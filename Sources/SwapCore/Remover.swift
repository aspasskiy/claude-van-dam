import Foundation

/// Removing an account: the slot's backups (Keychain items, `.enc` files, `.prev`), its profile,
/// its roster entry and its directory mappings. The live Claude Code login is
/// never touched.
struct Remover {
    let paths: Paths

    func remove(_ n: Int) throws -> String {
        if let why = paths.unsupportedEnvironment { throw SwapError("Can't remove here (\(why)) — unset it and try again") }
        // A refresh in flight would otherwise stash a successor for a slot that's gone.
        let consume: FileLock
        do { consume = try FileLock(TokenRefresher.consumeLockURL(paths, n), timeout: 15) } catch {
            throw SwapError("Account \(n) is being refreshed — try again in a moment")
        }
        defer { consume.release() }
        let lock = try FileLock(paths.globalLock)
        defer { lock.release() }

        guard let roster = try Roster.load(paths), let e = roster.entries[n] else { throw SwapError("Account \(n) doesn't exist") }
        let fm = FileManager.default
        // Also the legacy `account-None-…` key.
        for key in [String(n), "None"] {
            let base = "account-\(key)-\(e.email)"
            try? fm.removeItem(at: paths.credentialsDir.appendingPathComponent(".creds-\(key)-\(e.email).enc"))
            try? fm.removeItem(at: paths.credentialsDir.appendingPathComponent(".creds-\(key)-\(e.email).enc.prev"))
            try? Keychain.delete(service: Paths.backupService, account: base)
            try? Keychain.delete(service: Paths.backupService, account: base + ".prev")
        }
        try? fm.removeItem(at: paths.slotConfig(n, e.email))

        var raw = roster.raw
        var accounts = raw["accounts"] as? [String: Any] ?? [:]
        accounts.removeValue(forKey: String(n))
        raw["accounts"] = accounts
        raw["sequence"] = Roster.sequence(in: raw).filter { $0 != n }
        raw["lastUpdated"] = ISODate.nowUTC()
        try JSONFiles.atomicWrite(try JSONFiles.serialize(raw), to: paths.sequenceFile)

        pruneMappings(email: e.email, organizationUuid: e.organizationUuid)
        return e.email
    }

    /// Drop the identity's directory mappings.
    private func pruneMappings(email: String, organizationUuid: String) {
        let url = paths.backupRoot.appendingPathComponent("mappings.json")
        guard let data = FileManager.default.contents(atPath: url.path), var root = JSONFiles.object(data),
              let mappings = root["mappings"] as? [String: Any] else { return }
        let kept = mappings.filter { _, v in
            guard let m = v as? [String: Any] else { return true }
            return !(m["email"] as? String == email && (m["organizationUuid"] as? String ?? "") == organizationUuid)
        }
        guard kept.count != mappings.count else { return }
        root["mappings"] = kept
        if let out = try? JSONFiles.serialize(root) { try? JSONFiles.atomicWrite(out, to: url) }
    }
}
