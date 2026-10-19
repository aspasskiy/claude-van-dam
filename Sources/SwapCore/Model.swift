import Foundation

public struct UsageWindow: Equatable, Identifiable, Sendable {
    public let name: String?
    public let pct: Double
    public let resetsAt: Date?
    public let expectedPct: Double?
    public let aheadOfPace: Bool?
    public let projectedExhaustionAt: Date?
    public let willLastToReset: Bool?

    public var id: String { name ?? "\(pct)|\(resetsAt?.timeIntervalSince1970 ?? 0)" }

    /// A window whose reset has passed has rolled over to 0, even if the cached
    /// measurement predates the reset.
    public func hasRolled(at now: Date) -> Bool { resetsAt.map { $0 <= now } ?? false }
    public func effectivePct(at now: Date) -> Double { hasRolled(at: now) ? 0 : pct }
}

public struct Spend: Equatable, Sendable {
    public let used: Double
    public let limit: Double
    public let pct: Double
    public let currency: String
    public let resetsAt: Date?
}

public struct Usage: Equatable, Sendable {
    public let fiveHour: UsageWindow?
    public let sevenDay: UsageWindow?
    public let scoped: [UsageWindow]
    public let spend: Spend?

    /// The binding constraint: whichever of 5h / 7d is closer to 100%.
    public func tightest(at now: Date) -> Double? {
        [fiveHour, sevenDay].compactMap { $0?.effectivePct(at: now) }.max()
    }
}

public enum UsageStatus: String, Sendable {
    case ok, apiKey, reloginRequired, unavailable
}

public struct Account: Identifiable, Equatable, Sendable {
    public let number: Int
    public let email: String
    public let organizationName: String
    public let organizationUuid: String
    public let alias: String?
    public let disabled: Bool
    public let active: Bool
    public let status: UsageStatus
    /// Decision-grade usage (fresh enough to act on).
    public let usage: Usage?
    /// Last successful measurement, for display when `usage` is nil.
    public let lastGoodUsage: Usage?
    public let fetchedAt: Date?

    public var id: Int { number }
    public var displayUsage: Usage? { usage ?? lastGoodUsage }
    public var isStale: Bool { usage == nil && lastGoodUsage != nil }
}

public struct Snapshot: Equatable, Sendable {
    public let accounts: [Account]
    /// Email of a Claude Code login that isn't saved yet (a /login nobody added).
    public var unmanagedLogin: String? = nil
    public var active: Account? { accounts.first { $0.active } }
}

public struct LoginState: Equatable, Sendable {
    public let email: String?
    public let fingerprint: String?
}

public struct SwitchResult: Sendable {
    public let switched: Bool
    public let from: Int?
    public let to: Int?
    public let toEmail: String?
    /// Reason codes: switched, already-active, usage-unavailable, already-best, …
    public let reason: String
}

// MARK: - Parsing stored usage

enum UsageParser {
    static let week: Double = 604_800

    /// `lastGood` dict → Usage; pace fields come from `fetchedAt`.
    static func usage(_ dict: [String: Any]?, fetchedAt: Date?) -> Usage? {
        guard let dict else { return nil }
        let five = window(dict["five_hour"], name: nil, weekly: false, fetchedAt: fetchedAt)
        let seven = window(dict["seven_day"], name: nil, weekly: true, fetchedAt: fetchedAt)
        let scoped = (dict["scoped"] as? [[String: Any]] ?? []).compactMap {
            window($0, name: $0["name"] as? String, weekly: true, fetchedAt: fetchedAt)
        }
        var spend: Spend?
        if let s = dict["spend"] as? [String: Any], let used = number(s["used"]), let limit = number(s["limit"]), let pct = number(s["pct"]) {
            spend = Spend(used: used, limit: limit, pct: pct, currency: s["currency"] as? String ?? "USD",
                          resetsAt: ISODate.parse(s["resets_at"] as? String))
        }
        return Usage(fiveHour: five, sevenDay: seven, scoped: scoped, spend: spend)
    }

    private static func window(_ any: Any?, name: String?, weekly: Bool, fetchedAt: Date?) -> UsageWindow? {
        guard let w = any as? [String: Any], let pct = number(w["pct"]) else { return nil }
        let reset = ISODate.parse(w["resets_at"] as? String)
        var expected: Double?, ahead: Bool?, exhaustion: Date?, willLast: Bool?
        if weekly, let fetched = fetchedAt?.timeIntervalSince1970, let next = reset?.timeIntervalSince1970 {
            var remaining = fmod(next - fetched, week)
            if remaining < 0 { remaining += week }
            let elapsed = remaining == 0 ? 0 : week - remaining
            if elapsed >= 86_400 {
                let e = min(100, elapsed / week * 100)
                expected = (e * 10).rounded() / 10
                ahead = pct - e >= 15
                if elapsed > 0, pct > 0 {
                    exhaustion = Date(timeIntervalSince1970: pct >= 100 ? fetched : fetched + (100 - pct) / (pct / elapsed))
                }
                willLast = pct <= 0 ? true : (pct + pct / elapsed * (week - elapsed) <= 100)
            }
        }
        return UsageWindow(name: name, pct: pct, resetsAt: reset, expectedPct: expected, aheadOfPace: ahead,
                           projectedExhaustionAt: exhaustion, willLastToReset: willLast)
    }

    static func number(_ any: Any?) -> Double? { (any as? NSNumber)?.doubleValue }
}

/// Settings that shape headroom (settings.json).
struct SwapSettings {
    var threshold: Double = 90
    var models: [String] = []

    static func load(_ paths: Paths) -> SwapSettings {
        var s = SwapSettings()
        guard let data = FileManager.default.contents(atPath: paths.settingsFile.path),
              let root = JSONFiles.object(data), let auto = root["autoswitch"] as? [String: Any] else { return s }
        if let t = UsageParser.number(auto["threshold"]) { s.threshold = t }
        if let m = auto["model"] as? String {
            s.models = m.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        }
        return s
    }

    /// Windows that count for headroom: 5h, 7d and configured per-model windows.
    func relevantWindows(_ u: Usage) -> [UsageWindow] {
        var ws = [u.fiveHour, u.sevenDay].compactMap { $0 }
        if !models.isEmpty {
            ws += u.scoped.filter { w in models.contains("all") || models.contains((w.name ?? "").lowercased()) }
        }
        return ws
    }

    func headroom(_ u: Usage?) -> Double? {
        guard let u else { return nil }
        let ws = relevantWindows(u)
        guard let m = ws.map(\.pct).max() else { return nil }
        return 100 - m
    }
}
