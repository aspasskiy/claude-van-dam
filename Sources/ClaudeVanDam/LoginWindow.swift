import AppKit
import os
import SwapCore
import SwiftUI
import WebKit

/// `claude auth login` without Terminal: the CLI runs as a hidden child, its
/// $BROWSER hands over the sign-in URL, and the page opens in a private window
/// that shares no cookies with the user's browsers. The URL redirects to the
/// CLI's own localhost server, so the CLI finishes the login as usual.
@MainActor
final class LoginWindow: NSObject, NSWindowDelegate, NSToolbarDelegate, WKNavigationDelegate, WKUIDelegate {
    /// The user closed the window.
    var onCancel: (() -> Void)?
    /// The CLI exited on its own after the page was shown: its status and last line of output.
    var onExit: ((Int32, String) -> Void)?

    private let email: String?
    private let process = Process()
    /// Kept open: the CLI also waits for a pasted code on stdin.
    private let stdin = Pipe()
    private let output = OSAllocatedUnfairLock(initialState: Data())
    /// No spaces in this path: $BROWSER may be split on them.
    private let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("claude-van-dam-login-\(UUID().uuidString)")
    private var url: URL?
    private var window: NSWindow?
    private var popups: [NSWindow] = []
    private var ended = false
    private var web: WKWebView?
    private var urlObservation: NSKeyValueObservation?
    /// Times a signed-in page was sent back to the authorization page; capped so a redirect can't loop.
    private var returns = 0
    private let emailLink = EmailLinkState()
    /// Opens an email's magic link out of sight, in a session of its own.
    private var linkReader: WKWebView?

    init(email: String?) {
        self.email = email
    }

    /// Starts the CLI and shows its sign-in page once $BROWSER receives it.
    func start() async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let urlFile = dir.appendingPathComponent("url")
        let browser = dir.appendingPathComponent("browser")
        let script = """
        #!/bin/sh
        printf '%s' "$1" > \(Self.quote(urlFile.path)).tmp && mv \(Self.quote(urlFile.path)).tmp \(Self.quote(urlFile.path))

        """
        try Data(script.utf8).write(to: browser)
        chmod(browser.path, 0o700)

