import SwapCore
import SwiftUI

struct PopoverView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let others = store.accounts.filter { !$0.active }
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

            if let error = store.error {
                Banner(text: error, systemImage: "exclamationmark.triangle.fill", tint: .red) { store.dismissError() }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
            if let notice = store.notice {
                Banner(text: notice, systemImage: "checkmark.circle.fill", tint: .green, onClose: nil)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }

            if store.accounts.isEmpty {
                emptyState
            } else {
                if let active = store.active {
                    ActiveSection(account: active)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 14)
                }
                Divider().padding(.horizontal, 16)
                VStack(spacing: 2) {
                    ForEach(others) { AccountRow(account: $0) }
                    if let email = store.unmanagedLogin, store.loginPending == nil {
                        UnmanagedLoginRow(email: email)
                    }
                    AddAccountRow()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
        }
        .frame(width: 320)
        .animation(.easeInOut(duration: 0.2), value: store.notice)
        .animation(.easeInOut(duration: 0.2), value: store.error)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Claude").font(.system(size: 13, weight: .semibold))
            if let last = store.lastRefresh {
                Text("· \(Fmt.ago(last, now: store.now))")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if store.autoSwitch {
                Label("Auto \(Int(store.autoThreshold))%", systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 10.5))
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                    .help("Switches to the account with the most room at \(Int(store.autoThreshold))%, or earlier if usage is climbing fast. Right-click the menu bar icon to change.")
            }
            IconButton(systemImage: "arrow.clockwise", help: "Refresh", busy: store.refreshing) { store.refresh() }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            if store.refreshing {
                ProgressView().controlSize(.small)
            } else {
                Text("No accounts yet").font(.system(size: 12, weight: .medium))
                Text("Click Add account below to log in")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 110)
    }

}

// MARK: - Active account

private struct ActiveSection: View {
    let account: Account
    @EnvironmentObject var store: Store

