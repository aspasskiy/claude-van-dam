import Foundation

/// Auto-switch: when the active account's
/// binding window (the fullest of 5h / 7d / configured model windows) reaches
/// the threshold — or is burning fast enough to hit 100% before the next check
/// lands — switch to the account with the most headroom, while the old account
/// still works, so running Claude Code sessions (which pick up a new Keychain
/// token within ~30 s) never hit the limit.
public enum AutoSwitch {
    public struct Policy: Equatable, Sendable {
        public var threshold: Double = 95
        /// A target must sit this far below the threshold, so two accounts at the line never ping-pong.
        public var hysteresis: Double = 10
        public var cooldown: TimeInterval = 300
        /// Seconds until a switch is felt: next usage check + Claude Code's Keychain pickup.
        public var lookahead: TimeInterval = 150
        public init(threshold: Double = 95) { self.threshold = threshold }
    }

    public struct Candidate: Equatable, Sendable {
        public let number: Int
        public let email: String
        /// Binding-window utilization from decision-grade (fresh) usage; nil = unknown.
        public let binding: Double?
        public let weekResetsAt: Date?
        /// Switchable, not paused, refresh token not dead.
        public let eligible: Bool
        public init(number: Int, email: String, binding: Double?, weekResetsAt: Date?, eligible: Bool) {
            self.number = number; self.email = email; self.binding = binding
            self.weekResetsAt = weekResetsAt; self.eligible = eligible
        }
    }

    public enum Decision: Equatable, Sendable {
        case stay
        /// `projected` = the trigger was the burn rate, not the threshold itself.
        case switchTo(Int, email: String, fromBinding: Double, projected: Bool)
        /// Active is at the threshold but nothing better exists; `recovery` = earliest relief.
        case exhausted(recovery: Date?)
        case cooldown
    }

    /// Pure: no I/O. `burnRate` is the active binding's rise in % per second (≥ 0).
    public static func decide(active: Candidate, others: [Candidate], burnRate: Double, policy: Policy,
                              lastSwitch: Date?, now: Date, recovery: Date? = nil) -> Decision {
        guard let b = active.binding else { return .stay }
        let projected = b + max(0, burnRate) * policy.lookahead
        let atThreshold = b >= policy.threshold
        let willHitLimit = b >= policy.threshold - policy.hysteresis && projected >= 100
        guard atThreshold || willHitLimit else { return .stay }

        let hard = b >= 100
        if !hard, let lastSwitch, now.timeIntervalSince(lastSwitch) < policy.cooldown { return .cooldown }

        let ceiling = policy.threshold - policy.hysteresis
        let pool = others.filter { $0.eligible && $0.number != active.number }
        let fits = pool.filter { ($0.binding ?? 101) <= ceiling }
        // Most headroom; tie → the week that resets soonest (use it before it's wasted).
        let best = fits.min { x, y in
            if x.binding! != y.binding! { return x.binding! < y.binding! }
            return (x.weekResetsAt ?? .distantFuture) < (y.weekResetsAt ?? .distantFuture)
        }
        if let best {
            return .switchTo(best.number, email: best.email, fromBinding: b, projected: !atThreshold)
        }
        // At the hard limit, anything with more room beats being blocked.
        if hard, let any = pool.filter({ ($0.binding ?? 101) < 100 }).min(by: { $0.binding! < $1.binding! }) {
            return .switchTo(any.number, email: any.email, fromBinding: b, projected: false)
        }
        return .exhausted(recovery: recovery)
    }
}

/// Runs one auto-switch check against the live state.
struct AutoSwitchRunner {
    let paths: Paths
    var creds: Credentials { Credentials(paths: paths) }

    struct Sample { let at: Double; let binding: Double }