        let local = fm.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude").path
        let claude = fm.isExecutableFile(atPath: local) ? Self.quote(local) : "claude"
        let emailArg = email.map { " --email " + Self.quote($0) } ?? ""
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // A login shell finds `claude` on the user's PATH; BROWSER is set after the profile runs.
        process.arguments = ["-lc", "export BROWSER=\(Self.quote(browser.path)); exec \(claude) auth login\(emailArg)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = stdin
        let output = output
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil } else { output.withLock { $0.append(chunk) } }
        }
        process.terminationHandler = { [weak self] p in
            let status = p.terminationStatus
            Task { @MainActor in self?.exited(status) }
        }
        try process.run()

        let deadline = Date().addingTimeInterval(30)
        while url == nil {
            if ended { throw SwapError(lastLine.isEmpty ? "claude auth login quit before it opened the sign-in page" : lastLine) }
            if Date() > deadline {
                close()
                throw SwapError("claude auth login didn't open its sign-in page")
            }
            if let s = try? String(contentsOf: urlFile, encoding: .utf8), let u = URL(string: s), u.scheme == "https" {
                url = u
            } else {
                try await Task.sleep(for: .milliseconds(200))
            }
        }
        if let url { show(url) }
    }

    /// Closes the window and stops the CLI; no callbacks.
    func close() {
        guard !ended else { return }
        ended = true
        closeWindows()
        if process.isRunning { process.terminate() }
        try? stdin.fileHandleForWriting.close()
        try? FileManager.default.removeItem(at: dir)
    }

    private func exited(_ status: Int32) {
        guard !ended else { return }
        ended = true
        closeWindows()
        try? FileManager.default.removeItem(at: dir)
        // Before the page is shown, start() reports the failure.
        if url != nil { onExit?(status, lastLine) }
    }

    private var lastLine: String {
        let text = String(decoding: output.withLock { $0 }, as: UTF8.self)
        return text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty } ?? ""
    }

    // MARK: Window

    /// A fresh cookie-less session.
    private static func privateConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        // Without the Safari token Google's sign-in refuses an embedded web view.
        config.applicationNameForUserAgent = "Version/\(safariVersion) Safari/605.1.15"
        return config
    }

    private func show(_ url: URL) {
        let web = WKWebView(frame: .zero, configuration: Self.privateConfiguration())
        web.navigationDelegate = self
        web.uiDelegate = self
        self.web = web
        // Single-page navigation (pushState) changes the URL without a page load.
        urlObservation = web.observe(\.url) { [weak self] web, _ in
            MainActor.assumeIsolated { self?.urlChanged(web.url) }
        }

        let footer = NSHostingView(rootView: EmailLinkFooter(state: emailLink) { [weak self] text in self?.linkPasted(text) })
        footer.sizingOptions = [.intrinsicContentSize]
        let content = NSView()
        for view in [web, footer] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: content.topAnchor),
            web.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            web.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        let window = makeWindow(content: content, size: NSSize(width: 520, height: 760))
        window.title = email.map { "Log In as \($0)" } ?? "Log In to Claude"
        window.subtitle = "Separate from your browser's sign-ins"
        let toolbar = NSToolbar(identifier: "login")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.center()
        self.window = window
        web.load(URLRequest(url: url))
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow(content: NSView, size: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        window.delegate = self
        return window
    }

    private func closeWindows() {
        let all = popups + [window].compactMap { $0 }
        popups = []
        window = nil
        urlObservation = nil
        web = nil
        linkReader = nil
        for w in all {
            w.delegate = nil
            w.close()
        }
    }

    /// Hands the same URL to the default browser; the CLI keeps waiting for it.
    @objc private func openInBrowser() {
        guard let url else { return }
        NSWorkspace.shared.open(url)
        closeWindows()
    }

    // MARK: Finishing the sign-in

    /// Text typed or pasted into the footer's field.
    private func linkPasted(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let link = URL(string: trimmed), link.scheme == "https",
              ["claude.ai", "claude.com"].contains(link.host ?? ""), link.path.hasPrefix("/magic-link") else {
            if trimmed.contains("://") { emailLink.phase = .failed("That isn't the sign-in link from Claude's email") }
            return
        }
        emailLink.text = ""
        readCode(from: link)
    }

    /// Opened in a session other than the one that asked for it, the link
    /// shows a code for that one. Open it out of sight, read the code and
    /// type it into the page; if no code turns up, hand the link to the browser.
    private func readCode(from link: URL) {
        let reader = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 640), configuration: Self.privateConfiguration())
        linkReader = reader
        emailLink.phase = .reading
        reader.load(URLRequest(url: link))
        Task {
            for _ in 0..<60 {
                try? await Task.sleep(for: .milliseconds(500))
                guard linkReader === reader else { return }
                let found = (try? await reader.evaluateJavaScript(Self.findCode)) as? String ?? ""
                guard linkReader === reader else { return }
                if found.hasPrefix("error:") {
                    linkReader = nil
                    emailLink.phase = .failed("\(found.dropFirst(6)) — request a new email")
                    return
                }
                if !found.isEmpty {
                    linkReader = nil
                    enter(code: found)
                    return
                }
            }
            guard linkReader === reader else { return }
            linkReader = nil
            NSWorkspace.shared.open(link)
            emailLink.phase = .failed("No code found, so the link opened in your browser")
        }
    }

    private func enter(code: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        emailLink.phase = .entered(code)
        window?.makeFirstResponder(web)
        // Digits only, so safe to splice into the script.
        web?.evaluateJavaScript(Self.fillCode.replacingOccurrences(of: "CODE", with: code), completionHandler: nil)
    }

    /// The code on the magic-link page: an element whose text is only 4–10
    /// digits (spaces and dashes aside, so a code split into boxes counts too).
    private static let findCode = """
    (() => {
        const text = document.body ? document.body.innerText : '';
        if (/not valid|invalid|expired/i.test(text)) return 'error:' + text.split('\\n')[0].slice(0, 80);
        for (const el of document.querySelectorAll('body *')) {
            if (['SCRIPT', 'STYLE', 'NOSCRIPT'].includes(el.tagName) || el.offsetParent === null) continue;
            const t = (el.innerText || '').replace(/[\\s-]/g, '');
            if (/^\\d{4,10}$/.test(t)) return t;
        }
        return '';
    })()
    """

    /// Types the code into the page's code field (one field, or a box per
    /// digit) the way a keyboard would, then presses its submit button if
    /// the form didn't submit itself.
    private static let fillCode = """
    (() => {
        const code = 'CODE';
        const skip = ['hidden', 'email', 'password', 'checkbox', 'radio', 'submit', 'button'];
        const inputs = [...document.querySelectorAll('input')].filter(i => i.offsetParent !== null && !skip.includes(i.type));
        if (!inputs.length) return;
        const type = (input, text) => {
            input.focus();
            try { input.select(); } catch (e) {}
            if (!document.execCommand('insertText', false, text) || !input.value) {
                const set = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
                set.call(input, text);
                input.dispatchEvent(new Event('input', { bubbles: true }));
                input.dispatchEvent(new Event('change', { bubbles: true }));
            }
        };
        if (inputs.length >= code.length && inputs.slice(0, code.length).every(i => i.maxLength === 1)) {
            [...code].forEach((c, k) => type(inputs[k], c));
        } else {
            type(inputs[0], code);
        }
        const form = location.href;
        setTimeout(() => {
            if (location.href !== form) return;
            const button = [...document.querySelectorAll('button')].find(b => !b.disabled && b.offsetParent !== null
                && /^(verify|continue|submit|confirm|log ?in|sign ?in)\\b/i.test(b.innerText.trim())
                && !/with (google|apple|email)|resend|back|different/i.test(b.innerText));
            if (button) button.click();
        }, 800);
    })()
    """

    /// Whatever way the user signed in, end up on the authorization page and approve it.
    private func urlChanged(_ current: URL?) {
        guard let current, let url, current.host == "claude.ai" else { return }
        let path = current.path
        if path.hasPrefix("/oauth/authorize") {
            approve()
            return
        }
        // Still signing in, or an error page that needs the user.
        let signingIn = ["/login", "/magic-link", "/sso", "/oauth", "/cai", "/api", "/verify"]
        guard !signingIn.contains(where: path.hasPrefix), returns < 2 else { return }
        // Signed in, but the page didn't lead back (a magic link lands on a new chat).
        returns += 1
        web?.load(URLRequest(url: url))
    }

    /// Clicks the page's Authorize button once it renders; the user can still click it if this misses.
    private func approve() {
        let script = """
        if (!window.__cvdApproved) {
            clearInterval(window.__cvdApprove);
            let tries = 0;
            window.__cvdApprove = setInterval(() => {
                const button = location.pathname.startsWith('/oauth/authorize') && [...document.querySelectorAll('button')]
                    .find(b => /^(authorize|allow|approve)$/i.test(b.innerText.trim()) && !b.disabled);
                if (button) {
                    clearInterval(window.__cvdApprove);
                    window.__cvdApproved = true;
                    button.click();
                } else if (++tries > 120) {
                    clearInterval(window.__cvdApprove);
                }
            }, 250);
        }
        """
        web?.evaluateJavaScript(script, completionHandler: nil)
    }

    // MARK: Toolbar

    private static let browserItem = NSToolbarItem.Identifier("openInBrowser")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, Self.browserItem] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, Self.browserItem] }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard id == Self.browserItem else { return nil }
        let button = NSButton(title: "Open in Browser", image: NSImage(systemSymbolName: "safari", accessibilityDescription: nil)!,
                              target: self, action: #selector(openInBrowser))
        button.bezelStyle = .texturedRounded
        button.imagePosition = .imageLeading
        let item = NSToolbarItem(itemIdentifier: id)
        item.view = button
        item.label = "Open in Browser"
        item.toolTip = "Continue in your browser instead: for a passkey, or a sign-in it already has"
        return item
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        guard closing === window else {
            popups.removeAll { $0 === closing }
            return
        }
        window = nil
        close()
        onCancel?()
    }

    // MARK: Pop-ups (Google and Apple sign-in open one)

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let size = NSSize(width: windowFeatures.width?.doubleValue ?? 500, height: windowFeatures.height?.doubleValue ?? 640)
        let popup = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: configuration)
        popup.navigationDelegate = self
        popup.uiDelegate = self
        let w = makeWindow(content: popup, size: size)
        if let parent = window {
            w.setFrameTopLeftPoint(NSPoint(x: parent.frame.minX + 40, y: parent.frame.maxY - 40))
        }
        popups.append(w)
        w.makeKeyAndOrderFront(nil)
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        popups.first { $0.contentView === webView }?.close()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let w = popups.first(where: { $0.contentView === webView }) { w.title = webView.title ?? "" }
        if webView === web, webView.url?.host == "claude.ai", webView.url?.path.hasPrefix("/oauth/authorize") == true { approve() }
    }

    // MARK: Helpers

    private static let safariVersion: String = {
        Bundle(path: "/Applications/Safari.app")?.infoDictionary?["CFBundleShortVersionString"] as? String ?? "18.6"
    }()

    private static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

