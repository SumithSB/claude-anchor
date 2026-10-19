import SwiftUI
import AppKit
import ServiceManagement

enum Pane: Hashable { case accounts, rules, settings }

func abbreviate(_ path: String) -> String {
    path.hasPrefix(Paths.home) ? "~" + path.dropFirst(Paths.home.count) : path
}

private func compact(_ n: Int) -> String {
    n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1e6) : n >= 1000 ? "\(Int((Double(n) / 1000).rounded()))k" : "\(n)"
}

private func resetText(_ d: Date?) -> String {
    guard let d else { return "" }
    let s = d.timeIntervalSinceNow
    if s <= 0 { return "Resets now" }
    if s < 86_400 { let m = Int(s / 60); return m >= 60 ? "Resets in \(m / 60)h \(m % 60)m" : "Resets in \(m)m" }
    return "Resets " + d.formatted(.dateTime.weekday(.abbreviated))
}

/// Offscreen snapshots can't render the window material, so only they paint a background.
struct SnapshotKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues { var snapshotMode: Bool { get { self[SnapshotKey.self] } set { self[SnapshotKey.self] = newValue } } }

/// Back action for the pane header.
struct PaneBackKey: EnvironmentKey { static let defaultValue: @MainActor () -> Void = {} }
extension EnvironmentValues { var paneBack: @MainActor () -> Void { get { self[PaneBackKey.self] } set { self[PaneBackKey.self] = newValue } } }

/// True when the popover content is hosted in the resizable standalone window.
struct PopoutKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues { var isPopout: Bool { get { self[PopoutKey.self] } set { self[PopoutKey.self] = newValue } } }

private let gutter: CGFloat = 16

// MARK: shared building blocks

/// Rounded surface with a hairline border.
private extension View {
    func card(_ pad: CGFloat = 14, fill: Color = Clay.surface, stroke: Color = Clay.hairline, radius: CGFloat = 16) -> some View {
        self.padding(pad)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(stroke, lineWidth: 1))
    }
}

/// Uppercase tracked section caption.
private struct Caption: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.8)
            .foregroundStyle(.secondary).lineLimit(1)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Rounded `.quaternary` highlight under the pointer, as in Control Center rows.
private struct HoverHighlight: ViewModifier {
    @State private var hover = false
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hover ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear)))
            .contentShape(Rectangle())
            .onHover { hover = $0 }
    }
}
private extension View { func hoverHighlight() -> some View { modifier(HoverHighlight()) } }

/// Filled pill button used for primary actions.
struct ClayButtonStyle: ButtonStyle {
    var fill: Color = Clay.accentFill
    var ink: Color = Clay.accentInk
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(ink)
            .padding(.horizontal, 12).frame(minHeight: 30)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(fill))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// Small pill segmented control (range and group-by).
private struct Seg<T: Hashable>: View {
    let label: String
    let options: [(label: String, value: T)]
    @Binding var selection: T
    var fill = false
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                let o = options[i]
                let on = selection == o.value
                Button { selection = o.value } label: {
                    Text(o.label).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                        .padding(.horizontal, 9).frame(height: 22)
                        .frame(maxWidth: fill ? CGFloat.infinity : nil)
                        .foregroundStyle(on ? Color.primary : Color.secondary)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(on ? AnyShapeStyle(Clay.surface) : AnyShapeStyle(Color.clear)))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(on ? Clay.hairline : Color.clear, lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(o.label)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Clay.surface2))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

/// Plan / small status pill.
private struct Pill: View {
    let text: String
    var tint: Color = .secondary
    var body: some View {
        Text(text).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(tint).lineLimit(1).fixedSize()
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.12)))
    }
}

/// Header icon button.
private struct IconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12.5, weight: .medium)).frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Clay.surface))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Clay.hairline, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(label).accessibilityLabel(label)
    }
}

