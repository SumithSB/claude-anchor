import SwiftUI
import AppKit
import ServiceManagement

enum Pane: Hashable { case accounts, rules }

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

@MainActor struct PopoverView: View {
    @State private var path: [Pane] = []
    var body: some View {
        NavigationStack(path: $path) {
            PopoverHome(path: $path)
                .navigationDestination(for: Pane.self) { $0 == .accounts ? AnyView(AccountsPane()) : AnyView(RulesPane()) }
        }
        .frame(width: 340)
    }
}

@MainActor struct PopoverHome: View {
    @Environment(AppModel.self) private var model
    @Binding var path: [Pane]
    @State private var loginOn = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !model.cliInstalled {
                emptyState("Claude Code isn't installed.", "Install it, then reopen this menu.", "Open install guide") {
                    if let u = URL(string: "https://docs.anthropic.com/en/docs/claude-code/setup") { NSWorkspace.shared.open(u) }
                }
                bannerBlock
            } else if model.accounts.isEmpty {
                emptyState("Add an account to start", "Each account keeps its own limits and usage.", "Add account") { path.append(.accounts) }
                bannerBlock
            } else {
                TelegraphView()
                activeBlock
                Divider()
                usageBlock
            }
            Divider()
            footer
        }
        .padding(16)
        .onAppear { model.refreshEnvironment() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in model.refreshEnvironment() }
    }

    /// Stands in for the dial: a quiet mark, one sentence, one action.
    private func emptyState(_ title: String, _ detail: String, _ action: String, _ run: @escaping () -> Void) -> some View {
        VStack(spacing: 6) {
            AnchorGlyph().stroke(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                .frame(width: 22, height: 24).padding(.bottom, 6)
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button(action, action: run).controlSize(.small).padding(.top, 6)
        }
        .frame(maxWidth: .infinity, minHeight: 156)
    }

    @ViewBuilder private var bannerBlock: some View {
        if let b = model.banner {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: "flag.fill").font(.system(size: 9)).foregroundStyle(Color.signalRed)
                Text(b).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3)
            }
            if let id = model.overflowSuggestion, let t = model.account(id) {
                Button("Continue this conversation on \(t.name)") { model.continueSession(on: id) }.controlSize(.small)
            }
        }
    }

    /// Shown when the default account hasn't signed in yet (first run, or after signing out).
    private func signInBlock(_ a: Account) -> some View {
        let first = model.accounts.allSatisfy(\.pending)
        return VStack(alignment: .leading, spacing: 6) {
            Text(first ? "Sign in to get started" : "\(a.name) isn't signed in").font(.system(size: 12, weight: .semibold))
            Text("Anchor reads your Claude Code sign-in to show limits and usage.").font(.system(size: 11)).foregroundStyle(.secondary)
            if model.signingIn.contains(a.id) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Finish signing in in your browser").font(.system(size: 11)).foregroundStyle(.secondary)
                    Button("Cancel") { model.cancelSignIn(a.id) }.controlSize(.small)
                }
            } else {
                Button("Sign in with browser") { model.signIn(a.id) }.controlSize(.small)
            }
        }
    }

    // MARK: active account

    private var activeBlock: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let a = model.active {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(a.name).font(.system(size: 12, weight: .semibold))
                    if let e = a.email { Text(e).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
                    Spacer(minLength: 8)
                    if let p = a.plan { Text(p.capitalized).font(.system(size: 11)).foregroundStyle(.secondary) }
                }
                bannerBlock
                if a.pending {
                    signInBlock(a)
                } else if let l = model.limits[a.id] {
                    if let err = l.error {
                        HStack {
                            Text(err).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                            Spacer()
                            if l.needsSignIn { Button("Sign in again") { model.signIn(a.id) }.controlSize(.small) }
                        }
                    } else {
                        bar("5h", l.fiveHour, l.stale)
                        bar("Week", l.weekly, l.stale)
                        if let n = l.note { Text(n).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2) }
                    }
                }
            }
        }
    }

    private func bar(_ title: String, _ w: LimitWindow?, _ stale: Bool) -> some View {
        let p = w?.percent ?? 0
        return HStack(spacing: 8) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 32, alignment: .leading)
            Capsule().fill(Color.primary.opacity(0.1)).frame(height: 4)
                .overlay(alignment: .leading) {
                    GeometryReader { g in
                        Capsule().fill(p >= 90 ? Color.signalRed : Color.primary)
                            .frame(width: g.size.width * min(1, max(0, p / 100)))
                    }
                }
            Text("\(Int(p.rounded()))%").font(.system(size: 11)).monospacedDigit()
                .foregroundStyle(p >= 90 ? Color.signalRed : Color.primary).frame(width: 32, alignment: .trailing)
            Text(resetText(w?.resetsAt) + (stale ? " (cached)" : ""))
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                .frame(width: 96, alignment: .trailing)
        }
    }

    // MARK: usage

    private var usageBlock: some View {
        @Bindable var m = model
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Picker("Group by", selection: $m.groupBy) {
                    ForEach(GroupBy.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
                Menu {
                    Picker("Range", selection: $m.rangeDays) {
                        Text("Today").tag(1); Text("7 days").tag(7); Text("30 days").tag(30)
                    }.pickerStyle(.inline)
                } label: { Text(model.rangeDays == 1 ? "Today" : "\(model.rangeDays) days") }
                .menuStyle(.borderlessButton).fixedSize()
            }
            if model.usageRows.isEmpty {
                Text("No Claude Code usage yet in this range.").font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.usageRows.prefix(6).enumerated()), id: \.element.id) { i, r in
                        if i > 0 { Divider().opacity(0.5) }
                        row(r)
                    }
                }
                Text("≈ is the API price of this usage, not your bill.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ r: UsageRow) -> some View {
        HStack(spacing: 8) {
            if let id = r.accountID, let a = model.account(id) { FlagView(flag: a.flag, size: 11) }
            Text(r.label).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Text(compact(r.tokens)).frame(width: 46, alignment: .trailing)
            Text(String(format: "≈$%.2f", r.cost)).foregroundStyle(.secondary).frame(width: 60, alignment: .trailing)
                .help("What this usage would cost at API prices. Your plan is a flat fee.")
        }
        .font(.system(size: 12)).monospacedDigit().frame(height: 25)
    }

    // MARK: footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let s = model.lastSession {
                HStack(spacing: 8) {
                    Text("Last session").foregroundStyle(.secondary)
                    Text(abbreviate(s.cwd)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    if let a = model.account(s.accountID) { FlagView(flag: a.flag, size: 11) }
                    let others = model.accounts.filter { !$0.pending && $0.id != s.accountID }
                    if s.file != nil, !others.isEmpty {
                        Menu {
                            ForEach(others) { a in
                                Button { model.continueSession(on: a.id) } label: {
                                    Label { Text(a.name) } icon: { FlagView(flag: a.flag, size: 11) }
                                }
                            }
                        } label: { Text("Continue on…").font(.system(size: 11)).foregroundStyle(.secondary) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    }
                }.font(.system(size: 11))
            }
            HStack(spacing: 8) {
                Button("Folder rules") { path.append(.rules) }
                Button("Accounts") { path.append(.accounts) }
                Spacer()
                Menu {
                    Toggle("Launch at login", isOn: Binding(get: { loginOn }, set: { on in
                        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                        catch { model.banner = "Couldn't change Launch at login: \(AppModel.reason(error)). Run Claude Anchor from the Applications folder and try again." }
                        loginOn = SMAppService.mainApp.status == .enabled
                    }))
                    Toggle("Bell sound", isOn: Binding(get: { model.config.bell }, set: { model.config.bell = $0; model.save() }))
                    Toggle("Auto-switch near limit", isOn: Binding(get: { model.config.autoOverflow }, set: { model.config.autoOverflow = $0; model.save() }))
                    Toggle("Use in VS Code and Cursor", isOn: Binding(get: { model.config.editorIntegration ?? false }, set: { model.banner = model.setEditorIntegration($0) }))
                    Divider()
                    Button("Quit Claude Anchor") { NSApplication.shared.terminate(nil) }
                } label: { Image(systemName: "gearshape") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Settings")
            }.controlSize(.small)
        }
    }
}