// MARK: - Email link footer

@MainActor
final class EmailLinkState: ObservableObject {
    enum Phase: Equatable {
        case idle, reading, entered(String), failed(String)
    }
    @Published var text = ""
    @Published var phase = Phase.idle
}

/// The strip under the page: paste the email's link, watch the code go in.
private struct EmailLinkFooter: View {
    @ObservedObject var state: EmailLinkState
    let onChange: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                badge
                VStack(alignment: .leading, spacing: 2) {
                    Text("Logging in with email?")
                        .font(.system(size: 12, weight: .semibold))
                    Text(caption)
                        .font(.system(size: 11))
                        .foregroundStyle(captionColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            TextField("Paste the link from the email", text: $state.text)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .onChange(of: state.text) { _, text in onChange(text) }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .animation(.easeOut(duration: 0.15), value: state.phase)
    }

    private var badge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill(badgeColor.opacity(0.15))
            switch state.phase {
            case .reading:
                ProgressView().controlSize(.small)
            default:
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(badgeColor)
            }
        }
        .frame(width: 30, height: 30)
    }

    private var symbol: String {
        switch state.phase {
        case .idle, .reading: return "envelope"
        case .entered: return "checkmark"
        case .failed: return "exclamationmark.triangle"
        }
    }

    private var badgeColor: Color {
        switch state.phase {
        case .idle, .reading: return .accentColor
        case .entered: return .green
        case .failed: return .orange
        }
    }

    private var caption: String {
        switch state.phase {
        case .idle: return "Paste the link below — the code is read and entered for you"
        case .reading: return "Reading the code from the link…"
        case .entered(let code): return "Entered code \(code) · also on the clipboard"
        case .failed(let why): return why
        }
    }

    private var captionColor: Color {
        switch state.phase {
        case .failed: return .orange
        default: return .secondary
        }
    }
}