/// Refresh button: spins while a refresh is in flight and is disabled meanwhile.
struct RefreshButton: View {
    let busy: Bool
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Button(action: action) {
            TimelineView(.animation(paused: !busy || reduceMotion)) { ctx in
                let angle = busy && !reduceMotion ? ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) * 360 : 0
                Image(systemName: "arrow.clockwise").font(.system(size: 12.5, weight: .medium))
                    .rotationEffect(.degrees(angle))
                    .opacity(busy && reduceMotion ? 0.4 : 1)
            }
            .frame(width: 28, height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Clay.surface))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Clay.hairline, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(busy).help("Refresh limits")
        .accessibilityLabel("Refresh limits")
        .accessibilityValue(busy ? "Refreshing" : "")
    }
}

/// Full-width menu-extra row: optional SF Symbol, title, optional trailing hint.
@MainActor struct MenuRow: View {
    let title: String
    var symbol: String?
    var hint: String?
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 13)).frame(width: 18)
                        .foregroundStyle(.secondary).accessibilityHidden(true)
                }
                Text(title).lineLimit(1)
                Spacer(minLength: 8)
                if let hint { Text(hint).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 8).frame(height: 28)
            .hoverHighlight()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

private struct NavButton: View {
    let title: String?
    let symbol: String
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 12)).accessibilityHidden(true)
                if let title { Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1).fixedSize() }
            }
            .foregroundStyle(Color.primary.opacity(0.8))
            .frame(maxWidth: .infinity).frame(height: 32)
            .hoverHighlight()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// MARK: popover

/// Rounds the menu bar window to the card radius; the stock MenuBarExtra window has near-square corners.
private struct RoundedWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ v: NSView, context: Context) {}
    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let w = window, let frame = w.contentView?.superview ?? w.contentView else { return }
            w.isOpaque = false
            w.backgroundColor = .clear
            frame.wantsLayer = true
            frame.layer?.cornerRadius = 16
            frame.layer?.cornerCurve = .continuous
            frame.layer?.masksToBounds = true
            w.invalidateShadow()
        }
    }
}

@MainActor struct PopoverView: View {
    @State private var path: [Pane]
    let popout: Bool
    init(path: [Pane] = [], popout: Bool = false) {
        _path = State(initialValue: path)
        self.popout = popout
    }
    var body: some View {
        // A plain switch, not NavigationStack: the stack keeps Home in the layout, so the menu window
        // stayed Home-sized behind every pane.
        Group {
            switch path.last {
            case .accounts: AccountsPane()
            case .rules: RulesPane()
            case .settings: SettingsPane()
            case nil: PopoverHome(path: $path)
            }
        }
        .environment(\.paneBack, { if !path.isEmpty { path.removeLast() } })
        .environment(\.isPopout, popout)
        .background { if !popout { RoundedWindow() } }
        .frame(width: popout ? nil : 340)
        .frame(minWidth: popout ? 340 : nil, maxWidth: popout ? CGFloat.infinity : nil, maxHeight: popout ? CGFloat.infinity : nil)
        .background(Clay.paper)
    }
}

@MainActor struct PopoverHome: View {
    @Environment(AppModel.self) private var model
    @Environment(\.isPopout) private var popout
    @Environment(\.snapshotMode) private var snapshot
    @Binding var path: [Pane]
    @State private var showAllRows = false

    var body: some View {
        Group {
            if snapshot { content } else if popout { ScrollView { content }.scrollIndicators(.never) } else {
                // Same fixed height as the panes, so the menu window never changes size.
                ScrollView { content }.scrollIndicators(.never).frame(height: 640)
            }
        }
        .onAppear { model.refreshEnvironment(); model.refreshIfStale() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            model.refreshEnvironment(); model.refreshIfStale()
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if !model.cliInstalled {
                emptyState("Claude Code isn't installed.", "Install it, then reopen this menu.", "Open install guide") {
                    if let u = URL(string: "https://docs.anthropic.com/en/docs/claude-code/setup") { NSWorkspace.shared.open(u) }
                }
                alertCard
            } else if model.accounts.isEmpty {
                emptyState("Add an account to start", "Each account keeps its own limits and usage.", "Add account") { path.append(.accounts) }
                alertCard
            } else {
                HarborView(width: 340 - 2 * gutter).frame(maxWidth: .infinity)
                if model.banner != nil { alertCard } else { FreshCard() }
                if popout { usageCard; accountCard } else { accountCard; usageCard }
                ContinueCard()
            }
            nav
        }
        .padding(.horizontal, gutter).padding(.top, 14).padding(.bottom, 10)
    }

