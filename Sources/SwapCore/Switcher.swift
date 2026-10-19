import Foundation

/// Switching Claude Code to another saved account. Refused: an unsaved live
/// login, API-key slots and CLAUDE_CONFIG_DIR profiles.
struct Switcher {
    let paths: Paths
    var creds: Credentials { Credentials(paths: paths) }

    func perform(target: Int) throws -> SwitchResult {
        if let why = paths.unsupportedEnvironment { throw SwapError("Can't switch here (\(why)) — unset it and try again") }

        // A refresh of the target's backup must not POST while its token goes
        // live: take its consume lock first (order: consume → .lock → Claude
        // Code's locks, the same as the refresh path).
        let consume: FileLock
        do { consume = try FileLock(TokenRefresher.consumeLockURL(paths, target), timeout: 15) } catch {
            throw SwapError("Account \(target) is being refreshed — try again in a moment")
        }
        defer { consume.release() }
        let locks = try SwitchLocks(paths: paths)
        defer { locks.release() }

        // 1. Fresh state under the locks.
        guard let roster = try Roster.load(paths) else { throw SwapError("No accounts — use Add account first") }
        guard let targetEntry = roster.entries[target] else { throw SwapError("Account \(target) doesn't exist") }
        guard targetEntry.kind == "oauth" else { throw SwapError("API-key accounts can't be switched by \(AppInfo.name)") }
        guard let current = roster.slot(for: LiveIdentity.load(paths)), let currentEntry = roster.entries[current] else {
            throw SwapError("The current Claude Code login isn't saved yet — click Save next to it first")
        }
        if current == target {
            return SwitchResult(switched: false, from: current, to: target, toEmail: targetEntry.email, reason: "already-active")
        }

        // 2. Live credential and config. A failed or empty read aborts: an empty
        // value must never overwrite the departing slot's backup.
        let live: String
        switch creds.readLive() {
        case .value(let v) where !v.isEmpty: live = v
        case .unavailable: throw SwapError("Keychain is unavailable — unlock it and try again")
        default: throw SwapError("No live Claude Code credential to back up")
        }
        guard let liveConfigData = FileManager.default.contents(atPath: paths.globalConfig.path),
              var liveConfig = JSONFiles.object(liveConfigData) else {
            throw SwapError("~/.claude.json is missing or unreadable — open Claude Code once and try again")
        }

        // 3. Back up the departing account.
        let backup = creds.readSlot(current, currentEntry.email)
        if case .unavailable(let why) = backup { throw SwapError("Can't read the backup of account \(current): \(why)") }
        let backupValue = backup.string
        let writeCreds: Bool
        if let backupValue, backupValue == live {
            writeCreds = false                                      // own bytes
        } else if Credentials.isWiped(live) {
            writeCreds = false                                      // logged out: keep the old backup
        } else {
            writeCreds = true                                       // same lineage, rotated, or unresolved
        }
        if writeCreds { try creds.writeSlot(current, currentEntry.email, live) }
        try JSONFiles.atomicWrite(liveConfigData, to: paths.slotConfig(current, currentEntry.email))

        // 4. Target credential and its oauthAccount.
        let targetCred: String
        switch creds.readSlot(target, targetEntry.email) {
        case .value(let v): targetCred = v
        case .unavailable(let why): throw SwapError("Can't read account \(target): \(why) — don't re-add it")
        case .absent: throw SwapError("Account \(target) has no stored credentials — log in to it again")
        }
        guard let targetConfigData = FileManager.default.contents(atPath: paths.slotConfig(target, targetEntry.email).path),
              let targetConfig = JSONFiles.object(targetConfigData),
              let targetOAuth = targetConfig["oauthAccount"] as? [String: Any] else {
            throw SwapError("Account \(target) has no saved profile — log in to it again")
        }

        // 5–7 with reverse rollback.
        var wroteCreds = false, wroteConfig = false
        do {
            try creds.writeLive(try Credentials.compose(target: targetCred, live: live))
            wroteCreds = true
            liveConfig["oauthAccount"] = targetOAuth
            try JSONFiles.atomicWrite(try JSONFiles.serialize(liveConfig), to: paths.globalConfig)
            wroteConfig = true
            try roster.writeActive(target, paths: paths)
        } catch {
            if wroteConfig { try? JSONFiles.atomicWrite(liveConfigData, to: paths.globalConfig) }
            if wroteCreds { try? creds.writeLive(live) }
            throw error
        }
        return SwitchResult(switched: true, from: current, to: target, toEmail: targetEntry.email, reason: "switched")
    }

