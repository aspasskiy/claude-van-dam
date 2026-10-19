import Foundation

/// Store the login Claude Code is using now, refreshing the slot in
/// place when the account is already managed, else appending a new slot.
struct Adder {
    let paths: Paths
    var creds: Credentials { Credentials(paths: paths) }

    /// `oauthAccount` from ONE read of ~/.claude.json.
    struct Identity: Equatable {
        let email: String
        let organizationUuid: String
        let accountUuid: String
        let organizationName: String
    }

    static func identity(in config: [String: Any]) -> Identity? {
        guard let a = config["oauthAccount"] as? [String: Any],
              let email = a["emailAddress"] as? String, !email.isEmpty else { return nil }
        return Identity(email: email,
                        organizationUuid: a["organizationUuid"] as? String ?? "",
                        accountUuid: a["accountUuid"] as? String ?? "",
                        organizationName: a["organizationName"] as? String ?? "")
    }

    func addCurrent() throws -> AddResult {
        if let why = paths.unsupportedEnvironment { throw SwapError("Can't add here (\(why)) — unset it and try again") }

        guard let configData = FileManager.default.contents(atPath: paths.globalConfig.path),
              let config = JSONFiles.object(configData), let identity = Self.identity(in: config) else {
            throw SwapError("No Claude Code login found — log in first")
        }
        let live = try readLive()
        if Credentials.isAPIKey(live) { throw SwapError("The current login is an API key — \(AppInfo.name) only manages Claude subscription logins") }
        if Credentials.isWiped(live) { throw SwapError("Claude Code is logged out — log in first") }

        // Whose token is this? Network, so no lock is held.
        try rejectForeign(live, identity)

        // Nothing may have moved while we were on the network.
        let liveNow = try readLive()
        if Credentials.fingerprint(liveNow) != Credentials.fingerprint(live) {
            throw SwapError("The login changed while it was being checked. Nothing was changed — try again")
        }
        guard let configNowData = FileManager.default.contents(atPath: paths.globalConfig.path),
              let configNow = JSONFiles.object(configNowData), Self.identity(in: configNow) == identity else {
            throw SwapError("The active account changed while it was being checked. Nothing was changed — try again")
        }

        let lock = try FileLock(paths.globalLock)
        defer { lock.release() }
        try paths.createBackupDirectories()

        var raw = try Roster.load(paths)?.raw ?? Roster.emptyRaw()
        var accounts = raw["accounts"] as? [String: Any] ?? [:]
        let existing = accounts.first { _, v in
            guard let e = v as? [String: Any] else { return false }
            return e["email"] as? String == identity.email
                && (e["organizationUuid"] as? String ?? "") == identity.organizationUuid
        }

        let number: Int
        var credentialChanged = true
        if let (key, _) = existing, let n = Int(key) {
            // Refresh in place.
            number = n
            if case .value(let stored) = creds.readSlot(n, identity.email), stored == live { credentialChanged = false }
            if credentialChanged { try creds.writeSlot(n, identity.email, live) }
            try JSONFiles.atomicWrite(configNowData, to: paths.slotConfig(n, identity.email))
        } else {
            // New slot: max + 1.
            number = (accounts.keys.compactMap(Int.init).max() ?? 0) + 1
            try creds.writeSlot(number, identity.email, live)
            try JSONFiles.atomicWrite(configNowData, to: paths.slotConfig(number, identity.email))
            accounts[String(number)] = [
                "email": identity.email,
                "uuid": identity.accountUuid,
                "organizationUuid": identity.organizationUuid,
                "organizationName": identity.organizationName,
                "added": ISODate.nowUTC(),
            ]
            raw["accounts"] = accounts
            var sequence = Roster.sequence(in: raw)
            if !sequence.contains(number) { sequence.append(number); sequence.sort() }
            raw["sequence"] = sequence
        }
        raw["activeAccountNumber"] = number
        raw["lastUpdated"] = ISODate.nowUTC()
        try JSONFiles.atomicWrite(try JSONFiles.serialize(raw), to: paths.sequenceFile)
        lock.release()

        if credentialChanged { clearDeadToken(number, identity) }
        return AddResult(number: number, email: identity.email, created: existing == nil, credentialChanged: credentialChanged)
    }

