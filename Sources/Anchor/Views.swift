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

private let inset: CGFloat = 14

// MARK: shared building blocks

/// Hairline between sections; stronger under Increase Contrast.
private struct Sep: View {
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        if contrast == .increased { Rectangle().fill(Color.primary.opacity(0.4)).frame(height: 1).padding(.horizontal, inset) }
        else { Divider().padding(.horizontal, inset) }
    }
}

private struct SectionTitle: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Rounded `.quaternary` highlight under the pointer, as in Control Center rows.
private struct HoverHighlight: ViewModifier {
    @State private var hover = false
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hover ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear)))
            .contentShape(Rectangle())
            .onHover { hover = $0 }
    }
}
private extension View { func hoverHighlight() -> some View { modifier(HoverHighlight()) } }

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

@MainActor struct PopoverView: View {
    @State private var path: [Pane]
    @Environment(\.snapshotMode) private var snapshot
    init(path: [Pane] = []) { _path = State(initialValue: path) }
    var body: some View {
        NavigationStack(path: $path) {
            PopoverHome(path: $path)
                .navigationDestination(for: Pane.self) { p in
                    switch p {
                    case .accounts: AccountsPane()
                    case .rules: RulesPane()
                    case .settings: SettingsPane()
                    }
                }
        }
        .frame(width: 340)
        .background { if snapshot { Color(nsColor: .windowBackgroundColor) } }
    }
}