    // MARK: header

    private var routingText: String {
        let n = model.accounts.count
        return "Routing \(n) \(n == 1 ? "account" : "accounts")"
    }

    private var header: some View {
        HStack(spacing: 10) {
            AnchorGlyph().stroke(Clay.accentInk, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                .frame(width: 14, height: 16)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Clay.accentFill))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Claude Anchor").font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text(routingText).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                if !model.lastRefreshedText.isEmpty {
                    Text(model.lastRefreshedText).font(.system(size: 11))
                        .foregroundStyle(model.isOutdated ? Clay.amber : Color.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if popout {
                Button { PopoutController.shared.close() } label: {
                    Label("Dock", systemImage: "arrow.down.right.and.arrow.up.left").font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 9).frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Clay.surface))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Clay.hairline, lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("Dock back to the menu bar").accessibilityLabel("Dock back to the menu bar")
            } else {
                IconButton(symbol: "arrow.up.forward.app", label: "Pop out into a window") { PopoutController.shared.show(model) }
            }
            RefreshButton(busy: model.isRefreshing) { model.refreshNow() }
        }
        .frame(minHeight: 34)
    }

    // MARK: empty and alert states

    /// Stands in for the harbor: a quiet mark, one sentence, one action.
    private func emptyState(_ title: String, _ detail: String, _ action: String, _ run: @escaping () -> Void) -> some View {
        VStack(spacing: 6) {
            AnchorGlyph().stroke(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                .frame(width: 22, height: 24).padding(.bottom, 6)
            Text(title).font(.body.weight(.semibold))
            Text(detail).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button(action, action: run).controlSize(.small).padding(.top, 6)
        }
        .frame(maxWidth: .infinity, minHeight: 156)
    }

    /// Prefers a fresh account as the place to anchor next.
    private var alertTarget: Account? { model.freshAccounts.first { $0.id != model.active?.id } }

    @ViewBuilder private var alertCard: some View {
        if let b = model.banner {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 14)).foregroundStyle(Clay.amber)
                    .padding(.top, 1).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    Text(b).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
                    if let f = alertTarget {
                        Button { model.setDefault(f.id) } label: {
                            Text("Anchor at \(f.name)").lineLimit(1)
                        }
                        .buttonStyle(ClayButtonStyle())
                        .accessibilityLabel("Anchor at \(f.name)")
                    } else if let id = model.overflowSuggestion, let t = model.account(id) {
                        Button { model.continueSession(on: id) } label: {
                            Text("Continue this conversation on \(t.name)").lineLimit(1)
                        }
                        .buttonStyle(ClayButtonStyle())
                        .accessibilityLabel("Continue this conversation on \(t.name)")
                    }
                }
                Spacer(minLength: 0)
                Button { model.banner = nil } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        .frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("Dismiss").accessibilityLabel("Dismiss message")
            }
            .card(12, fill: Clay.amber.opacity(0.10), stroke: Clay.amber.opacity(0.28))
            .accessibilityElement(children: .contain)
        }
    }

    /// Shown when the default account hasn't signed in yet (first run, or after signing out).
    private func signInBlock(_ a: Account) -> some View {
        let first = model.accounts.allSatisfy(\.pending)
        return VStack(alignment: .leading, spacing: 6) {
            Text(first ? "Sign in to get started" : "\(a.name) isn't signed in").font(.callout.weight(.semibold))
            Text("Anchor reads your Claude Code sign-in to show limits and usage.").font(.subheadline).foregroundStyle(.secondary)
            if model.signingIn.contains(a.id) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Finish signing in in your browser").font(.subheadline).foregroundStyle(.secondary)
                    Button("Cancel") { model.cancelSignIn(a.id) }.controlSize(.small)
                }
            } else {
                Button("Sign in with browser") { model.signIn(a.id) }.controlSize(.small)
            }
        }
    }

    // MARK: active account and limits

    @ViewBuilder private var accountCard: some View {
        if let a = model.active {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    FlagView(flag: a.flag, size: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(a.name).font(.system(size: 13.5, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                        if let e = a.email { Text(e).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                    }
                    Spacer(minLength: 6)
                    if let p = a.plan, !a.pending { Pill(text: p.capitalized) }
                }
                .accessibilityElement(children: .combine)
                Rectangle().fill(Clay.hairline).frame(height: 1)
                limitsBlock(a)
            }
            .card(14)
        }
    }

    @ViewBuilder private func limitsBlock(_ a: Account) -> some View {
        if a.pending {
            signInBlock(a)
        } else if let l = model.limits[a.id] {
            if let err = l.error {
                HStack {
                    Text(err).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                    if l.needsSignIn { Button("Sign in again") { model.signIn(a.id) }.controlSize(.small) }
                }
            } else {
                HStack(alignment: .top, spacing: 8) {
                    Ring(title: "5-hour", window: l.fiveHour, stale: l.stale)
                    Ring(title: "Weekly", window: l.weekly, stale: l.stale)
                }
                if let n = l.note { Text(n).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
            }
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Checking limits…").font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: usage

    private var usageCard: some View {
        let rows = model.usageRows
        let total = rows.reduce(0) { $0 + $1.tokens }
        let cost = rows.reduce(0.0) { $0 + $1.cost }
        let prices = model.showsAPIPrices
        let top = max(1, rows.map(\.tokens).max() ?? 1)
        let shown = showAllRows ? rows : Array(rows.prefix(4))
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Caption("Usage")
                Spacer(minLength: 8)
                Seg(label: "Range",
                    options: [("Today", 1), ("7 days", 7), ("30 days", 30)],
                    selection: Binding(get: { model.rangeDays }, set: { model.rangeDays = $0 }))
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(compact(total)).font(.system(size: 28, weight: .light)).monospacedDigit()
                Text(prices ? "tokens · ≈" + String(format: "$%.2f", cost) : "tokens")
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Total usage")
            .accessibilityValue(prices ? "\(compact(total)) tokens, about \(String(format: "$%.2f", cost)) at API prices" : "\(compact(total)) tokens")
            Seg(label: "Group by",
                options: GroupBy.allCases.map { (label: $0.rawValue, value: $0) },
                selection: Binding(get: { model.groupBy }, set: { model.groupBy = $0 }), fill: true)
            if rows.isEmpty {
                Text("No Claude Code usage yet in this range.").font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            } else {
                VStack(spacing: 9) {
                    ForEach(shown) { row($0, top: top, prices: prices) }
                }
                if rows.count > 4 {
                    Button { showAllRows.toggle() } label: {
                        Text(showAllRows ? "Show fewer" : "Show all \(rows.count)").font(.system(size: 12, weight: .medium)).foregroundStyle(Clay.accentText)
                            .frame(maxWidth: .infinity).frame(height: 24).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(showAllRows ? "Show fewer usage rows" : "Show all \(rows.count) usage rows")
                }
                if prices {
                    Text("≈ is the API price of this usage, not your bill.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .card(14)
    }

    private func row(_ r: UsageRow, top: Int, prices: Bool) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                if let id = r.accountID, let a = model.account(id) { FlagView(flag: a.flag, size: 11) }
                Text(r.label).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Text(compact(r.tokens)).monospacedDigit().fixedSize()
                if prices {
                    Text(String(format: "≈$%.2f", r.cost)).monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .trailing).fixedSize()
                        .help("What this usage would cost at API prices.")
                }
            }
            .font(.system(size: 12.5))
            Capsule().fill(Color.primary.opacity(0.07)).frame(height: 4)
                .overlay(alignment: .leading) {
                    GeometryReader { g in
                        Capsule().fill(Clay.accent).frame(width: max(3, g.size.width * CGFloat(r.tokens) / CGFloat(top)))
                    }
                }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(r.label)
        .accessibilityValue(prices ? "\(compact(r.tokens)) tokens, about \(String(format: "$%.2f", r.cost))" : "\(compact(r.tokens)) tokens")
    }

    // MARK: navigation

    private var nav: some View {
        HStack(spacing: 2) {
            NavButton(title: "Accounts", symbol: "person.2", label: "Accounts") { path.append(.accounts) }
            NavButton(title: "Rules", symbol: "folder", label: "Folder rules") { path.append(.rules) }
            NavButton(title: "Settings", symbol: "gearshape", label: "Settings") { path.append(.settings) }
            NavButton(title: nil, symbol: "power", label: "Quit Claude Anchor") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q").frame(width: 36).help("Quit Claude Anchor")
        }
        .padding(.top, 8)
        .overlay(alignment: .top) { Rectangle().fill(Clay.hairline).frame(height: 1) }
    }
}

/// Progress ring with the percent in the centre and the reset time beneath.
private struct Ring: View {
    let title: String
    let window: LimitWindow?
    let stale: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let p = min(100, max(0, window?.percent ?? 0))
        let reset = resetText(window?.resetsAt) + (stale ? " (cached)" : "")
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.12), lineWidth: 7)
                if p > 0 {
                    Circle().trim(from: 0, to: CGFloat(p / 100))
                        .stroke(Clay.gradient(p), style: StrokeStyle(lineWidth: 7, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(reduceMotion ? nil : Animation.easeOut(duration: 0.5), value: p)
                }
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("\(Int(p.rounded()))").font(.system(size: 22, weight: .light)).monospacedDigit()
                        .foregroundStyle(p >= 90 ? Clay.limit : Color.primary)
                    Text("%").font(.system(size: 11, weight: .light)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 76, height: 76)
            VStack(spacing: 2) {
                Text(title).font(.system(size: 12.5, weight: .medium))
                Text(reset).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) limit")
        .accessibilityValue("\(Int(p.rounded())) percent used. \(reset)")
    }
}

// MARK: fresh and continue cards

/// Teal card: another account has an unused 5-hour window.
@MainActor struct FreshCard: View {
    var compact = false
    @Environment(AppModel.self) private var model
    init(compact: Bool = false) { self.compact = compact }

    var body: some View {
        let fresh = model.freshAccounts
        if fresh.isEmpty, model.activeIsFresh, let a = model.active {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 15)).foregroundStyle(Clay.fresh).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(a.name) has a full 5-hour window").font(.system(size: 13, weight: .semibold))
                    Text("Your limit just reset. You're good to go.").font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
            .card(compact ? 10 : 12, fill: Clay.fresh.opacity(0.10), stroke: Clay.fresh.opacity(0.30))
            .accessibilityElement(children: .combine)
        } else if !fresh.isEmpty {
            // One line of chips, not a button per account: three fresh accounts used to take a third of the menu.
            let shown = Array(fresh.prefix(3))
            VStack(alignment: .leading, spacing: compact ? 6 : 8) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(Clay.fresh)
                        .accessibilityHidden(true)
                    Text("Full 5-hour window on").font(.system(size: 12.5, weight: .semibold))
                    Spacer(minLength: 0)
                    Text("Click to anchor").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    ForEach(shown) { f in
                        Button { model.setDefault(f.id) } label: {
                            HStack(spacing: 5) {
                                FlagView(flag: f.flag, size: 9)
                                Text(f.name).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                            }
                            .foregroundStyle(Clay.freshInk)
                            .padding(.horizontal, 9).frame(height: 24)
                            .background(Clay.fresh, in: Capsule())
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("Anchor at \(f.name)")
                        .accessibilityLabel("Anchor at \(f.name)")
                    }
                    if fresh.count > shown.count {
                        Text("+\(fresh.count - shown.count)").font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }
            .card(compact ? 10 : 12, fill: Clay.fresh.opacity(0.10), stroke: Clay.fresh.opacity(0.30))
            .accessibilityElement(children: .contain)
        }
    }
}

/// Continue the last conversation on another account.
@MainActor struct ContinueCard: View {
    var compact = false
    @Environment(AppModel.self) private var model
    @State private var picked: String?
    @State private var doneID: String?
    init(compact: Bool = false) { self.compact = compact }

    var body: some View {
        if let s = model.lastSession { content(s) }
    }

    private func content(_ s: LastSession) -> some View {
        let src = model.account(s.accountID)
        let targets = model.continueTargets.filter { $0.id != s.accountID }
        let sel = targets.first { $0.id == picked } ?? targets.first
        return VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            Caption("Last conversation")
            HStack(spacing: 6) {
                Image(systemName: "folder").font(.system(size: 12)).foregroundStyle(.secondary).accessibilityHidden(true)
                Text(abbreviate(s.cwd)).font(.system(size: 12.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if let src {
                    FlagView(flag: src.flag, size: 11)
                    Text("on \(src.name)").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: 110, alignment: .leading)
                }
            }
            .accessibilityElement(children: .combine)
            if let d = doneID, let t = model.account(d) {
                doneRow(t, src: src, session: s)
            } else if targets.isEmpty {
                Text("Add a second account to continue a conversation there when this one runs out.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if let sel {
                Picker("Continue on", selection: Binding(get: { sel.id }, set: { picked = $0 })) {
                    ForEach(targets) { t in Text(tag(t).isEmpty ? t.name : "\(t.name) · \(tag(t))").tag(t.id) }
                }
                .pickerStyle(.menu).labelsHidden().frame(maxWidth: .infinity)
                Button {
                    model.continueSession(on: sel.id)
                    if model.banner == nil { doneID = sel.id }
                } label: {
                    HStack(spacing: 7) {
                        if let src { FlagView(flag: src.flag, size: 10) }
                        Image(systemName: "arrow.right").font(.system(size: 10, weight: .bold))
                        FlagView(flag: sel.flag, size: 10)
                        Text("Continue on \(sel.name)").lineLimit(1).truncationMode(.tail)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(ClayButtonStyle())
                .disabled(s.file == nil)
                .help(s.editor ? "Anchors at \(sel.name), then reopens the conversation in VS Code on it."
                               : "Opens in a new Terminal tab with the full history.")
                .accessibilityLabel("Continue on \(sel.name)")
            }
        }
        .card(compact ? 10 : 14)
        .accessibilityElement(children: .contain)
    }

    private func tag(_ t: Account) -> String {
        if model.isFresh(t.id) { return "Fresh" }
        return model.limits[t.id]?.fiveHour.map { "\(Int($0.percent.rounded()))% used" } ?? ""
    }

    private func doneRow(_ t: Account, src: Account?, session s: LastSession) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Clay.fresh).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.editor ? "Anchored at \(t.name)." : "Reopened on \(t.name) in Terminal.")
                    .font(.system(size: 12.5, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                // A running tab keeps its account, so it has to close before the link can reopen it on the new one.
                Text(s.editor ? "Close the conversation's tab in VS Code, then reopen it here. It continues on \(t.name) with its history."
                              : "Full history carried over. The old one stays on \(src?.name ?? "the original account").")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if s.editor {
                    Button("Reopen in VS Code") { model.reopenInEditor(s) }
                        .controlSize(.small).padding(.top, 4)
                        .accessibilityLabel("Reopen the conversation in VS Code on \(t.name)")
                }
            }
            Spacer(minLength: 4)
            Button("Done") { doneID = nil }.controlSize(.small).accessibilityLabel("Done")
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Clay.fresh.opacity(0.10)))
        .accessibilityElement(children: .contain)
    }
}

// MARK: shared pane chrome

@MainActor struct PaneHeader: View {
    let title: String
    @Environment(\.paneBack) private var back
    var body: some View {
        HStack(spacing: 10) {
            IconButton(symbol: "chevron.left", label: "Back") { back() }.keyboardShortcut(.cancelAction)
            Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(1).accessibilityAddTraits(.isHeader)
            Spacer()
        }
        .frame(minHeight: 34)
        .padding(.horizontal, gutter).padding(.top, 14).padding(.bottom, 4)
    }
}

/// Header + System Settings style grouped form (or, with `scroll`, a stack of cards) over the paper background.
@MainActor struct PaneScaffold<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    @Environment(\.isPopout) private var popout
    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: title)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) { content }
                    .padding(.horizontal, gutter).padding(.top, 8).padding(.bottom, 16)
            }
            .scrollIndicators(.never)
        }
        .frame(width: popout ? nil : 340, height: popout ? nil : 640, alignment: .top)
        .frame(maxWidth: popout ? CGFloat.infinity : nil, maxHeight: popout ? CGFloat.infinity : nil)
        .background(Clay.paper)
    }
}

