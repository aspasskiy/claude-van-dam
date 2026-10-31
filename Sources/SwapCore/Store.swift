import Foundation

/// `sequence.json`: the roster of managed slots.
struct Roster {
    struct Entry {
        let email: String
        let organizationUuid: String
        let organizationName: String
        let alias: String?
        let disabled: Bool
        let kind: String
        let uuid: String
        let added: String
    }

    let raw: [String: Any]
    let sequence: [Int]
    let entries: [Int: Entry]
    let activeHint: Int?

    /// nil = no roster yet. An unparseable file is an error, never "empty":
    /// rewriting it from scratch would wipe every account.
    static func load(_ paths: Paths) throws -> Roster? {
        guard let data = FileManager.default.contents(atPath: paths.sequenceFile.path) else { return nil }
        guard let raw = JSONFiles.object(data) else { throw SwapError("\(paths.sequenceFile.path) is unreadable — restore it from an export") }
        var entries: [Int: Entry] = [:]
        for (key, value) in raw["accounts"] as? [String: Any] ?? [:] {
            guard let n = Int(key), let e = value as? [String: Any] else { continue }
            let alias = (e["alias"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            entries[n] = Entry(email: e["email"] as? String ?? "unknown",
                               organizationUuid: e["organizationUuid"] as? String ?? "",
                               organizationName: e["organizationName"] as? String ?? "",
                               alias: alias,
                               disabled: e["disabled"] as? Bool ?? false,
                               kind: e["kind"] as? String ?? "oauth",
                               uuid: e["uuid"] as? String ?? "",
                               added: e["added"] as? String ?? "")
        }
        let sequence = Self.sequence(in: raw)
        return Roster(raw: raw, sequence: sequence, entries: entries,
                      activeHint: (raw["activeAccountNumber"] as? NSNumber)?.intValue)
    }

    func slot(for identity: LiveIdentity?) -> Int? {
        guard let identity else { return nil }
        return sequence.first { n in
            guard let e = entries[n] else { return false }
            return e.email == identity.email && e.organizationUuid == identity.organizationUuid
        }
    }

    /// Only `activeAccountNumber` and `lastUpdated` change; every other key is kept.
    func writeActive(_ n: Int, paths: Paths) throws {
        var updated = raw
        updated["activeAccountNumber"] = n
        updated["lastUpdated"] = ISODate.nowUTC()
        try JSONFiles.atomicWrite(try JSONFiles.serialize(updated), to: paths.sequenceFile)
    }

    /// A brand-new `sequence.json`.
    static func emptyRaw() -> [String: Any] {
        ["activeAccountNumber": NSNull(), "lastUpdated": ISODate.nowUTC(), "sequence": [Int](), "accounts": [String: Any]()]
    }

    /// The slot numbers in `raw["sequence"]`.
    static func sequence(in raw: [String: Any]) -> [Int] {
        (raw["sequence"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue }
    }
}

/// The login Claude Code is using now: `oauthAccount` in ~/.claude.json.
struct LiveIdentity: Equatable {
    let email: String
    let organizationUuid: String

    static func load(_ paths: Paths) -> LiveIdentity? {
        guard let data = FileManager.default.contents(atPath: paths.globalConfig.path),
              let config = JSONFiles.object(data),
              let account = config["oauthAccount"] as? [String: Any],
              let email = account["emailAddress"] as? String, !email.isEmpty else { return nil }
        return LiveIdentity(email: email, organizationUuid: account["organizationUuid"] as? String ?? "")
    }
}

/// `cache/usage.json` rows (schemaVersion 2). Read lock-free: every writer
/// replaces the file atomically.
struct UsageRow {
    let raw: [String: Any]

    var email: String? { raw["email"] as? String }
    var organizationUuid: String { raw["organizationUuid"] as? String ?? "" }
    var fetchedAt: Double? { UsageParser.number(raw["fetchedAt"]) }
    var lastGood: [String: Any]? { raw["lastGood"] as? [String: Any] }
    var lastError: String? { raw["lastError"] as? String }
    var consecutiveFailures: Int { (raw["consecutiveFailures"] as? NSNumber)?.intValue ?? 0 }
    var nextPollAt: Double? { UsageParser.number(raw["nextPollAt"]) }
    var claimUntil: Double? { UsageParser.number(raw["claimUntil"]) }
    var lastAttemptAt: Double? { UsageParser.number(raw["lastAttemptAt"]) }
    var authDeadStrikes: Int { (raw["authDeadStrikes"] as? NSNumber)?.intValue ?? 0 }
    var struckFingerprint: String? { raw["struckFingerprint"] as? String }
    var plan: String? { raw["plan"] as? String }
    var planFetchedAt: Double? { UsageParser.number(raw["planFetchedAt"]) }

    func matches(_ e: Roster.Entry) -> Bool { email == e.email && organizationUuid == e.organizationUuid }

    func liveClaim(now: Double) -> Bool {
        if let c = claimUntil { return now < c }
        if let a = lastAttemptAt { return now - a < 10 }
        return false
    }

    /// Dead refresh token, unless the stored credential has since changed.
    func tokenDead(storedFingerprint: String?) -> Bool {
        guard authDeadStrikes >= 1 else { return false }
        if let stored = storedFingerprint, let struck = struckFingerprint, stored != struck { return false }
        return true
    }

    /// Usage trusted enough to act on.
    func decisionValue(now: Double, settings: SwapSettings) -> [String: Any]? {
        guard let lastGood, let fetchedAt else { return nil }
        let age = now - fetchedAt
        if age <= 300 { return lastGood }
        let within: Bool
        if lastError == "http-429" {
            let parsed = UsageParser.usage(lastGood, fetchedAt: nil)
            let resets = parsed.map { settings.relevantWindows($0).compactMap { $0.resetsAt?.timeIntervalSince1970 }.filter { $0 > now } } ?? []
            within = now < min(resets.min() ?? .infinity, now + 7200 - age)
        } else {
            within = age <= 3600
        }
        let extended = within && (consecutiveFailures > 0 || (nextPollAt.map { now < $0 } ?? false) || liveClaim(now: now))
        return extended ? lastGood : nil
    }

    static func loadAll(_ paths: Paths) -> [Int: UsageRow] {
        guard let data = FileManager.default.contents(atPath: paths.usageFile.path),
              let root = JSONFiles.object(data),
              (root["schemaVersion"] as? NSNumber)?.intValue == 2,
              let accounts = root["accounts"] as? [String: Any] else { return [:] }
        var rows: [Int: UsageRow] = [:]
        for (key, value) in accounts {
            if let n = Int(key), let raw = value as? [String: Any] { rows[n] = UsageRow(raw: raw) }
        }
        return rows
    }
}
