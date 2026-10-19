import Foundation

/// Claude Code and app paths on macOS. Only the default
/// profile is supported: with CLAUDE_CONFIG_DIR set the Keychain service name
/// gets a hash suffix, so mutations are refused instead.
struct Paths {
    let home: URL

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    var configHome: URL { home.appendingPathComponent(".claude") }

    /// `~/.claude/.config.json` if that legacy file exists, else `~/.claude.json`.
    var globalConfig: URL {
        let legacy = configHome.appendingPathComponent(".config.json")
        return FileManager.default.fileExists(atPath: legacy.path) ? legacy : home.appendingPathComponent(".claude.json")
    }

    var credentialsFile: URL { configHome.appendingPathComponent(".credentials.json") }

    /// Directory and Keychain service names are kept as they are: renaming
    /// them would orphan every saved account.
    var backupRoot: URL { home.appendingPathComponent(".claude-swap-backup") }
    /// The global lock around the roster and slot backups.
    var globalLock: URL { backupRoot.appendingPathComponent(".lock") }
    var sequenceFile: URL { backupRoot.appendingPathComponent("sequence.json") }
    var settingsFile: URL { backupRoot.appendingPathComponent("settings.json") }
    var configsDir: URL { backupRoot.appendingPathComponent("configs") }
    var credentialsDir: URL { backupRoot.appendingPathComponent("credentials") }
    var cacheDir: URL { backupRoot.appendingPathComponent("cache") }
    var usageFile: URL { cacheDir.appendingPathComponent("usage.json") }
    var usageLock: URL { cacheDir.appendingPathComponent(".usage.lock") }

    /// The backup root and its subdirectories, owner-only.
    func createBackupDirectories() throws {
        for dir in [backupRoot, configsDir, credentialsDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            chmod(dir.path, 0o700)
        }
    }

    func slotConfig(_ n: Int, _ email: String) -> URL {
        configsDir.appendingPathComponent(".claude-config-\(n)-\(email).json")
    }

    func slotEnc(_ n: Int, _ email: String) -> URL {
        credentialsDir.appendingPathComponent(".creds-\(n)-\(email).enc")
    }

    func slotKeychainAccount(_ n: Int, _ email: String) -> String { "account-\(n)-\(email)" }

    // Claude Code's lock directories.
    var oauthRefreshLock: URL { configHome.appendingPathComponent(".oauth_refresh.lock") }
    var credentialsLock: URL { home.appendingPathComponent(".claude.lock") }
    var configLock: URL { globalConfig.deletingLastPathComponent().appendingPathComponent(globalConfig.lastPathComponent + ".lock") }

    static let liveService = "Claude Code-credentials"
    static let managedKeyService = "Claude Code"
    static let backupService = "claude-swap"

    /// Reasons the app must not touch credentials.
    var unsupportedEnvironment: String? {
        let env = ProcessInfo.processInfo.environment
        if let v = env["CLAUDE_CONFIG_DIR"], !v.isEmpty { return "CLAUDE_CONFIG_DIR is set" }
        if env["CLAUDE_SECURESTORAGE_CONFIG_DIR"] != nil { return "CLAUDE_SECURESTORAGE_CONFIG_DIR is set" }
        return nil
    }
}