/// Trailing "…" row actions.
@MainActor struct RowMenu<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content
    var body: some View {
        Menu { content } label: { Image(systemName: "ellipsis.circle").font(.system(size: 15)).foregroundStyle(.secondary) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel(label)
    }
}

/// A pane section in the Home card style: optional caption, a card of rows split by `RowDivider`, optional footnote.
struct PaneSection<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title { Caption(title).padding(.horizontal, 4) }
            VStack(spacing: 0) { content }
                .padding(.horizontal, 14).padding(.vertical, 2)
                .card(0)
            if let footer {
                Text(footer).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
            }
        }
    }
}

struct RowDivider: View {
    var body: some View { Rectangle().fill(Clay.hairline).frame(height: 1) }
}

/// Title on the left, control on the right.
struct PaneRow<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 13))
            Spacer(minLength: 8)
            trailing
        }
        .frame(minHeight: 40)
    }
}

struct SwitchRow: View {
    let title: String
    let isOn: Binding<Bool>
    init(_ title: String, isOn: Binding<Bool>) { self.title = title; self.isOn = isOn }
    var body: some View {
        PaneRow(title: title) { Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.small) }
    }
}

// MARK: settings

@MainActor struct SettingsPane: View {
    @Environment(AppModel.self) private var model
    @State private var loginOn = SMAppService.mainApp.status == .enabled

