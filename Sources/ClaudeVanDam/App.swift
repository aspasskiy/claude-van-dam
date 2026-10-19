import AppKit
import Combine
import SwapCore
import SwiftUI

@main
@MainActor
enum ClaudeVanDamApp {
    static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let store = Store()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
        }

        let host = NSHostingController(rootView: PopoverView().environmentObject(store))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        popover.delegate = self

        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.updateButton() }
            .store(in: &cancellables)

        store.start()
        updateButton()

        if CommandLine.arguments.contains("--show"), let button = statusItem.button {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.togglePopover(button) }
        }
        // Debug: `--render <dir> [--appearance light|dark]` writes
        // popover-<look>.png / tray-<look>.png and exits.
        if let dir = Self.argument("--render"), let button = statusItem.button {
            let look = Self.argument("--appearance") ?? "light"
            let appearance = NSAppearance(named: look == "dark" ? .darkAqua : .aqua)!
            NSApp.appearance = appearance
            let out = URL(fileURLWithPath: dir)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.togglePopover(button) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) {
                self.renderPopover(dark: look == "dark", to: out.appendingPathComponent("popover-\(look).png"))
                Self.renderTray(button, appearance: appearance, to: out.appendingPathComponent("tray-\(look).png"))
                NSApp.terminate(nil)
            }
        }
    }

    /// ImageRenderer blends translucent fills correctly (cacheDisplay does not);
    /// the popover's material is approximated with a flat background.
    private func renderPopover(dark: Bool, to url: URL) {
        let background = dark ? Color(red: 0.17, green: 0.17, blue: 0.18) : Color(red: 0.93, green: 0.93, blue: 0.94)
        let view = PopoverView()
            .environmentObject(store)
            .background(background)
            .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let cg = renderer.cgImage else { return }
        let rep = NSBitmapImageRep(cgImage: cg)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// The status button's image + title on a menu-bar-like strip.
    private static func renderTray(_ button: NSStatusBarButton, appearance: NSAppearance, to url: URL) {
        guard let icon = button.image else { return }
        let title = NSMutableAttributedString(attributedString: button.attributedTitle)
        let size = NSSize(width: 120, height: 24)
        let image = NSImage(size: size)
        image.lockFocus()
        appearance.performAsCurrentDrawingAppearance {
            let dark = appearance.name == .darkAqua
            (dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.92, alpha: 1)).setFill()
            NSRect(origin: .zero, size: size).fill()
            icon.draw(in: NSRect(x: 8, y: (size.height - icon.size.height) / 2, width: icon.size.width, height: icon.size.height))
            title.addAttribute(.foregroundColor, value: NSColor.labelColor, range: NSRange(location: 0, length: title.length))
            title.draw(at: NSPoint(x: 8 + icon.size.width, y: 4))
        }
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let out = NSBitmapImageRep(data: tiff) else { return }
        try? out.representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func argument(_ name: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if let event = NSApp.currentEvent,
           event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            popover.performClose(sender)
            showSettingsMenu()
            return
        }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate()
        }
    }

    // MARK: Right-click menu

    private func showSettingsMenu() {
        let menu = NSMenu()
        menu.addItem(item("Auto-Switch at \(Int(store.autoThreshold))%", checked: store.autoSwitch) { [store] in store.autoSwitch.toggle() })
        let at = NSMenuItem(title: "Switch At", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for value in [90.0, 95, 98, 99] {
            let label = value == 95 ? "95% (recommended)" : value >= 98 ? "\(Int(value))% (may hit the limit)" : "\(Int(value))%"
            sub.addItem(item(label, checked: store.autoThreshold == value) { [store] in store.autoThreshold = value })
        }
        at.submenu = sub
        menu.addItem(at)
        menu.addItem(.separator())
        menu.addItem(item("Keep Awake", checked: store.keepAwake) { [store] in store.keepAwake.toggle() })
        menu.addItem(item("Launch at Login", checked: LoginItem.isEnabled) { LoginItem.setEnabled(!LoginItem.isEnabled) })
        menu.addItem(.separator())
        menu.addItem(NSMenuItem.sectionHeader(title: "Menu Bar Shows"))
        for option in TrayText.allCases {
            menu.addItem(item(option.label, checked: store.trayText == option) { [store] in store.trayText = option })
        }
        menu.addItem(.separator())
        menu.addItem(item("Export Accounts…") { [weak self] in self?.exportAccounts() })
        menu.addItem(item("Import Accounts…") { [weak self] in self?.importAccounts() })
        menu.addItem(.separator())
        menu.addItem(item("Refresh") { [store] in store.refresh() })
        let quit = item("Quit \(AppInfo.name)") { NSApp.terminate(nil) }
        quit.keyEquivalent = "q"
        menu.addItem(quit)
        // Attach only for this click so a left click keeps opening the popover.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func exportAccounts() {
        let panel = NSSavePanel()
        let day = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        panel.nameFieldStringValue = "\(AppInfo.name) accounts \(day).json"
        panel.allowedContentTypes = [.json]
        panel.message = "The file holds your Claude logins in plain text. Keep it private, and after moving "
            + "to another Mac stop using these accounts here — a login refreshed on one Mac signs the other out."
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let service = SwapService()
        Task {
            let result = await Task.detached { Result { try service.exportAccounts(to: url) } }.value
            switch result {
            case .success(let n): Self.alert("Exported \(n) account\(n == 1 ? "" : "s")", url.path)
            case .failure(let e): Self.alert("Export failed", e.localizedDescription)
            }
        }
    }

    private func importAccounts() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a file exported by \(AppInfo.name)"
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let service = SwapService()
        Task { [store] in
            let result = await Task.detached { Result { try service.importAccounts(from: url) } }.value
            switch result {
            case .success(let r):
                var lines = ["Added: \(r.imported)", "Already here, kept: \(r.skipped)"]
                if r.replaced > 0 { lines.insert("Signed-out accounts restored: \(r.replaced)", at: 1) }
                if r.skipped > 0 { lines.append("Accounts that are already here and working were left as they are.") }
                if r.liveReplaced { lines.append("The current login wasn't changed — switch away and back to use the imported one.") }
                Self.alert("Import finished", lines.joined(separator: "\n"))
            case .failure(let e):
                Self.alert("Import failed", e.localizedDescription)
            }
            store.refresh()
        }
    }

    private static func alert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate()
        alert.runModal()
    }

    private func item(_ title: String, checked: Bool = false, _ action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(MenuAction.run), keyEquivalent: "")
        let target = MenuAction(action)
        item.target = target
        item.representedObject = target   // keeps the target alive
        item.state = checked ? .on : .off
        return item
    }

    func popoverWillShow(_ notification: Notification) { store.popoverVisible = true }
    func popoverDidClose(_ notification: Notification) { store.popoverVisible = false }

    private struct TrayState: Equatable {
        let five: Int?
        let seven: Int?
        let dimmed: Bool
        let awake: Bool
        let title: String
        let tip: String
    }

    private var trayState: TrayState?

    /// Called on every store change (the popover clock ticks each second), but
    /// the button is only touched when what it shows actually changes.
    private func updateButton() {
        guard let button = statusItem?.button else { return }
        let now = Date()
        let active = store.active
        let usage = active?.displayUsage
        let five = usage?.fiveHour.map { Int($0.effectivePct(at: now).rounded()) }
        let seven = usage?.sevenDay.map { Int($0.effectivePct(at: now).rounded()) }

        var parts: [String] = []
        let mode = store.trayText
        if mode == .account || mode == .both, let active {
            parts.append(active.alias ?? String(active.email.split(separator: "@").first ?? ""))
        }
        if mode == .percent || mode == .both, let tight = usage?.tightest(at: now) {
            parts.append(Fmt.pct(tight))
        }

        var tip = [AppInfo.name]
        if let active {
            tip.append("Active: \(active.title)")
            if let five { tip.append("Session: \(five)%") }
            if let seven { tip.append("Week: \(seven)%") }
        }

        if store.keepAwake { tip.append("Keeping the Mac awake") }

        let state = TrayState(five: five, seven: seven, dimmed: active == nil || active?.usage == nil,
                              awake: store.keepAwake, title: parts.joined(separator: " "), tip: tip.joined(separator: "\n"))
        guard state != trayState else { return }
        trayState = state

        button.image = StatusIcon.image(fiveHour: state.five.map(Double.init), sevenDay: state.seven.map(Double.init),
                                        dimmed: state.dimmed)
        button.attributedTitle = NSAttributedString(
            string: state.title.isEmpty ? "" : " " + state.title,
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)]
        )
        button.toolTip = state.tip
    }
}

private final class MenuAction: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func run() { action() }
}