    func tick(policy: AutoSwitch.Policy, lastSwitch: Date?, history: inout [Sample], dryRun: Bool) throws -> AutoTickResult {
        guard paths.unsupportedEnvironment == nil, let roster = try Roster.load(paths),
              let live = roster.slot(for: LiveIdentity.load(paths)) else { return AutoTickResult(decision: .stay) }
        let settings = SwapSettings.load(paths)
        let rows = UsageRow.loadAll(paths)
        let now = Date()
        let t = now.timeIntervalSince1970
        let switcher = Switcher(paths: paths)

        func usage(_ n: Int) -> (Usage?, UsageRow?) {
            guard let e = roster.entries[n], let row = rows[n], row.matches(e) else { return (nil, nil) }
            return (UsageParser.usage(row.decisionValue(now: t, settings: settings), fetchedAt: nil), row)
        }
        func binding(_ u: Usage?) -> Double? {
            guard let u else { return nil }
            return settings.relevantWindows(u).map { $0.effectivePct(at: now) }.max()
        }
        func candidate(_ n: Int) -> AutoSwitch.Candidate? {
            guard let e = roster.entries[n], e.kind == "oauth" else { return nil }
            let (u, row) = usage(n)
            var eligible = !e.disabled && switcher.switchable(n, e)
            if eligible, let row, row.authDeadStrikes >= 1,
               row.tokenDead(storedFingerprint: creds.readSlot(n, e.email).string.flatMap(Credentials.fingerprint)) {
                eligible = false
            }
            return AutoSwitch.Candidate(number: n, email: e.email, binding: binding(u),
                                        weekResetsAt: u?.sevenDay?.resetsAt, eligible: eligible)
        }

        guard let active = candidate(live) else { return AutoTickResult(decision: .stay) }
        let others = roster.sequence.filter { $0 != live }.compactMap(candidate)

        // Burn rate from the last two distinct measurements of the active account.
        if let row = usage(live).1, let fetched = row.fetchedAt, let b = active.binding {
            if history.last?.at != fetched { history.append(Sample(at: fetched, binding: b)) }
            history = history.filter { t - $0.at < 900 }.suffix(4).map { $0 }
        }
        var rate = 0.0
        if history.count >= 2, let a = history.first, let z = history.last, z.at > a.at, z.binding >= a.binding {
            rate = (z.binding - a.binding) / (z.at - a.at)
        }
        // Earliest relief across every account's fullest window.
        let recovery = ([live] + others.map(\.number)).compactMap { n -> Date? in
            guard let u = usage(n).0 else { return nil }
            return settings.relevantWindows(u).filter { $0.effectivePct(at: now) >= policy.threshold }.compactMap(\.resetsAt).max()
        }.min()

        let decision = AutoSwitch.decide(active: active, others: others, burnRate: rate, policy: policy,
                                         lastSwitch: lastSwitch, now: now, recovery: recovery)
        guard case .switchTo(let target, let email, _, _) = decision, !dryRun else {
            return AutoTickResult(decision: decision, burnRate: rate)
        }
        // Freshen the target first (refresh if it expires within 10 min),
        // so the token that goes live is good for a while.
        if let e = roster.entries[target], let snap = creds.readSlot(target, e.email).string,
           let exp = (Credentials.oauthObject(snap)?["expiresAt"] as? NSNumber)?.doubleValue, exp / 1000 - t < 600 {
            let r = TokenRefresher(paths: paths).consume(target, email: email, snapshot: snap)
            if let err = r.error, UsageFetcher.permanentAuthErrors.contains(err) {
                return AutoTickResult(decision: .stay, burnRate: rate, failure: "\(email) is signed out")
            }
        }
        let result = try switcher.perform(target: target)
        return AutoTickResult(decision: decision, burnRate: rate, switched: result.switched)
    }
}

public struct AutoTickResult: Sendable {
    public var decision: AutoSwitch.Decision
    public var burnRate: Double = 0
    public var switched = false
    public var failure: String?
}

/// State an auto-switch caller keeps between ticks.
public final class AutoSwitchSession: @unchecked Sendable {
    let lock = NSLock()
    var history: [AutoSwitchRunner.Sample] = []
    public internal(set) var lastSwitch: Date?
    public init(lastSwitch: Date? = nil) { self.lastSwitch = lastSwitch }
    /// A manual switch also starts the cooldown, so auto-switch doesn't undo it at once.
    public func noteSwitch() { lock.withLock { lastSwitch = Date(); history.removeAll() } }
}