    private func readLive() throws -> String {
        switch creds.readLive() {
        case .value(let v) where !v.isEmpty: return v
        case .unavailable: throw SwapError("Keychain is unavailable — unlock it and try again")
        default: throw SwapError("No Claude Code credential found — log in first")
        }
    }

    /// Advisory: an unresolvable token registers anyway; only an
    /// identity that resolves and DISAGREES refuses. Expired tokens are not
    /// refreshed here (that would spend the grant).
    private func rejectForeign(_ live: String, _ identity: Identity) throws {
        guard let token = Credentials.accessToken(live), !token.isEmpty, !Credentials.isExpired(live) else { return }
        if Self.owns(token: token, email: identity.email, organizationUuid: identity.organizationUuid,
                     accountUuid: identity.accountUuid) == false {
            throw SwapError("The stored token isn't \(identity.email)'s. Nothing was changed — log in as \(identity.email) again")
        }
    }

    /// Does this access token belong to the account? nil = unresolvable
    /// (offline, 401, no uuid): callers decide whether that blocks.
    /// UUID first, else email; the org must agree when the response has one.
    static func owns(token: String, email: String, organizationUuid: String, accountUuid: String) -> Bool? {
        guard let profile = fetchProfile(token) else { return nil }
        if !accountUuid.isEmpty {
            if profile.uuid != accountUuid { return false }
        } else {
            guard let seen = profile.email, !seen.isEmpty else { return nil }
            if seen.lowercased() != email.lowercased() { return false }
        }
        if let org = profile.organizationUuid, org.trimmingCharacters(in: .whitespaces) != organizationUuid { return false }
        return true
    }

    /// GET /api/oauth/profile. nil = unresolvable.
    static func fetchProfile(_ token: String) -> (uuid: String, email: String?, organizationUuid: String?)? {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/profile")!, timeoutInterval: 5)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let response = HTTP.send(req)
        let body = response.status == 200 ? response.json : nil
        guard let account = body?["account"] as? [String: Any],
              let uuid = (account["uuid"] as? String)?.trimmingCharacters(in: .whitespaces), !uuid.isEmpty else { return nil }
        let org = (body?["organization"] as? [String: Any])?["uuid"] as? String
        return (uuid, account["email"] as? String, org)
    }

    /// `UsageStore.clear_dead_token`: the new token
    /// becomes fetch-eligible again.
    private func clearDeadToken(_ n: Int, _ identity: Identity) {
        clearDeadToken(n, email: identity.email, organizationUuid: identity.organizationUuid)
    }

    func clearDeadToken(_ n: Int, email: String, organizationUuid: String) {
        guard let lock = try? FileLock(paths.usageLock) else { return }
        defer { lock.release() }
        guard let data = FileManager.default.contents(atPath: paths.usageFile.path),
              var root = JSONFiles.object(data), (root["schemaVersion"] as? NSNumber)?.intValue == 2 else { return }
        var accounts = root["accounts"] as? [String: Any] ?? [:]
        var row = accounts[String(n)] as? [String: Any] ?? [:]
        if row["email"] as? String != email || (row["organizationUuid"] as? String ?? "") != organizationUuid {
            row = ["email": email, "organizationUuid": organizationUuid]
        }
        row["claimId"] = NSNull()
        row["claimUntil"] = 0.0
        row["authDeadStrikes"] = 0
        row["struckFingerprint"] = NSNull()
        row["consecutiveFailures"] = 0
        row["lastError"] = NSNull()
        row["backoffUntil"] = NSNull()
        accounts[String(n)] = row
        root["accounts"] = accounts
        if let out = try? JSONFiles.serialize(root) { try? JSONFiles.atomicWrite(out, to: paths.usageFile) }
    }
}

public struct AddResult: Sendable {
    public let number: Int
    public let email: String
    public let created: Bool
    public let credentialChanged: Bool
}