    private func floating(_ get: @escaping () -> Bool, _ set: @escaping (Bool) -> Void) -> Binding<Bool> {
        Binding(get: get, set: { set($0); model.save(); FloatingController.shared.sync(model) })
    }

    var body: some View {
        PaneScaffold(title: "Settings") {
            PaneSection(title: "General") {
                SwitchRow("Launch at login", isOn: Binding(get: { loginOn }, set: { on in
                    do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                    catch { model.banner = "Couldn't change Launch at login: \(AppModel.reason(error)). Run Claude Anchor from the Applications folder and try again." }
                    loginOn = SMAppService.mainApp.status == .enabled
                }))
                RowDivider()
                SwitchRow("Bell sound", isOn: Binding(get: { model.config.bell }, set: { model.config.bell = $0; model.save() }))
                RowDivider()
                SwitchRow("Auto-switch near limit", isOn: Binding(get: { model.config.autoOverflow }, set: { model.config.autoOverflow = $0; model.save() }))
                RowDivider()
                SwitchRow("Use in VS Code and Cursor", isOn: Binding(get: { model.config.editorIntegration ?? false }, set: { model.banner = model.setEditorIntegration($0) }))
            }
            PaneSection(title: "Limits", footer: "Live uses more of Anthropic's API. Use Refresh in the header any time.") {
                PaneRow(title: "Refresh limits") {
                    Picker("Refresh limits", selection: Binding(get: { model.config.refreshSeconds }, set: { model.setRefreshSeconds($0) })) {
                        Text("Live every 30 s").tag(30)
                        Text("Every 1 min").tag(60)
                        Text("Every 5 min").tag(300)
                        Text("Every 15 min").tag(900)
                        Text("Manual only").tag(0)
                    }
                    .labelsHidden().fixedSize().controlSize(.small)
                }
                RowDivider()
                SwitchRow("Notify when a window resets", isOn: Binding(get: { model.config.notifyFresh }, set: { model.config.notifyFresh = $0; model.save() }))
            }
            PaneSection(title: "Usage", footer: "What your usage would cost at Anthropic's API prices. Pro, Max and Team plans are a flat fee, so it's off for them unless you turn it on.") {
                SwitchRow("Show API-price estimates", isOn: Binding(get: { model.showsAPIPrices }, set: { model.config.showAPIPrices = $0; model.save() }))
            }
            PaneSection(title: "Floating button") {
                PaneRow(title: "Show floating button") {
                    Text("⌥⌘A").font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Clay.surface2))
                        .accessibilityHidden(true)
                    Toggle("Show floating button", isOn: floating({ model.config.floatingButton }, { model.config.floatingButton = $0 }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                RowDivider()
                SwitchRow("Snap to screen edges", isOn: floating({ model.config.floatingSnap }, { model.config.floatingSnap = $0 }))
                RowDivider()
                SwitchRow("Fade when idle", isOn: floating({ model.config.floatingFade }, { model.config.floatingFade = $0 }))
                RowDivider()
                SwitchRow("Show on every Space", isOn: floating({ model.config.floatingAllSpaces }, { model.config.floatingAllSpaces = $0 }))
            }
        }
    }
}

// MARK: rules

@MainActor struct RulesPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        PaneScaffold(title: "Folder rules") {
            PaneSection(title: "Folders", footer: "New Claude sessions in a folder, in Terminal or VS Code, use its account. Overflow lets a folder use the default account when its own is near its limit.") {
                ForEach(Array(model.config.rules.enumerated()), id: \.element.id) { i, r in
                    if i > 0 { RowDivider() }
                    ruleRow(r)
                }
                if !model.config.rules.isEmpty { RowDivider() }
                Button { addFolder() } label: {
                    Label("Add folder", systemImage: "plus").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Clay.accentText)
                        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Choose a folder, or drop one here")
                .dropDestination(for: URL.self) { urls, _ in addDropped(urls) }
            }
            if let d = model.active {
                PaneSection(title: "Default") {
                    PaneRow(title: "Every other folder") {
                        FlagView(flag: d.flag, size: 11)
                        Text(d.name).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.tail)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func ruleRow(_ rule: Rule) -> some View {
        let acct = model.account(rule.accountID)
        let pct = model.limits[rule.accountID]?.fiveHour?.percent ?? 0
        let near = pct >= model.config.overflowThreshold && model.limits[rule.accountID]?.error == nil
        let fallback = model.active
        let usesFallback = rule.allowOverflow && fallback != nil && fallback?.id != rule.accountID
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "folder").font(.system(size: 12)).foregroundStyle(.secondary).accessibilityHidden(true)
                Text(abbreviate(rule.path)).font(.system(size: 12.5, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                RowMenu(label: "Options for \(abbreviate(rule.path))") {
                    Button("Remove rule", role: .destructive) { model.removeRule(rule.path) }
                }
            }
            HStack(spacing: 8) {
                Menu {
                    ForEach(model.accounts) { a in
                        Button {
                            model.removeRule(rule.path); model.addRule(path: rule.path, accountID: a.id)
                            if rule.allowOverflow { model.setRuleOverflow(rule.path, true) }
                        } label: { Label { Text(a.name) } icon: { FlagView(flag: a.flag, size: 11) } }
                    }
                } label: {
                    HStack(spacing: 6) {
                        if let acct { FlagView(flag: acct.flag, size: 11) }
                        Text(acct?.name ?? "Choose account").font(.system(size: 12.5, weight: .medium)).lineLimit(1).truncationMode(.tail)
                    }
                }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel("Account for \(abbreviate(rule.path)): \(acct?.name ?? "none")")
                Spacer(minLength: 8)
                Text("Overflow").font(.system(size: 12)).foregroundStyle(.secondary)
                Toggle("Allow overflow for \(abbreviate(rule.path))", isOn: Binding(get: { rule.allowOverflow }, set: { model.setRuleOverflow(rule.path, $0) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            if near, let acct {
                let pctText = "\(Int(pct.rounded()))%"
                let text = usesFallback ? "\(acct.name) at \(pctText) · now using \(fallback?.name ?? "default")"
                                        : "\(acct.name) at \(pctText) · new sessions will wait"
                let tint = usesFallback ? Clay.amber : Clay.limit
                HStack(spacing: 6) {
                    Circle().fill(tint).frame(width: 6, height: 6).accessibilityHidden(true)
                    Text(text).font(.system(size: 11.5, weight: .medium)).foregroundStyle(tint).lineLimit(2)
                }
                .padding(.horizontal, 8).padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(0.10)))
            }
        }
        .padding(.vertical, 10)
    }

    private func addDropped(_ urls: [URL]) -> Bool {
        guard let id = model.active?.id ?? model.accounts.first?.id else { return false }
        var added = false
        for u in urls {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue {
                model.addRule(path: u.path, accountID: id); added = true
            }
        }
        return added
    }

    private func addFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = false
        p.prompt = "Add folder"
        if p.runModal() == .OK, let u = p.url, let id = model.active?.id ?? model.accounts.first?.id {
            model.addRule(path: u.path, accountID: id)
        }
    }
}