    var body: some View {
        let usage = account.displayUsage
        let now = store.now
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Circle().fill(Color.green).frame(width: 6, height: 6)
                Text(account.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let sub = account.subtitle {
                    Text(sub).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            if let usage {
                HStack(alignment: .top, spacing: 0) {
                    Gauge(title: "Session", window: usage.fiveHour, weekly: false)
                        .frame(maxWidth: .infinity)
                    Gauge(title: "Week", window: usage.sevenDay, weekly: true)
                        .frame(maxWidth: .infinity)
                }
                .opacity(account.isStale ? 0.5 : 1)

                if !usage.scoped.isEmpty || usage.spend != nil {
                    VStack(spacing: 7) {
                        ForEach(usage.scoped) { w in
                            LineMeter(label: w.name ?? "Model", pct: w.effectivePct(at: now),
                                      trailing: w.resetsAt.map { Fmt.countdown(to: $0, from: now) })
                        }
                        if let spend = usage.spend {
                            LineMeter(label: "Extra", pct: spend.pct,
                                      trailing: String(format: "%.0f/%.0f %@", spend.used, spend.limit, spend.currency))
                        }
                    }
                }

                if let hint = paceHint(usage.sevenDay, now: now) {
                    Text(hint)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
            }
            if let note = account.note(now: now) {
                Text(note).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private func paceHint(_ w: UsageWindow?, now: Date) -> String? {
        guard let w, !w.hasRolled(at: now), w.pct < 100 else { return nil }
        if w.willLastToReset == false, let end = w.projectedExhaustionAt, end > now {
            return "At this pace the week runs out \(Fmt.clock(end, now: now))"
        }
        if w.aheadOfPace == true { return "Ahead of an even weekly pace" }
        return nil
    }
}

private struct Gauge: View {
    let title: String
    let window: UsageWindow?
    let weekly: Bool
    @EnvironmentObject var store: Store

    var body: some View {
        let now = store.now
        let pct = window?.effectivePct(at: now) ?? 0
        let rolled = window?.hasRolled(at: now) ?? false
        VStack(spacing: 8) {
            ZStack {
                Ring(pct: pct, expected: weekly && !rolled ? window?.expectedPct : nil)
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("\(Int(pct.rounded()))")
                        .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText())
                    Text("%").font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 76, height: 76)
            VStack(spacing: 2) {
                Text(title).font(.system(size: 11, weight: .medium))
                Group {
                    if rolled {
                        Text("reset")
                    } else if let reset = window?.resetsAt {
                        Text("\(Fmt.countdown(to: reset, from: now)) · \(Fmt.clock(reset, now: now))")
                    } else {
                        Text("not started")
                    }
                }
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
        .animation(.spring(duration: 0.5), value: pct)
    }
}

private struct Ring: View {
    let pct: Double
    let expected: Double?
    private let line: CGFloat = 5

    var body: some View {
        let fraction = min(max(pct, 0), 100) / 100
        ZStack {
            Circle().stroke(Color.primary.opacity(0.08), lineWidth: line)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(Level(pct).color, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if let expected, expected > 0, expected < 100, pct < 100 {
                // Even-pace marker: where usage would be if spread evenly over the week.
                Capsule()
                    .fill(Color.primary.opacity(0.55))
                    .frame(width: 1.5, height: line + 4)
                    .offset(y: -38 + line / 2)
                    .rotationEffect(.degrees(360 * expected / 100))
                    .help("Even pace: \(Fmt.pct(expected))")
            }
        }
        .padding(line / 2)
    }
}

private struct LineMeter: View {
    let label: String
    let pct: Double
    let trailing: String?

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
                .lineLimit(1)
            Bar(pct: pct)
            Text(Fmt.pct(pct))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .frame(width: 32, alignment: .trailing)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 52, alignment: .trailing)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Other accounts

private struct AccountRow: View {
    let account: Account
    @EnvironmentObject var store: Store
    @State private var hover = false

    var body: some View {
        let now = store.now
        let usage = account.displayUsage
        let five = usage?.fiveHour?.effectivePct(at: now)
        let seven = usage?.sevenDay?.effectivePct(at: now)
        let exhausted = (usage?.tightest(at: now) ?? 0) >= 100
        let signedOut = account.status == .reloginRequired
        let waiting = store.loginPending == account.email
        Button {
            if signedOut { store.logIn(email: account.email) } else { store.switchTo(account.number) }
        } label: {
            HStack(spacing: 10) {
                Avatar(account: account)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(account.title)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if account.disabled {
                            Text("paused").font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 0)
                    }
                    Text(waiting ? "Waiting for the browser login…" : caption(usage: usage, now: now, exhausted: exhausted) ?? " ")
                        .font(.system(size: 10.5))
                        .foregroundStyle(account.problem != nil ? Color.orange : Color.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    MiniStat(pct: five)
                    MiniStat(pct: seven)
                }
                .opacity(account.isStale ? 0.5 : 1)
                ZStack {
                    if store.switching == account.number || waiting {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: signedOut ? "person.badge.key" : "arrow.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .opacity(hover ? 1 : 0)
                    }
                }
                .frame(width: 14)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(hover ? 0.06 : 0)))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(store.switching != nil || (store.loginPending != nil && !waiting))
        .opacity(account.disabled ? 0.55 : 1)
        .onHover { h in withAnimation(.easeOut(duration: 0.1)) { hover = h } }
        .help(signedOut ? "Log in to \(account.title) again" : "Switch to \(account.title)")
        .contextMenu {
            if signedOut {
                Button("Log In Again") { store.logIn(email: account.email) }
            } else {
                Button("Switch to This Account") { store.switchTo(account.number) }
            }
            Divider()
            Button("Remove…", role: .destructive) { store.confirmRemove(account) }
        }
    }

    private func caption(usage: Usage?, now: Date, exhausted: Bool) -> String? {
        if let note = account.note(now: now) { return note }
        guard let usage else { return nil }
        if exhausted {
            let resets = [usage.fiveHour, usage.sevenDay].compactMap { $0 }
                .filter { $0.effectivePct(at: now) >= 100 }.compactMap(\.resetsAt)
            return resets.max().map { "Back in \(Fmt.countdown(to: $0, from: now))" } ?? "Limit reached"
        }
        if let w = usage.sevenDay, let reset = w.resetsAt, !w.hasRolled(at: now) {
            return "Week resets in \(Fmt.countdown(to: reset, from: now))"
        }
        return nil
    }
}

/// "+ Add account": runs `claude auth login` in Terminal and stores the result.
private struct AddAccountRow: View {
    @EnvironmentObject var store: Store
    @State private var hover = false

    var body: some View {
        let waiting = store.loginPending == ""
        HStack(spacing: 10) {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 24, height: 24)
                .background(Circle().strokeBorder(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [2.5, 2])))
            Text(waiting ? "Waiting for the browser login…" : "Add account")
                .font(.system(size: 12))
            Spacer(minLength: 0)
            if waiting {
                ProgressView().controlSize(.mini)
                Button("Cancel") { store.cancelLogin() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(hover && !waiting ? Color.primary : Color.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(hover && !waiting ? 0.06 : 0)))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture { if !waiting { store.logIn(email: nil) } }
        .onHover { h in withAnimation(.easeOut(duration: 0.1)) { hover = h } }
        .opacity(store.loginPending != nil && !waiting ? 0.4 : 1)
        .help("Log in with another Claude account in your browser")
    }
}

/// Claude Code is logged in as an account that isn't saved yet (a bare /login).
private struct UnmanagedLoginRow: View {
    let email: String
    @EnvironmentObject var store: Store

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 13))
                .foregroundStyle(.orange)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(email).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                Text("Logged in but not saved").font(.system(size: 10.5)).foregroundStyle(.orange)
            }
            Spacer(minLength: 0)
            Button(store.adding ? "Saving…" : "Save") { store.addCurrentLogin() }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .disabled(store.adding)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

/// Session / week as a tiny vertical pair: bar + number.
private struct MiniStat: View {
    let pct: Double?

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(pct.map(Fmt.pct) ?? "—")
                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
            Bar(pct: pct ?? 0, height: 3)
        }
        .frame(width: 34)
    }
}

// MARK: - Building blocks

private struct Bar: View {
    let pct: Double
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                if pct > 0 {
                    Capsule()
                        .fill(Level(pct).color)
                        .frame(width: max(height, geo.size.width * min(pct, 100) / 100))
                }
            }
        }
        .frame(height: height)
        .animation(.spring(duration: 0.5), value: pct)
    }
}

private struct Avatar: View {
    let account: Account

    var body: some View {
        Text(account.initial)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(Color(hue: account.avatarHue, saturation: 0.6, brightness: 0.75))
            .frame(width: 24, height: 24)
            .background(Circle().fill(Color(hue: account.avatarHue, saturation: 0.5, brightness: 0.9).opacity(0.18)))
            .help("Slot \(account.number)")
    }
}

private struct IconButton: View {
    let systemImage: String
    let help: String
    var busy = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Group {
                if busy {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: systemImage).font(.system(size: 11, weight: .medium))
                }
            }
            .frame(width: 22, height: 22)
            .background(Circle().fill(Color.primary.opacity(hover ? 0.08 : 0)))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { hover = $0 }
        .help(help)
    }
}

private struct Banner: View {
    let text: String
    let systemImage: String
    let tint: Color
    let onClose: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(tint).font(.system(size: 11))
            Text(text).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let onClose {
                Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.1)))
        .transition(.opacity)
    }
}

