import Foundation

/// Refreshing an INACTIVE slot's backup token through the consume gate
///. Refresh tokens are one-time use: the POST must
/// consume the freshest copy (re-read under the slot lock), two processes must
/// never POST the same grant (per-slot consume lock), and a successor is never
/// dropped (CAS on the lineage fingerprint, else stash it where the next
/// refresh adopts it). The active slot is never refreshed here: Claude Code owns that token.
struct TokenRefresher {
    let paths: Paths
    var creds: Credentials { Credentials(paths: paths) }

    static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    struct Outcome {
        /// The slot's now-current credential (ours, or a racing writer's newer one).
        var credential: String?
        /// invalid_grant, no_refresh_token, invalid_client, transient, consume-busy,
        /// stash-unreadable, store-unmirrored, active.
        var error: String?
        /// Fingerprint of the bytes actually POSTed; strikes bind to it.
        var consumedFp: String?
    }

    static func consumeLockURL(_ paths: Paths, _ n: Int) -> URL {
        paths.credentialsDir.appendingPathComponent(".consume-\(n).lock")
    }

    func consume(_ n: Int, email: String, snapshot: String) -> Outcome {
        if ProcessInfo.processInfo.environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"] != nil {
            return Outcome(error: "store-unmirrored")
        }
        guard let consumeLock = try? FileLock(Self.consumeLockURL(paths, n)) else { return Outcome(error: "consume-busy") }
        defer { consumeLock.release() }

        // Pre-consume window under the slot lock.
        let input: String
        do {
            let lock = try FileLock(paths.globalLock)
            defer { lock.release() }
            guard let roster = try Roster.load(paths), roster.slot(for: LiveIdentity.load(paths)) != n else {
                return Outcome(error: "active")
            }
            var current: String
            switch creds.readSlot(n, email) {
            case .unavailable: return Outcome(error: "transient")
            case .absent: return Outcome(error: "transient")
            case .value(let v): current = v
            }
            switch Stash(paths: paths).adopt(slot: n, email: email, current: current) {
            case .unreadable: return Outcome(error: "stash-unreadable")
            case .adopted(let c): current = c
            case .none: break
            }
            input = current
        } catch {
            return Outcome(error: "transient")
        }
        let consumedFp = Credentials.fingerprint(input)

        // Someone already refreshed it: use theirs, spend nothing.
        let inputToken = Credentials.accessToken(input)
        if let inputToken, !inputToken.isEmpty, inputToken != Credentials.accessToken(snapshot),
           !Credentials.isExpired(input) {
            return Outcome(credential: input, consumedFp: consumedFp)
        }

        let posted = Self.post(input)
        guard let successor = posted.credential else { return Outcome(error: posted.error, consumedFp: consumedFp) }

        // CAS: persist only over the generation we consumed.
        do {
            let lock = try FileLock(paths.globalLock)
            defer { lock.release() }
            switch creds.readSlot(n, email) {
            case .unavailable:
                return stash(successor, n, consumedFp, reason: "consume-gate-store-unreadable", demote: true)
            case .absent:
                return stash(successor, n, consumedFp, reason: "consume-gate-slot-removed", demote: false)
            case .value(let now) where Credentials.fingerprint(now) != consumedFp:
                var out = stash(successor, n, consumedFp, reason: "consume-gate-cas-conflict", demote: false)
                out.credential = now
                return out
            case .value:
                try creds.writeSlot(n, email, successor)
                return Outcome(credential: successor, consumedFp: consumedFp)
            }
        } catch is LockTimeout {
            return stash(successor, n, consumedFp, reason: "consume-gate-persist-lock-failed", demote: true)
        } catch {
            return stash(successor, n, consumedFp, reason: "consume-gate-persist-failed", demote: true)
        }
    }

    /// The consumed successor must survive somewhere; the next gate pass adopts it.
    private func stash(_ successor: String, _ n: Int, _ consumedFp: String?, reason: String, demote: Bool) -> Outcome {
        let stored = (try? Stash(paths: paths).write(successor, slot: n, consumedFp: consumedFp, reason: reason)) != nil
        // Persist failures report transient; the successor
        // still serves this pass.
        return Outcome(credential: successor, error: demote || !stored ? "transient" : nil, consumedFp: consumedFp)
    }

    /// POST the refresh grant. Every key besides the
    /// refreshed ones is kept.
    static func post(_ credential: String, timeout: TimeInterval = 10) -> (credential: String?, error: String?) {
        guard var root = JSONFiles.object(Data(credential.utf8)),
              var oauth = root["claudeAiOauth"] as? [String: Any] else {
            return (nil, JSONFiles.object(Data(credential.utf8)) == nil ? "transient" : "no_refresh_token")
        }
        guard let rt = oauth["refreshToken"] as? String, !rt.isEmpty else { return (nil, "no_refresh_token") }

        var req = URLRequest(url: tokenURL, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token", "refresh_token": rt, "client_id": clientID,
        ])
        let response = HTTP.send(req)
        let json = response.json
        guard response.status == 200 else {
            if [400, 401, 403].contains(response.status), let err = json?["error"] as? String,
               err == "invalid_grant" || err == "invalid_client" {
                return (nil, err)
            }
            return (nil, "transient")
        }
        guard let json, let access = json["access_token"] as? String,
              let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue else {
            // A 200 we can't read may still have consumed the grant; nothing to persist.
            return (nil, "transient")
        }
        oauth["accessToken"] = access
        oauth["expiresAt"] = Int64(Date().timeIntervalSince1970 * 1000) + Int64(expiresIn * 1000)
        if let next = json["refresh_token"] as? String, !next.isEmpty { oauth["refreshToken"] = next }
        if let scope = json["scope"] as? String, !scope.isEmpty {
            oauth["scopes"] = scope.split(separator: " ").map(String.init)
        }
        root["claudeAiOauth"] = oauth
        guard let out = try? JSONSerialization.data(withJSONObject: root, options: [.withoutEscapingSlashes]),
              let text = String(data: out, encoding: .utf8) else { return (nil, "transient") }
        return (text, nil)
    }
}