@MainActor struct PopoverHome: View {
    @Environment(AppModel.self) private var model
    @Binding var path: [Pane]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !model.cliInstalled {
                emptyState("Claude Code isn't installed.", "Install it, then reopen this menu.", "Open install guide") {
                    if let u = URL(string: "https://docs.anthropic.com/en/docs/claude-code/setup") { NSWorkspace.shared.open(u) }
                }
                bannerBlock.padding(.horizontal, inset).padding(.bottom, 10)
            } else if model.accounts.isEmpty {
                emptyState("Add an account to start", "Each account keeps its own limits and usage.", "Add account") { path.append(.accounts) }
                bannerBlock.padding(.horizontal, inset).padding(.bottom, 10)
            } else {
                TelegraphView().frame(maxWidth: .infinity).padding(.top, 10)
                identityRow.padding(.horizontal, inset).padding(.top, 10).padding(.bottom, 10)
                Sep()
                section("Limits") { limitsBlock }
                Sep()
                usageBlock
                if let s = model.lastSession {
                    Sep()
                    lastSessionBlock(s)
                }
            }
            Sep()
            VStack(spacing: 0) {
                MenuRow(title: "Accounts…", symbol: "person.2") { path.append(.accounts) }
                MenuRow(title: "Folder rules…", symbol: "folder") { path.append(.rules) }
                MenuRow(title: "Settings…", symbol: "gearshape") { path.append(.settings) }
            }.padding(.horizontal, 6).padding(.top, 6)
            Sep().padding(.vertical, 4)
            MenuRow(title: "Quit Claude Anchor", hint: "⌘Q") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q").padding(.horizontal, 6).padding(.bottom, 6)
        }
        .onAppear { model.refreshEnvironment() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in model.refreshEnvironment() }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title)
            content()
        }.padding(.horizontal, inset).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Stands in for the dial: a quiet mark, one sentence, one action.
    private func emptyState(_ title: String, _ detail: String, _ action: String, _ run: @escaping () -> Void) -> some View {
        VStack(spacing: 6) {
            AnchorGlyph().stroke(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                .frame(width: 22, height: 24).padding(.bottom, 6)
            Text(title).font(.body.weight(.semibold))
            Text(detail).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button(action, action: run).controlSize(.small).padding(.top, 6)
        }
        .padding(.horizontal, inset)
        .frame(maxWidth: .infinity, minHeight: 156)
    }

    @ViewBuilder private var bannerBlock: some View {
        if let b = model.banner {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "flag.fill").font(.caption2).foregroundStyle(Color.signalRed).accessibilityHidden(true)
                    Text(b).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                }
                if let id = model.overflowSuggestion, let t = model.account(id) {
                    Button("Continue this conversation on \(t.name)") { model.continueSession(on: id) }.controlSize(.small)
                }
            }
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

    @ViewBuilder private var identityRow: some View {
        if let a = model.active {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(a.name).font(.callout.weight(.semibold)).lineLimit(1)
                if let e = a.email { Text(e).font(.subheadline).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                Spacer(minLength: 8)
                if let p = a.plan { Text(p.capitalized).font(.subheadline).foregroundStyle(.secondary).fixedSize() }
            }
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder private var limitsBlock: some View {
        bannerBlock
        if let a = model.active {
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
                    bar("5-hour", l.fiveHour, l.stale)
                    bar("Weekly", l.weekly, l.stale)
                    if let n = l.note { Text(n).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
                }
            }
        }
    }

    private func bar(_ title: String, _ w: LimitWindow?, _ stale: Bool) -> some View {
        let p = w?.percent ?? 0
        let reset = resetText(w?.resetsAt) + (stale ? " (cached)" : "")
        return VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).font(.callout)
                Text(reset).font(.subheadline).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 8)
                Text("\(Int(p.rounded()))%").font(.callout.weight(.medium)).monospacedDigit()
                    .foregroundStyle(p >= 90 ? Color.signalRed : Color.primary)
            }
            ProgressView(value: min(1, max(0, p / 100))).progressViewStyle(.linear)
                .tint(p >= 90 ? Color.signalRed : Color.primary).labelsHidden()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) limit")
        .accessibilityValue("\(Int(p.rounded())) percent used. \(reset)")
    }

    // MARK: usage

    private var usageBlock: some View {
        @Bindable var m = model
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionTitle("Usage")
                Spacer()
                Picker("Range", selection: $m.rangeDays) {
                    Text("Today").tag(1); Text("7 days").tag(7); Text("30 days").tag(30)
                }.pickerStyle(.menu).labelsHidden().controlSize(.small).fixedSize()
            }
            Picker("Group by", selection: $m.groupBy) {
                ForEach(GroupBy.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
            if model.usageRows.isEmpty {
                Text("No Claude Code usage yet in this range.").font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.usageRows.prefix(6)) { row($0) }
                }.padding(.horizontal, -8)
                Text("≈ is the API price of this usage, not your bill.").font(.subheadline).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, inset).padding(.vertical, 10)
    }

    private func row(_ r: UsageRow) -> some View {
        HStack(spacing: 8) {
            if let id = r.accountID, let a = model.account(id) { FlagView(flag: a.flag, size: 11) }
            Text(r.label).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Text(compact(r.tokens)).monospacedDigit().fixedSize()
            Text(String(format: "≈$%.2f", r.cost)).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 60, alignment: .trailing).fixedSize()
                .help("What this usage would cost at API prices. Your plan is a flat fee.")
        }
        .font(.callout).padding(.horizontal, 8).frame(height: 24).hoverHighlight()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(r.label)
        .accessibilityValue("\(compact(r.tokens)) tokens, about \(String(format: "$%.2f", r.cost))")
    }

    // MARK: last session

    private func lastSessionBlock(_ s: (cwd: String, accountID: String, file: String?)) -> some View {
        section("Last session") {
            HStack(spacing: 8) {
                if let a = model.account(s.accountID) { FlagView(flag: a.flag, size: 11) }
                Text(abbreviate(s.cwd)).font(.callout).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                let others = model.accounts.filter { !$0.pending && $0.id != s.accountID }
                if s.file != nil, !others.isEmpty {
                    Menu {
                        ForEach(others) { a in
                            Button { model.continueSession(on: a.id) } label: {
                                Label { Text(a.name) } icon: { FlagView(flag: a.flag, size: 11) }
                            }
                        }
                    } label: { Text("Continue on…").font(.subheadline) }
                    .menuStyle(.borderlessButton).fixedSize()
                    .accessibilityLabel("Continue last session on another account")
                }
            }
        }
    }
}

