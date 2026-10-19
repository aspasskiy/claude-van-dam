import Foundation

/// Reading and writing the OAuth credential blobs: Claude Code's live one and
/// the per-slot backups. Values are opaque JSON text
/// and are never logged.
struct Credentials {
    let paths: Paths

    // MARK: Helpers

    /// `claudeAiOauth.expiresAt` is epoch milliseconds; 5-minute buffer.
    static func isExpired(_ credential: String, now: Date = Date()) -> Bool {
        guard let oauth = oauthObject(credential), let expires = oauth["expiresAt"] as? NSNumber else { return false }
        return now.timeIntervalSince1970 * 1000 + 300_000 >= expires.doubleValue
    }

    /// Lineage fingerprint.
    static func fingerprint(_ credential: String) -> String? {
        guard !credential.isEmpty else { return nil }
        if let rt = oauthObject(credential)?["refreshToken"] as? String, !rt.isEmpty {
            return "sha256:" + JSONFiles.sha256Hex(rt)
        }
        return "sha256-full:" + JSONFiles.sha256Hex(credential)
    }

    static func oauthObject(_ credential: String) -> [String: Any]? {
        JSONFiles.object(Data(credential.utf8))?["claudeAiOauth"] as? [String: Any]
    }

    static func accessToken(_ credential: String) -> String? {
        oauthObject(credential)?["accessToken"] as? String
    }

    static func isAPIKey(_ credential: String) -> Bool { credential.hasPrefix("sk-ant-api") }

    /// Claude Code blanked both tokens (e.g. after /logout): never back that up.
    static func isWiped(_ credential: String) -> Bool {
        guard let oauth = oauthObject(credential) else { return false }
        return (oauth["accessToken"] as? String ?? "").isEmpty && (oauth["refreshToken"] as? String ?? "").isEmpty
    }

    // MARK: Live credential

    /// Keychain first (2 attempts on "unavailable"), then the plaintext file.
    /// An unavailable Keychain is reported as such even if the file exists:
    /// on macOS that file may hold a consumed predecessor.
    func readLive() -> SecretRead {
        var result = Keychain.read(service: Paths.liveService, account: Keychain.accountName)
        if case .unavailable = result {
            usleep(300_000)
            result = Keychain.read(service: Paths.liveService, account: Keychain.accountName)
        }
        switch result {
        case .value(let v) where !v.isEmpty:
            return .value(v)
        case .unavailable:
            return result
        default:
            if let data = FileManager.default.contents(atPath: paths.credentialsFile.path) {
                let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { return .value(text) }
            }
            return .absent
        }
    }

    /// Machine-shared keys stay with the machine, not the account.
    static let sharedKeys = ["mcpOAuth", "mcpOAuthClientConfig", "mcpXaaIdp", "mcpXaaIdpConfig", "pluginSecrets"]

    static func compose(target: String, live: String?) throws -> String {
        guard var targetObject = JSONFiles.object(Data(target.utf8)), targetObject["claudeAiOauth"] != nil else {
            return target
        }
        guard let live, let liveObject = JSONFiles.object(Data(live.utf8)) else { return target }
        for key in sharedKeys {
            targetObject[key] = liveObject[key]
        }
        let data = try JSONSerialization.data(withJSONObject: targetObject, options: [.withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    /// Writes the OAuth credential Claude Code reads. `-U` updates the item in
    /// place, keeping its ACL. If the plaintext file already exists it is
    /// rewritten with the same bytes (running sessions watch its mtime);
    /// it is never created.
    func writeLive(_ credential: String) throws {
        guard !Self.isAPIKey(credential) else { throw SwapError("API-key accounts can't be switched by \(AppInfo.name)") }
        try Keychain.write(service: Paths.liveService, account: Keychain.accountName, value: credential)
        if FileManager.default.fileExists(atPath: paths.credentialsFile.path) {
            try JSONFiles.atomicWrite(Data(credential.utf8), to: paths.credentialsFile)
        }
        clearManagedKey()
    }

    /// A stale managed API key would shadow the OAuth login.
    private func clearManagedKey() {
        try? Keychain.delete(service: Paths.managedKeyService, account: Keychain.accountName)
        let url = paths.globalConfig
        guard let data = FileManager.default.contents(atPath: url.path),
              var config = JSONFiles.object(data), config["primaryApiKey"] != nil else { return }
        config.removeValue(forKey: "primaryApiKey")
        if let out = try? JSONFiles.serialize(config) { try? JSONFiles.atomicWrite(out, to: url) }
    }

    // MARK: Slot backups

    /// `.enc` file wins over the Keychain copy; unreadable is never collapsed into absent.
    func readSlot(_ n: Int, _ email: String) -> SecretRead {
        var failed: String?
        let enc = paths.slotEnc(n, email)
        if FileManager.default.fileExists(atPath: enc.path) {
            if let data = FileManager.default.contents(atPath: enc.path) {
                let b64 = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if let decoded = Data(base64Encoded: b64), let text = String(data: decoded, encoding: .utf8), !text.isEmpty {
                    return .value(text)
                }
            } else {
                failed = "cannot read \(enc.lastPathComponent)"
            }
        }
        switch Keychain.read(service: Paths.backupService, account: paths.slotKeychainAccount(n, email)) {
        case .value(let v) where !v.isEmpty: return .value(v)
        case .unavailable(let why): return .unavailable(why)
        default: return failed.map { .unavailable($0) } ?? .absent
        }
    }

    func writeSlot(_ n: Int, _ email: String, _ credential: String) throws {
        let account = paths.slotKeychainAccount(n, email)
        // Keep the previous generation as a recovery cushion (best effort).
        if case .value(let old) = readSlot(n, email), old != credential {
            try? Keychain.write(service: Paths.backupService, account: account + ".prev", value: old)
        }
        try Keychain.write(service: Paths.backupService, account: account, value: credential)
        // `.enc` wins on read, so a stale one must not survive a Keychain write.
        let enc = paths.slotEnc(n, email)
        if FileManager.default.fileExists(atPath: enc.path) {
            if (try? FileManager.default.removeItem(at: enc)) == nil {
                try JSONFiles.atomicWrite(Data(Data(credential.utf8).base64EncodedString().utf8), to: enc)
            }
        }
    }
}