/// The unclaimed-credential stash: consumed
/// successors whose persist failed. Shared format so either side adopts.
struct Stash {
    let paths: Paths

    var manifestURL: URL { paths.credentialsDir.appendingPathComponent(".unclaimed-manifest.json") }
    var manifestLockURL: URL { paths.credentialsDir.appendingPathComponent(".unclaimed-manifest.lock") }
    func entryURL(_ id: String) -> URL { paths.credentialsDir.appendingPathComponent(".unclaimed-\(id).enc") }

    enum Adoption { case none, adopted(String), unreadable }

    private enum ManifestRead { case ok([String: Any]), unreadable, corrupt }

    private func readManifest() -> ManifestRead {
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return .ok([:]) }
        guard let data = FileManager.default.contents(atPath: manifestURL.path) else { return .unreadable }
        guard let root = JSONFiles.object(data), let entries = root["entries"] as? [String: Any] else { return .corrupt }
        return .ok(entries)
    }

    private func entryFilesExist() -> Bool {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: paths.credentialsDir.path) else {
            return FileManager.default.fileExists(atPath: paths.credentialsDir.path)
        }
        return items.contains { $0.hasPrefix(".unclaimed-") && $0.hasSuffix(".enc") }
    }

    /// The matching case of `_adopt_stashed_successor`:
    /// a stash row for this slot whose consumedFp is the stored generation holds
    /// that generation's live successor. Caller holds the slot lock.
    func adopt(slot n: Int, email: String, current: String) -> Adoption {
        guard let fp = Credentials.fingerprint(current) else { return .none }
        let entries: [String: Any]
        switch readManifest() {
        case .unreadable: return .unreadable
        case .corrupt: return entryFilesExist() ? .unreadable : .none
        case .ok(let e): entries = e
        }
        for (id, value) in entries {
            guard let meta = value as? [String: Any], meta["configSlot"] as? String == String(n),
                  meta["consumedFp"] as? String == fp else { continue }
            let url = entryURL(id)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            guard let data = FileManager.default.contents(atPath: url.path) else { return .unreadable }
            let b64 = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let decoded = Data(base64Encoded: b64), let text = String(data: decoded, encoding: .utf8),
                  !text.isEmpty else { continue }
            guard (try? Credentials(paths: paths).writeSlot(n, email, text)) != nil else { return .unreadable }
            retire(id)
            return .adopted(text)
        }
        return .none
    }

    /// `_write_unclaimed_credential`: entry bytes first, then the manifest row.
    func write(_ credential: String, slot n: Int, consumedFp: String?, reason: String) throws {
        try FileManager.default.createDirectory(at: paths.credentialsDir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        let nonce = (0..<3).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        let id = "\(f.string(from: Date()))-\(JSONFiles.sha256Hex(credential).prefix(12))-\(nonce)"
        try JSONFiles.atomicWrite(Data(Data(credential.utf8).base64EncodedString().utf8), to: entryURL(id))
        let row: [String: Any] = [
            "createdAt": ISODate.nowUTC(),
            "reason": reason,
            "configSlot": String(n),
            "consumedFp": consumedFp ?? NSNull(),
            "fingerprint": Credentials.fingerprint(credential) ?? NSNull(),
        ]
        try mutate { $0[id] = row }
    }

    private func retire(_ id: String) {
        try? FileManager.default.removeItem(at: entryURL(id))
        try? mutate { $0.removeValue(forKey: id) }
    }

    private func mutate(_ change: (inout [String: Any]) -> Void) throws {
        let lock = try FileLock(manifestLockURL)
        defer { lock.release() }
        var entries: [String: Any]
        switch readManifest() {
        case .unreadable: throw SwapError("The unclaimed manifest is unreadable")
        case .corrupt:
            // Set the bad file aside rather than overwrite it unread.
            let aside = manifestURL.deletingLastPathComponent()
                .appendingPathComponent(".unclaimed-manifest.json.corrupt-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: manifestURL, to: aside)
            entries = [:]
        case .ok(let e): entries = e
        }
        change(&entries)
        try JSONFiles.atomicWrite(try JSONFiles.serialize(["entries": entries]), to: manifestURL)
    }
}