// MARK: shared pane chrome

@MainActor struct PaneHeader: View {
    let title: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        HStack {
            Button { dismiss() } label: { Label("Back", systemImage: "chevron.left") }.buttonStyle(.borderless)
            Spacer()
            Text(title).font(.system(size: 13, weight: .semibold))
            Spacer()
            Label("Back", systemImage: "chevron.left").hidden()   // balances the title
        }.padding(.horizontal, 16).padding(.vertical, 10)
    }
}

// MARK: rules

@MainActor struct RulesPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(title: "Folder rules")
            Text("New Claude sessions in this folder, in Terminal or VS Code, use this account. Overflow lets a folder use the default account when its own is near its limit.")
                .font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.bottom, 8)
            if model.config.rules.isEmpty {
                Text("No folder rules yet. Add a folder to pin it to an account.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).padding(16)
            }
            List {
                ForEach(model.config.rules) { rule in ruleRow(rule) }
            }.listStyle(.plain)
            Divider()
            Button("Add folder") { addFolder() }.padding(12).controlSize(.small)
        }
        .frame(width: 340, height: 440)
    }

    private func ruleRow(_ rule: Rule) -> some View {
        let acct = Binding(get: { rule.accountID }, set: { id in
            model.removeRule(rule.path); model.addRule(path: rule.path, accountID: id)
            if rule.allowOverflow { model.setRuleOverflow(rule.path, true) }
        })
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(abbreviate(rule.path)).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button { model.removeRule(rule.path) } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless).help("Remove rule").accessibilityLabel("Remove rule")
            }
            HStack(spacing: 6) {
                if let a = model.account(rule.accountID) { FlagView(flag: a.flag, size: 12) }
                Picker("Account", selection: acct) {
                    ForEach(model.accounts) { Text($0.name).tag($0.id) }
                }.labelsHidden().fixedSize()
                Spacer()
                Toggle("Allow overflow", isOn: Binding(get: { rule.allowOverflow }, set: { model.setRuleOverflow(rule.path, $0) }))
                    .toggleStyle(.checkbox).font(.system(size: 11))
            }
        }.padding(.vertical, 6)
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
