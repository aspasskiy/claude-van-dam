import Foundation
import SwapCore
import SwiftUI
import UserNotifications

@MainActor
final class Store: ObservableObject {
    @Published private(set) var accounts: [Account] = []
    @Published private(set) var refreshing = false
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    /// Slot being switched to; -1 for best/next switches.
    @Published private(set) var switching: Int?
    @Published private(set) var now = Date()
    /// A Claude Code login that isn't saved yet.
    @Published private(set) var unmanagedLogin: String?
    /// Login in progress in Terminal: "" for a new account, else the email being re-logged.
    @Published private(set) var loginPending: String?
    @Published private(set) var adding = false
    private var loginBaseline: LoginState?
    private var loginDeadline = Date.distantPast
    private var loginChecking = false
    /// A changed login must read the same twice (2 s apart) before it's stored:
    /// the token and ~/.claude.json are written separately.
    private var loginCandidate: LoginState?
    private var loginFailures = 0

    /// Survives relaunches: the assertion is re-taken at startup.
    @Published var keepAwake: Bool = UserDefaults.standard.bool(forKey: "keepAwake") {
        didSet {
            UserDefaults.standard.set(keepAwake, forKey: "keepAwake")
            awake.set(keepAwake)
        }
    }
    private let awake = KeepAwake()

    @Published var autoSwitch: Bool = UserDefaults.standard.bool(forKey: "autoSwitch") {
        didSet {
            UserDefaults.standard.set(autoSwitch, forKey: "autoSwitch")
            if autoSwitch { Notifier.requestPermission(); refresh() }
        }
    }
    @Published var autoThreshold: Double = UserDefaults.standard.object(forKey: "autoThreshold") as? Double ?? 95 {
        didSet {
            UserDefaults.standard.set(autoThreshold, forKey: "autoThreshold")
            let service = service, value = autoThreshold
            Task.detached { service.setAutoSwitchThreshold(value) }
            refresh()
        }
    }
    private let autoSession = AutoSwitchSession(lastSwitch: UserDefaults.standard.object(forKey: "autoLastSwitch") as? Date)
    /// One "all accounts are at the limit" alert per episode.
    private var exhaustedNotified = false

    @Published var trayText: TrayText = TrayText(rawValue: UserDefaults.standard.string(forKey: "trayText") ?? "") ?? .percent {
        didSet { UserDefaults.standard.set(trayText.rawValue, forKey: "trayText") }
    }

    var popoverVisible = false {
        didSet {
            guard popoverVisible, !oldValue else { return }
            now = Date()
            refresh()
        }
    }

    var active: Account? { accounts.first { $0.active } }

    private let service = SwapService()
    /// The usage store decides which accounts are due, so polling every 60 s
    /// doesn't mean an API call per account every 60 s.
    private let refreshInterval = 60
    private var ticks = 0
    private var timer: Timer?
    private var noticeTask: Task<Void, Never>?
    private var refreshQueued = false

    private var claudeJSONModified: Date?

    /// `--demo`: made-up accounts for screenshots; never touches real state.
    static let demo = CommandLine.arguments.contains("--demo")

    func start() {
        if Self.demo {
            accounts = Demo.snapshot().accounts
            lastRefresh = Date()
            return
        }
        awake.set(keepAwake)
        if autoSwitch {
            Notifier.requestPermission()
            let service = service, value = autoThreshold
            Task.detached { service.setAutoSwitchThreshold(value) }
        }
        refresh()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        ticks += 1
        // Countdowns only need per-second precision while someone is looking.
        if popoverVisible || ticks % 30 == 0 { now = Date() }
        if ticks % 2 == 0 { checkActiveAccountChange(); checkLogin() }
        if ticks % refreshInterval == 0 { refresh() }
    }

