import Foundation

/// Export / import: a portable JSON envelope, version 1. The file holds live login tokens in
/// plain text, written 0600.
struct Transfer {
    let paths: Paths
    var creds: Credentials { Credentials(paths: paths) }

    static let formatVersion = 1

    // MARK: Export

    func export() throws -> (data: Data, count: Int) {
        guard let roster = try Roster.load(paths), !roster.entries.isEmpty else {
            throw SwapError("No accounts to export")
        }
        let live = LiveIdentity.load(paths)
        var payload: [[String: Any]] = []
        for n in roster.entries.keys.sorted() {
            guard let e = roster.entries[n] else { continue }
            let credText: String?
            let configData: Data?
            if let live, live.email == e.email, live.organizationUuid == e.organizationUuid {
                switch creds.readLive() {
                case .value(let v) where !v.isEmpty: credText = v
                case .unavailable: throw SwapError("Keychain is unavailable — unlock it and try again")
                default: throw SwapError("Can't read the live login for \(e.email)")
                }
                configData = FileManager.default.contents(atPath: paths.globalConfig.path)
            } else {
                switch creds.readSlot(n, e.email) {
                case .value(let v): credText = v
                case .unavailable: throw SwapError("Keychain is unavailable — unlock it and try again")
                case .absent: credText = nil
                }
                configData = FileManager.default.contents(atPath: paths.slotConfig(n, e.email).path)
            }
            guard let credText, let configData, !configData.isEmpty else { continue }
            guard let config = JSONFiles.object(configData), let oauthAccount = config["oauthAccount"] as? [String: Any] else {
                throw SwapError("The saved profile of \(e.email) is unreadable")
            }
            var entry: [String: Any] = [
                "number": n,
                "email": e.email,
                "uuid": e.uuid,
                "organizationUuid": e.organizationUuid,
                "organizationName": e.organizationName,
                "added": e.added,
                "config": ["oauthAccount": oauthAccount],
            ]
            if Credentials.isAPIKey(credText.trimmingCharacters(in: .whitespacesAndNewlines)) {
                entry["credentials"] = credText.trimmingCharacters(in: .whitespacesAndNewlines)
                entry["kind"] = "api_key"
            } else {
                guard let obj = JSONFiles.object(Data(credText.utf8)) else {
                    throw SwapError("The saved login of \(e.email) is unreadable")
                }
                entry["credentials"] = obj["claudeAiOauth"].map { ["claudeAiOauth": $0] } ?? obj
            }
            if let alias = e.alias { entry["alias"] = alias }
            payload.append(entry)
        }
        guard !payload.isEmpty else { throw SwapError("No exportable accounts") }
        let exported = Set(payload.compactMap { $0["number"] as? Int })
        let active = roster.activeHint.flatMap { exported.contains($0) ? $0 : nil }
        let envelope: [String: Any] = [
            "version": Self.formatVersion,
            "exportedAt": ISODate.nowUTC(),
            "exportedFrom": "macos",
            "swapVersion": "\(AppInfo.slug)-\(AppInfo.version)",
            "encrypted": false,
            "activeAccountNumber": active ?? NSNull(),
            "accounts": payload,
        ]
        return (try JSONFiles.serialize(envelope), payload.count)
    }

    // MARK: Import — new accounts, and replacing slots
    // whose refresh token is dead. A healthy slot is never overwritten.

