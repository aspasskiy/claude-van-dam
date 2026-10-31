import Foundation

/// Public entry point. Every call blocks (file locks, `security` subprocesses):
/// run it off the main thread.
public struct SwapService: Sendable {
    let paths: Paths

    public init() { paths = Paths() }

    /// Claude Code's global config (`~/.claude.json`); it changes on every switch or /login.
    public var globalConfigPath: String { paths.globalConfig.path }

    /// Accounts with usage read from the cache. No network.
    public func snapshot(now: Date = Date()) throws -> Snapshot {
        let identity = LiveIdentity.load(paths)
        guard let roster = try Roster.load(paths) else { return Snapshot(accounts: [], unmanagedLogin: identity?.email) }
        let live = roster.slot(for: identity)
        let rows = UsageRow.loadAll(paths)
        let settings = SwapSettings.load(paths)
        let creds = Credentials(paths: paths)
        let t = now.timeIntervalSince1970

        let accounts: [Account] = roster.sequence.compactMap { n in
            guard let e = roster.entries[n] else { return nil }
            let row = rows[n].flatMap { $0.matches(e) ? $0 : nil }
            var status: UsageStatus = e.kind == "api_key" ? .apiKey : .ok
            // Only touch the Keychain when the cache says the token may be dead.
            if let row, row.authDeadStrikes >= 1 {
                let stored = (n == live ? creds.readLive() : creds.readSlot(n, e.email)).string
                if row.tokenDead(storedFingerprint: stored.flatMap(Credentials.fingerprint)) { status = .reloginRequired }
            }
            let fetched = row?.fetchedAt.map { Date(timeIntervalSince1970: $0) }
            let decision = row?.decisionValue(now: t, settings: settings)
            let usage = status == .ok ? UsageParser.usage(decision, fetchedAt: fetched) : nil
            let lastGood = UsageParser.usage(row?.lastGood, fetchedAt: fetched)
            if status == .ok, usage == nil { status = .unavailable }
            return Account(number: n, email: e.email, organizationName: e.organizationName,
                           organizationUuid: e.organizationUuid, alias: e.alias, disabled: e.disabled,
                           active: n == live, status: status, usage: usage,
                           lastGoodUsage: usage == nil ? lastGood : nil, fetchedAt: fetched, plan: row?.plan)
        }
        return Snapshot(accounts: accounts, unmanagedLogin: live == nil ? identity?.email : nil)
    }

    /// Fetches fresh usage for rows the usage store says are due, then returns a snapshot.
    public func refresh() throws -> Snapshot {
        UsageFetcher(paths: paths).collect()
        return try snapshot()
    }

    /// Store the current Claude Code login (refreshes it in place when managed).
    public func addCurrent() throws -> AddResult { try Adder(paths: paths).addCurrent() }

    /// Who Claude Code is logged in as and which token lineage it holds, to notice a finished login.
    public func loginState() -> LoginState {
        LoginState(email: LiveIdentity.load(paths)?.email,
                   fingerprint: Credentials(paths: paths).readLive().string.flatMap(Credentials.fingerprint))
    }

    /// Before a new login overwrites the live credential, store the current one
    /// (it may hold a token generation its slot backup doesn't have yet).
    public func prepareLogin() throws -> LoginState {
        if paths.unsupportedEnvironment == nil, LiveIdentity.load(paths) != nil,
           case .value(let live) = Credentials(paths: paths).readLive(),
           !live.isEmpty, !Credentials.isWiped(live), !Credentials.isAPIKey(live) {
            _ = try addCurrent()
        }
        return loginState()
    }

    /// Every account with its login, for Import on another Mac. Returns the count.
    public func exportAccounts(to url: URL) throws -> Int {
        let (data, count) = try Transfer(paths: paths).export()
        try JSONFiles.atomicWrite(data, to: url)
        return count
    }

    /// Adds new accounts, heals dead slots, keeps healthy ones.
    public func importAccounts(from url: URL) throws -> ImportResult {
        guard let data = FileManager.default.contents(atPath: url.path) else { throw SwapError("Can't read \(url.lastPathComponent)") }
        return try Transfer(paths: paths).importFile(data)
    }

    /// Deletes the account's saved login and profile. Returns its email.
    public func removeAccount(_ n: Int) throws -> String { try Remover(paths: paths).remove(n) }

    /// One auto-switch check. `session` carries the burn-rate history and last switch time.
    public func autoSwitch(_ session: AutoSwitchSession, policy: AutoSwitch.Policy, dryRun: Bool = false) throws -> AutoTickResult {
        try session.lock.withLock {
            var history = session.history
            defer { session.history = history }
            let r = try AutoSwitchRunner(paths: paths).tick(policy: policy, lastSwitch: session.lastSwitch,
                                                            history: &history, dryRun: dryRun)
            if r.switched { session.lastSwitch = Date(); history.removeAll() }
            return r
        }
    }

    /// Mirror the threshold into settings.json: the poll planner checks
    /// the active account every 60 s once it's within 15% of it.
    public func setAutoSwitchThreshold(_ value: Double) {
        let url = paths.settingsFile
        var root = FileManager.default.contents(atPath: url.path).flatMap(JSONFiles.object) ?? ["schemaVersion": 1]
        var auto = root["autoswitch"] as? [String: Any] ?? [:]
        guard (auto["threshold"] as? NSNumber)?.doubleValue != value else { return }
        auto["threshold"] = value
        root["autoswitch"] = auto
        if let data = try? JSONFiles.serialize(root) { try? JSONFiles.atomicWrite(data, to: url) }
    }

    public func switchTo(_ n: Int) throws -> SwitchResult { try Switcher(paths: paths).perform(target: n) }
    public func rotate() throws -> SwitchResult { try Switcher(paths: paths).rotate() }
    public func best() throws -> SwitchResult { try Switcher(paths: paths).best() }
}