    func refresh() {
        guard !Self.demo else { return }
        // A pass already in flight may predate a switch; run one more after it.
        guard !refreshing else { refreshQueued = true; return }
        refreshing = true
        let service = service
        Task {
            defer {
                refreshing = false
                if refreshQueued { refreshQueued = false; refresh() }
            }
            do {
                let snap = try await Task.detached(priority: .utility) { try service.refresh() }.value
                accounts = snap.accounts
                unmanagedLogin = snap.unmanagedLogin
                lastRefresh = Date()
                now = Date()
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
            await runAutoSwitch()
        }
    }

    // MARK: Auto-switch

    /// Debug renders run a second copy of the app; it must never switch accounts.
    var autoSwitchSuspended = CommandLine.arguments.contains("--render") || demo

    private func runAutoSwitch() async {
        guard autoSwitch, !autoSwitchSuspended, switching == nil, loginPending == nil, !adding else { return }
        let service = service, session = autoSession
        let policy = AutoSwitch.Policy(threshold: autoThreshold)
        switching = -1
        let result = await Task.detached(priority: .userInitiated) { Result { try service.autoSwitch(session, policy: policy) } }.value
        switching = nil
        switch result {
        case .failure(let e):
            self.error = "Auto-switch: \(e.localizedDescription)"
        case .success(let r):
            if let failure = r.failure { self.error = "Auto-switch: \(failure)" }
            switch r.decision {
            case .switchTo(_, let email, let from, let projected) where r.switched:
                UserDefaults.standard.set(session.lastSwitch, forKey: "autoLastSwitch")
                exhaustedNotified = false
                let name = accounts.first { $0.email == email }?.title ?? email
                let why = projected ? "was about to hit the limit (\(Int(from))%)" : "reached \(Int(from))%"
                showNotice("Auto-switched to \(name)")
                var body = "The previous account \(why). Running sessions move over within ~30 s."
                if from >= 100 { body += " A session that already stopped needs “continue”." }
                Notifier.post(title: "Switched to \(name)", body: body)
                refresh()
            case .exhausted(let recovery):
                guard !exhaustedNotified else { break }
                exhaustedNotified = true
                let when = recovery.map { " First one frees up at \(Fmt.clock($0, now: Date()))." } ?? ""
                Notifier.post(title: "Every account is near its limit", body: "Nothing to switch to.\(when)")
            case .stay:
                exhaustedNotified = false
            default:
                break
            }
        }
    }

    func switchTo(_ number: Int) {
        guard !Self.demo else { return }
        let service = service
        performSwitch(marker: number) { try service.switchTo(number) }
    }

    private func performSwitch(marker: Int, _ op: @escaping @Sendable () throws -> SwitchResult) {
        guard switching == nil else { return }
        switching = marker
        autoSession.noteSwitch()
        UserDefaults.standard.set(autoSession.lastSwitch, forKey: "autoLastSwitch")
        Task {
            defer { switching = nil }
            do {
                let result = try await Task.detached(priority: .userInitiated) { try op() }.value
                if result.switched {
                    let name = accounts.first { $0.number == result.to }?.title ?? result.toEmail ?? "account"
                    showNotice("Switched to \(name). Running sessions pick it up within ~30 s.")
                } else {
                    showNotice(Self.describe(result.reason))
                }
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
            refresh()
        }
    }

    private static func describe(_ reason: String) -> String {
        switch reason {
        case "already-active": return "Already on this account"
        case "already-best": return "Already on the account with the most headroom"
        case "candidates-exhausted": return "Every account is at its limit"
        case "usage-unavailable": return "Usage unknown for some accounts — not switching"
        case "only-one-account": return "Only one account"
        case "no-valid-target": return "No account to switch to"
        default: return reason
        }
    }

    private func showNotice(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { notice = nil }
        }
    }

    func dismissError() { error = nil }

    /// Asks first; the live Claude Code login is never touched.
    func confirmRemove(_ account: Account) {
        guard !Self.demo else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \(account.title)?"
        alert.informativeText = "Its saved login is deleted from this Mac. To bring it back, use Add account and log in again."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let service = service
        let number = account.number
        Task {
            do {
                let email = try await Task.detached(priority: .userInitiated) { try service.removeAccount(number) }.value
                showNotice("Removed \(email)")
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
            refresh()
        }
    }

    // MARK: Login and add

    /// Store the login Claude Code has now.
    func addCurrentLogin() {
        guard !Self.demo else { return }
        guard !adding else { return }
        adding = true
        let service = service
        Task {
            defer { adding = false }
            do {
                let r = try await Task.detached(priority: .userInitiated) { try service.addCurrent() }.value
                showNotice(r.created ? "Added \(r.email) as account \(r.number)" : "Saved the login for \(r.email)")
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
            refresh()
        }
    }

    /// Saves the current login, then runs `claude auth login` in Terminal and
    /// stores whatever account it ends up logged in as.
    func logIn(email: String?) {
        guard !Self.demo else { return }
        guard loginPending == nil, !adding else { return }
        loginPending = email ?? ""
        let service = service
        Task {
            do {
                let baseline = try await Task.detached(priority: .userInitiated) { try service.prepareLogin() }.value
                try Self.openLoginTerminal(email: email)
                loginBaseline = baseline
                loginDeadline = Date().addingTimeInterval(15 * 60)
                error = nil
            } catch {
                loginPending = nil
                self.error = error.localizedDescription
            }
        }
    }

    func cancelLogin() {
        loginPending = nil
        loginBaseline = nil
        loginCandidate = nil
        loginFailures = 0
    }

    private func checkLogin() {
        guard let expected = loginPending, let baseline = loginBaseline, !loginChecking else { return }
        if Date() > loginDeadline {
            cancelLogin()
            return
        }
        loginChecking = true
        let service = service
        Task {
            defer { loginChecking = false }
            let state = await Task.detached(priority: .utility) { service.loginState() }.value
            guard loginPending != nil, state.fingerprint != nil, state.email != nil, state != baseline else {
                loginCandidate = nil
                return
            }
            guard state == loginCandidate else {
                loginCandidate = state
                return
            }
            loginCandidate = nil
            do {
                let r = try await Task.detached(priority: .userInitiated) { try service.addCurrent() }.value
                // A token refresh of the account we started on also changes the
                // fingerprint: it got saved, but keep waiting for the real login.
                let done = expected.isEmpty ? state.email != baseline.email || r.created : r.email == expected
                if done {
                    cancelLogin()
                    showNotice(r.created ? "Added \(r.email) as account \(r.number)" : "Logged in again as \(r.email)")
                } else {
                    loginBaseline = state
                }
                error = nil
            } catch {
                // Usually a half-written login; give it a few more reads.
                loginFailures += 1
                if loginFailures >= 3 {
                    cancelLogin()
                    self.error = error.localizedDescription
                }
            }
            refresh()
        }
    }

    /// A `.command` file opens in Terminal without Apple Events permission.
    private static func openLoginTerminal(email: String?) throws {
        let fm = FileManager.default
        let local = fm.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude").path
        let claude = fm.isExecutableFile(atPath: local) ? quote(local) : "claude"
        let emailArg = email.map { " --email " + quote($0) } ?? ""
        let script = """
        #!/bin/zsh -l
        clear
        echo "Log in to Claude in your browser. \(AppInfo.name) saves the account when you're done."
        echo
        \(claude) auth login\(emailArg)
        echo
        echo "You can close this window."
        """
        let url = fm.temporaryDirectory.appendingPathComponent("\(AppInfo.name) Login.command")
        try Data(script.utf8).write(to: url, options: .atomic)
        chmod(url.path, 0o700)
        guard NSWorkspace.shared.open(url) else { throw SwapError("Couldn't open Terminal") }
    }

    private static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// A /login in Claude Code (or another switcher) rewrites
    /// ~/.claude.json; re-read when the logged-in identity there changes.
    private func checkActiveAccountChange() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: service.globalConfigPath),
              let modified = attrs[.modificationDate] as? Date,
              modified != claudeJSONModified else { return }
        let first = claudeJSONModified == nil
        claudeJSONModified = modified
        guard !first, !refreshing, switching == nil else { return }
        let service = service
        Task {
            guard let snap = try? await Task.detached(priority: .utility, operation: { try service.snapshot() }).value else { return }
            unmanagedLogin = snap.unmanagedLogin
            guard snap.active?.number != active?.number else { return }
            accounts = snap.accounts
        }
    }
}

enum TrayText: String, CaseIterable, Identifiable {
    case percent, account, both, none
    var id: String { rawValue }
    var label: String {
        switch self {
        case .percent: return "Percentage"
        case .account: return "Account"
        case .both: return "Account and percentage"
        case .none: return "Bars only"
        }
    }
}

/// Start at login through a LaunchAgent; SMAppService is unreliable for
/// ad-hoc signed bundles.
enum LoginItem {
    static let label = Bundle.main.bundleIdentifier ?? "site.spasskiy.claude-van-dam"
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    static func setEnabled(_ enabled: Bool) {
        if !enabled {
            try? FileManager.default.removeItem(at: plistURL)
            return
        }
        guard let exe = Bundle.main.executablePath else { return }
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [exe],
            "RunAtLoad": true,
            // Restart after a crash, but not after Quit.
            "KeepAlive": ["SuccessfulExit": false],
            "ProcessType": "Interactive",
        ]
        try? FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
            try? data.write(to: plistURL)
        }
    }
}