    func importFile(_ data: Data) throws -> ImportResult {
        if let why = paths.unsupportedEnvironment { throw SwapError("Can't import here (\(why)) — unset it and try again") }
        guard let envelope = JSONFiles.object(data) else { throw SwapError("Not an export file") }
        guard (envelope["version"] as? NSNumber)?.intValue == Self.formatVersion else {
            throw SwapError("Unsupported export version")
        }
        if envelope["encrypted"] as? Bool == true { throw SwapError("Encrypted exports aren't supported — decrypt it first") }
        guard let raws = envelope["accounts"] as? [Any], !raws.isEmpty else { throw SwapError("The file has no accounts") }

        struct Item { let email, org, orgName, uuid, added, kind, credText, configText: String; let number: Int; let alias: String? }
        var items: [Item] = []
        var seen = Set<String>()
        for raw in raws {
            guard let a = raw as? [String: Any] else { throw SwapError("Malformed account entry") }
            guard let email = a["email"] as? String, Self.validEmail(email) else { throw SwapError("Invalid email in the file") }
            // `is Bool` matches any NSNumber 0/1; JSON booleans are CFBoolean.
            guard let num = a["number"] as? NSNumber, CFGetTypeID(num) != CFBooleanGetTypeID(),
                  let number = Int(exactly: num.doubleValue), number >= 1 else {
                throw SwapError("Invalid slot number for \(email)")
            }
            for field in ["organizationUuid", "organizationName", "uuid", "added", "alias"] {
                if let v = a[field], !(v is NSNull), !(v is String) { throw SwapError("\(field) for \(email) must be text") }
            }
            guard let config = a["config"] as? [String: Any] else { throw SwapError("Missing profile for \(email)") }
            let org = a["organizationUuid"] as? String ?? ""
            guard seen.insert(email + "\u{0}" + org).inserted else { throw SwapError("\(email) appears twice in the file") }
            let credText: String
            let kind: String
            if a["kind"] as? String == "api_key" || a["credentials"] is String {
                guard let key = (a["credentials"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      Credentials.isAPIKey(key) else { throw SwapError("Bad API key for \(email)") }
                credText = key
                kind = "api_key"
            } else {
                guard let obj = a["credentials"] as? [String: Any],
                      let d = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else {
                    throw SwapError("Missing login for \(email)")
                }
                credText = String(decoding: d, as: UTF8.self)
                kind = "oauth"
            }
            let alias = (a["alias"] as? String).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.flatMap { $0.isEmpty ? nil : $0 }
            items.append(Item(email: email, org: org, orgName: a["organizationName"] as? String ?? "",
                              uuid: a["uuid"] as? String ?? "", added: (a["added"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? ISODate.nowUTC(),
                              kind: kind, credText: credText,
                              configText: String(decoding: try JSONFiles.serialize(config), as: UTF8.self),
                              number: number, alias: alias))
        }

        let lock = try FileLock(paths.globalLock)
        defer { lock.release() }
        try paths.createBackupDirectories()
        var root = try Roster.load(paths)?.raw ?? Roster.emptyRaw()
        let rows = UsageRow.loadAll(paths)
        let envelopeActive = (envelope["activeAccountNumber"] as? NSNumber)?.intValue
        var result = ImportResult()
        var resolvedActive: Int?

        for item in items {
            var accounts = root["accounts"] as? [String: Any] ?? [:]
            let existing = accounts.first { _, v in
                guard let r = v as? [String: Any] else { return false }
                return r["email"] as? String == item.email && (r["organizationUuid"] as? String ?? "") == item.org
            }.flatMap { Int($0.key) }
            let target: Int
            if let existing {
                // A dead slot is replaced (auto-heal); a healthy one is kept.
                let stored = creds.readSlot(existing, item.email).string.flatMap(Credentials.fingerprint)
                // Re-importing the very generation that was struck heals nothing.
                guard let row = rows[existing], row.email == item.email, row.tokenDead(storedFingerprint: stored),
                      Credentials.fingerprint(item.credText) != row.struckFingerprint else {
                    result.skipped += 1
                    if item.number == envelopeActive { resolvedActive = existing }
                    continue
                }
                target = existing
                result.replaced += 1
            } else {
                target = accounts[String(item.number)] == nil ? item.number : (accounts.keys.compactMap(Int.init).max() ?? 0) + 1
                result.imported += 1
            }
            try creds.writeSlot(target, item.email, item.credText)
            try JSONFiles.atomicWrite(Data(item.configText.utf8), to: paths.slotConfig(target, item.email))
            Adder(paths: paths).clearDeadToken(target, email: item.email, organizationUuid: item.org)

            var record: [String: Any] = [
                "email": item.email, "uuid": item.uuid, "organizationUuid": item.org,
                "organizationName": item.orgName, "added": item.added,
            ]
            if item.kind == "api_key" { record["kind"] = "api_key" }
            if let alias = item.alias, !Self.aliasTaken(alias, by: accounts, except: (item.email, item.org)) { record["alias"] = alias }
            accounts[String(target)] = record
            root["accounts"] = accounts
            var sequence = Roster.sequence(in: root)
            if !sequence.contains(target) { sequence.append(target); sequence.sort() }
            root["sequence"] = sequence
            root["lastUpdated"] = ISODate.nowUTC()
            try JSONFiles.atomicWrite(try JSONFiles.serialize(root), to: paths.sequenceFile)
            if item.number == envelopeActive { resolvedActive = target }
            if let live = LiveIdentity.load(paths), live.email == item.email, live.organizationUuid == item.org {
                result.liveReplaced = true
            }
        }
        if (root["activeAccountNumber"] as? NSNumber)?.intValue ?? 0 == 0, let resolvedActive {
            root["activeAccountNumber"] = resolvedActive
            root["lastUpdated"] = ISODate.nowUTC()
            try JSONFiles.atomicWrite(try JSONFiles.serialize(root), to: paths.sequenceFile)
        }
        return result
    }

    static func validEmail(_ s: String) -> Bool {
        s.range(of: #"^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$"#, options: .regularExpression) != nil
    }

    private static func aliasTaken(_ alias: String, by accounts: [String: Any], except owner: (String, String)) -> Bool {
        accounts.values.contains { v in
            guard let r = v as? [String: Any], (r["alias"] as? String)?.lowercased() == alias else { return false }
            return !(r["email"] as? String == owner.0 && (r["organizationUuid"] as? String ?? "") == owner.1)
        }
    }
}

public struct ImportResult: Sendable {
    public var imported = 0
    public var replaced = 0
    public var skipped = 0
    /// An imported slot is the current Claude Code login; its live token wasn't touched.
    public var liveReplaced = false
}