    /// A slot is switchable when its backup and its profile both exist.
    func switchable(_ n: Int, _ e: Roster.Entry) -> Bool {
        guard case .value = creds.readSlot(n, e.email) else { return false }
        guard let data = FileManager.default.contents(atPath: paths.slotConfig(n, e.email).path) else { return false }
        return !data.isEmpty
    }

    /// Plain rotation.
    func rotate() throws -> SwitchResult {
        guard let roster = try Roster.load(paths) else { throw SwapError("No accounts") }
        guard roster.sequence.count >= 2 else {
            return SwitchResult(switched: false, from: nil, to: nil, toEmail: nil, reason: "only-one-account")
        }
        let live = roster.slot(for: LiveIdentity.load(paths))
        let anchor = roster.activeHint ?? live
        let start = anchor.flatMap { roster.sequence.firstIndex(of: $0) } ?? 0
        for offset in 1..<roster.sequence.count {
            let cand = roster.sequence[(start + offset) % roster.sequence.count]
            guard let e = roster.entries[cand], !e.disabled, switchable(cand, e) else { continue }
            if cand == live {
                return SwitchResult(switched: false, from: live, to: cand, toEmail: e.email, reason: "already-active")
            }
            return try perform(target: cand)
        }
        return SwitchResult(switched: false, from: live, to: nil, toEmail: nil, reason: "no-valid-target")
    }

    /// `--strategy best` on decision-grade usage; also
    /// skips slots whose refresh token is known dead.
    func best() throws -> SwitchResult {
        guard let roster = try Roster.load(paths) else { throw SwapError("No accounts") }
        let settings = SwapSettings.load(paths)
        let rows = UsageRow.loadAll(paths)
        let now = Date().timeIntervalSince1970
        guard let current = roster.slot(for: LiveIdentity.load(paths)) ?? roster.activeHint else {
            throw SwapError("The current login isn't saved yet")
        }
        func headroom(_ n: Int) -> Double? {
            guard let e = roster.entries[n], let row = rows[n], row.matches(e) else { return nil }
            let u = UsageParser.usage(row.decisionValue(now: now, settings: settings), fetchedAt: nil)
            return settings.headroom(u)
        }
        let others = roster.sequence.filter { n in
            guard n != current, let e = roster.entries[n], !e.disabled, switchable(n, e) else { return false }
            if let row = rows[n], row.matches(e), row.authDeadStrikes >= 1 {
                return !row.tokenDead(storedFingerprint: creds.readSlot(n, e.email).string.flatMap(Credentials.fingerprint))
            }
            return true
        }
        guard !others.isEmpty else { return try rotate() }
        guard let cur = headroom(current) else {
            return SwitchResult(switched: false, from: current, to: nil, toEmail: nil, reason: "usage-unavailable")
        }
        let known = others.compactMap { n in headroom(n).map { (n, $0) } }
        guard let best = known.max(by: { $0.1 < $1.1 }) else {
            return SwitchResult(switched: false, from: current, to: nil, toEmail: nil, reason: "usage-unavailable")
        }
        // First max in sequence order; ties stay put.
        let first = known.first { $0.1 == best.1 }!
        if first.1 > cur { return try perform(target: first.0) }
        if known.count < others.count {
            return SwitchResult(switched: false, from: current, to: nil, toEmail: nil, reason: "usage-unavailable")
        }
        return SwitchResult(switched: false, from: current, to: nil, toEmail: nil,
                            reason: cur <= 0 ? "candidates-exhausted" : "already-best")
    }
}