// MARK: - Display helpers

extension Account {
    var title: String { alias ?? email }

    var subtitle: String? {
        var parts: [String] = []
        if alias != nil { parts.append(email) }
        if !organizationName.isEmpty, organizationName != "\(email)'s Organization" { parts.append(organizationName) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var initial: String {
        String(title.first(where: { $0.isLetter || $0.isNumber }) ?? "?").uppercased()
    }

    /// Distinct hue per slot, so same-initial accounts still look different.
    var avatarHue: Double {
        let palette: [Double] = [0.62, 0.40, 0.08, 0.88, 0.53, 0.75, 0.15, 0.97]
        return palette[(number - 1 + palette.count) % palette.count]
    }

    var problem: String? {
        switch status {
        case .ok, .unavailable: return nil
        case .reloginRequired: return "Signed out — click to log in"
        case .apiKey: return "API key — no subscription limits"
        }
    }

    func note(now: Date) -> String? {
        if let problem { return problem }
        if let fetchedAt, now.timeIntervalSince(fetchedAt) > 15 * 60 { return "Updated \(Fmt.ago(fetchedAt, now: now))" }
        return nil
    }
}

/// macOS notifications (asks once). A bare executable (`swift run`) has no
/// bundle, and UNUserNotificationCenter raises there, so it stays silent.
enum Notifier {
    private static var available: Bool { Bundle.main.bundleIdentifier != nil }

    static func requestPermission() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