// MARK: shared pane chrome

@MainActor struct PaneHeader: View {
    let title: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        HStack(spacing: 6) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold)).frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.borderless).keyboardShortcut(.cancelAction).help("Back").accessibilityLabel("Back")
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            Spacer()
        }.padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 2)
    }
}

/// Header + System Settings style grouped form over the popover material.
@MainActor struct PaneScaffold<Content: View>: View {
    let title: String
    let height: CGFloat
    @ViewBuilder var content: Content
    @Environment(\.snapshotMode) private var snapshot
    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: title)
            Form { content }.formStyle(.grouped).scrollContentBackground(.hidden)
        }
        .frame(width: 340, height: height)
        .background { if snapshot { Color(nsColor: .windowBackgroundColor) } }
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

// MARK: settings

@MainActor struct SettingsPane: View {
    @Environment(AppModel.self) private var model
    @State private var loginOn = SMAppService.mainApp.status == .enabled

    var body: some View {
        PaneScaffold(title: "Settings", height: 240) {
            Section {
                Toggle("Launch at login", isOn: Binding(get: { loginOn }, set: { on in
                    do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                    catch { model.banner = "Couldn't change Launch at login: \(AppModel.reason(error)). Run Claude Anchor from the Applications folder and try again." }
                    loginOn = SMAppService.mainApp.status == .enabled
                }))
                Toggle("Bell sound", isOn: Binding(get: { model.config.bell }, set: { model.config.bell = $0; model.save() }))
                Toggle("Auto-switch near limit", isOn: Binding(get: { model.config.autoOverflow }, set: { model.config.autoOverflow = $0; model.save() }))
                Toggle("Use in VS Code and Cursor", isOn: Binding(get: { model.config.editorIntegration ?? false }, set: { model.banner = model.setEditorIntegration($0) }))
            }
            .toggleStyle(.switch).controlSize(.small)
        }
    }
}

// MARK: rules

@MainActor struct RulesPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        PaneScaffold(title: "Folder rules", height: 440) {
            Section {
                Text("New Claude sessions in a folder, in Terminal or VS Code, use its account. Overflow lets a folder use the default account when its own is near its limit.")
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(model.config.rules) { rule in ruleSection(rule) }
            Section {
                if model.config.rules.isEmpty {
                    Text("No folder rules yet. Add a folder to pin it to an account.").font(.subheadline).foregroundStyle(.secondary)
                }
                Button { addFolder() } label: { Label("Add folder", systemImage: "plus") }.buttonStyle(.borderless)
            }
        }
    }

    private func ruleSection(_ rule: Rule) -> some View {
        let acct = Binding(get: { rule.accountID }, set: { id in
            model.removeRule(rule.path); model.addRule(path: rule.path, accountID: id)
            if rule.allowOverflow { model.setRuleOverflow(rule.path, true) }
        })
        return Section {
            Picker(selection: acct) {
                ForEach(model.accounts) { Text($0.name).tag($0.id) }
            } label: {
                HStack(spacing: 6) {
                    if let a = model.account(rule.accountID) { FlagView(flag: a.flag, size: 11) }
                    Text("Account")
                }
            }
            Toggle("Allow overflow", isOn: Binding(get: { rule.allowOverflow }, set: { model.setRuleOverflow(rule.path, $0) }))
                .toggleStyle(.switch).controlSize(.small)
        } header: {
            HStack {
                Text(abbreviate(rule.path)).font(.callout.weight(.semibold)).foregroundStyle(.primary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                RowMenu(label: "Options for \(abbreviate(rule.path))") {
                    Button("Remove rule", role: .destructive) { model.removeRule(rule.path) }
                }
            }
        }
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
