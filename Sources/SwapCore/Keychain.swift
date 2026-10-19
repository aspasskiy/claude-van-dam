import Foundation

/// Tri-state read result. Only `security` exit 44 means "absent"; anything else
/// that fails is "unavailable" (locked / denied / timed out) and must never be
/// treated as empty.
public enum SecretRead: Equatable {
    case value(String)
    case absent
    case unavailable(String)

    var string: String? { if case .value(let v) = self { return v } else { return nil } }
}

struct KeychainError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Keychain access through `/usr/bin/security` only. Every item involved was
/// created by that binary (by Claude Code and by this app), so its ACL trusts it;
/// Security.framework calls from this app would prompt or re-ACL the item
/// so Claude Code could no longer read it silently.
enum Keychain {
    static let security = "/usr/bin/security"
    static let timeout: TimeInterval = 5
    /// `security -i` reads stdin with a 4096-byte line buffer.
    static let stdinLineLimit = 4096 - 64
    static let notFound: Int32 = 44

    /// Mirrors Claude Code's getUsername(): $USER, then the OS user name.
    static var accountName: String {
        if let user = ProcessInfo.processInfo.environment["USER"], !user.isEmpty { return user }
        if let pw = getpwuid(geteuid()), let name = pw.pointee.pw_name { return String(cString: name) }
        return "claude-code-user"
    }

    static func read(service: String, account: String) -> SecretRead {
        do {
            let r = try execRun(security, ["find-generic-password", "-a", account, "-w", "-s", service], timeout: timeout)
            if r.status == 0 {
                var s = r.out
                if s.hasSuffix("\n") { s.removeLast() }
                return .value(s)
            }
            if r.status == notFound { return .absent }
            return .unavailable("security rc=\(r.status): \(r.err)")
        } catch {
            return .unavailable("security timed out")
        }
    }

    /// The hex value goes through `security -i` on stdin so it stays out of
    /// argv. A credential too long for that line (big MCP OAuth blobs) falls
    /// back to argv, where other processes of the same user can see it in
    /// `ps` while `security` runs.
    static func write(service: String, account: String, value: String) throws {
        let hex = Data(value.utf8).map { String(format: "%02x", $0) }.joined()
        let line = "add-generic-password -U -a \(quote(account)) -s \(quote(service)) -X \(hex)\n"
        let r: ExecResult
        do {
            if line.utf8.count <= stdinLineLimit {
                r = try execRun(security, ["-i"], stdin: Data(line.utf8), timeout: timeout)
            } else {
                r = try execRun(security, ["add-generic-password", "-U", "-a", account, "-s", service, "-X", hex], timeout: timeout)
            }
        } catch {
            throw KeychainError(message: "security add-generic-password timed out")
        }
        guard r.status == 0 else {
            throw KeychainError(message: "security add-generic-password failed (rc=\(r.status)): \(r.err)")
        }
    }

    static func delete(service: String, account: String) throws {
        let r: ExecResult
        do {
            r = try execRun(security, ["delete-generic-password", "-a", account, "-s", service], timeout: timeout)
        } catch {
            throw KeychainError(message: "security delete-generic-password timed out")
        }
        guard r.status == 0 || r.status == notFound else {
            throw KeychainError(message: "security delete-generic-password failed (rc=\(r.status)): \(r.err)")
        }
    }

    private static func quote(_ v: String) -> String {
        "\"" + v.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
