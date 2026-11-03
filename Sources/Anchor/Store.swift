import AppKit
import CoreServices
import UserNotifications

/// Process-wide state that extensions can't store on AppModel.
@MainActor enum AnchorRuntime {
    static var stream: FSEventStreamRef?
    static var logins: [String: Process] = [:]   // running `claude auth login` per account
    static var limitsTimer: Timer?
    static var lastMove: Date?
    static var limitsAttempted = false   // a limits refresh has run at least once
    static let queue = DispatchQueue(label: "anchor.scan", qos: .utility)
}

struct AnchorError: LocalizedError {
    var errorDescription: String?
    init(_ m: String) { errorDescription = m }
}

extension AppModel {
    // MARK: helpers

    /// Runs a tool, returns stdout (nil if it could not launch). Never logs output.
    @discardableResult
    nonisolated static func run(_ exe: String, _ args: [String], wait: Bool = true) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = wait ? pipe : FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        guard wait else { return nil }
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? d : nil
    }

    /// Account's .claude.json (primary's lives in HOME, not in its config dir).
    nonisolated static func claudeJSONPath(for a: Account) -> String {
        a.isPrimary ? Paths.home + "/.claude.json" : a.dir + "/.claude.json"
    }

    nonisolated static func claudeJSON(for a: Account) -> [String: Any] {
        guard let d = FileManager.default.contents(atPath: claudeJSONPath(for: a)),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return o
    }

    nonisolated static func email(of a: Account) -> String? {
        (claudeJSON(for: a)["oauthAccount"] as? [String: Any])?["emailAddress"] as? String
    }

    nonisolated static func keychainPlan(for a: Account) -> String? {
        (keychainJSON(service: keychainService(for: a))?["claudeAiOauth"] as? [String: Any])?["subscriptionType"] as? String
    }

    nonisolated static func keychainJSON(service: String) -> [String: Any]? {
        guard let d = run("/usr/bin/security", ["find-generic-password", "-s", service, "-w"]) else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }

    // MARK: files

    /// User-facing reason for a failed write, without the trailing period.
    nonisolated static func reason(_ e: Error) -> String {
        var t = e.localizedDescription
        while t.hasSuffix(".") { t.removeLast() }
        return t
    }

    /// Creates (or tightens) a private directory: only the owner can read it.
    nonisolated static func ensureDir(_ path: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
    }

    /// Atomic write, then owner-only permissions.
    nonisolated static func writeSecure(_ data: Data, to path: String, mode: Int = 0o600) throws {
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
    }

    func reportSaveError(_ e: Error) { banner = "Couldn't save settings: \(Self.reason(e))." }

    /// Signed in = Claude Code left an account record or a keychain credential for this dir.
    nonisolated static func signedIn(_ a: Account) -> Bool {
        email(of: a) != nil || keychainJSON(service: keychainService(for: a)) != nil
    }

    /// Definitely signed out: .claude.json is gone or reads cleanly without an account, and the keychain answers
    /// "no such item" (exit 44). A file caught mid-write by Claude Code or a keychain still locked after wake is
    /// not a sign-out, and treating it as one wiped the account's limits.
    nonisolated static func signedOut(_ a: Account) -> Bool {
        if let d = FileManager.default.contents(atPath: claudeJSONPath(for: a)) {
            guard let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], o["oauthAccount"] == nil else { return false }
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", keychainService(for: a)]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 44
    }

    /// Keeps the primary account's pending flag in step with what the CLI actually has (sign-in or sign-out in Terminal).
    func reconcilePrimary() {
        guard live, let i = config.accounts.firstIndex(where: { $0.isPrimary }), !signingIn.contains(config.accounts[i].id) else { return }
        let a = config.accounts[i]
        if a.pending && Self.signedIn(a) {
            config.accounts[i].email = Self.email(of: a)
            config.accounts[i].plan = Self.keychainPlan(for: a)
            config.accounts[i].pending = false
            save()
            Task { await refreshLimits() }
        } else if !a.pending && Self.signedOut(a) {
            config.accounts[i].pending = true
            config.accounts[i].email = nil
            config.accounts[i].plan = nil
            limits[a.id] = nil
            save()
        }
    }

    /// Cheap re-check, run each time the popover opens.
    func refreshEnvironment() {
        guard live else { return }
        reconcilePrimary()
        reconcileCodexPrimary()
        if Self.claudeFastPath() != nil { cliInstalled = true } else {
            Task.detached {
                let found = Self.claudePath() != nil
                await MainActor.run { self.cliInstalled = found }
            }
        }
        if Self.codexFastPath() != nil { codexInstalled = true } else {
            Task.detached {
                let found = Self.codexPath() != nil
                await MainActor.run { self.codexInstalled = found }
            }
        }
    }

    /// Adds the "codex" account for a ~/.codex login (file, or keyring per `codex login status`), or refreshes it.
    /// Never removes anything: a sign-out in Terminal is noticed by the limits check.
    func reconcileCodexPrimary() {
        guard live else { return }
        if let auth = Self.codexAuth(dir: Paths.codexPrimaryDir) { adoptCodexPrimary(auth); return }
        guard !config.codexAccounts.contains(where: { $0.isPrimary }), let exe = Self.codexFastPath() else { return }
        Task.detached {   // keyring mode has no auth.json
            if Self.codexRun(exe, ["login", "status"], home: nil) { await MainActor.run { self.adoptCodexPrimary((nil, nil, nil)) } }
        }
    }

    private func adoptCodexPrimary(_ auth: (email: String?, plan: String?, accountID: String?)) {
        var c = config
        if let i = c.codexAccounts.firstIndex(where: { $0.isPrimary }) {
            c.codexAccounts[i].email = auth.email ?? c.codexAccounts[i].email
            c.codexAccounts[i].plan = auth.plan ?? c.codexAccounts[i].plan
            c.codexAccounts[i].accountID = auth.accountID ?? c.codexAccounts[i].accountID
            c.codexAccounts[i].pending = false
        } else {
            let used = Set((c.accounts + c.codexAccounts).map(\.flag))
            let flag = SignalFlag.allCases.first { !used.contains($0) } ?? .a
            c.codexAccounts.append(Account(id: "codex", name: "Codex", flag: flag, dir: Paths.codexPrimaryDir, email: auth.email,
                                           plan: auth.plan, pending: false, tool: .codex, accountID: auth.accountID))
        }
        if !c.codexAccounts.contains(where: { $0.id == c.codexDefaultID }) { c.codexDefaultID = "codex" }
        guard let before = try? JSONEncoder().encode(config), let after = try? JSONEncoder().encode(c), before != after else { return }
        config = c
        save()
        restartWatch()
        Task { await refreshLimits() }
    }

    // MARK: lifecycle

    func start() {
        load()
        let clamped = Self.clampRefresh(config.refreshSeconds)
        if clamped != config.refreshSeconds { config.refreshSeconds = clamped; save() }
        installShellFiles()
        refreshEnvironment()
        // Editors are on by default: the first launch that finds VS Code or Cursor routes them too.
        // The choice is remembered, so turning it off in Settings sticks.
        if live, config.editorIntegration == nil,
           Self.editorSettingsFiles.contains(where: { FileManager.default.fileExists(atPath: $0) }) {
            banner = setEditorIntegration(true)
                ?? "VS Code and Cursor now use Claude Anchor for new conversations. You can turn this off in Settings."
        }
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        rescan()
        restartWatch()
        Task { await refreshLimits() }
        applyRefreshInterval()
    }

    nonisolated static let refreshChoices = [30, 60, 300, 900]

    /// Maps any stored value to an allowed one: 0 stays manual, others snap to the nearest choice.
    nonisolated static func clampRefresh(_ s: Int) -> Int {
        if s == 0 { return 0 }
        if s < 0 { return 300 }
        return refreshChoices.min { abs($0 - s) < abs($1 - s) } ?? 300
    }

    /// (Re)arms the limits timer from config.refreshSeconds; 0 leaves it off.
    func applyRefreshInterval() {
        AnchorRuntime.limitsTimer?.invalidate()
        AnchorRuntime.limitsTimer = nil
        let s = config.refreshSeconds
        guard s > 0 else { return }
        AnchorRuntime.limitsTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(s), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.restartWatch()
                Task { await self?.refreshLimits() }
            }
        }
    }

    func setRefreshSeconds(_ s: Int) {
        config.refreshSeconds = Self.clampRefresh(s)
        save()
        applyRefreshInterval()
    }

    /// Scan logs off the main thread, then update rows.
    func rescan() {
        let accts = accounts, cx = codexAccounts, u = usage
        AnchorRuntime.queue.async {
            u.scan(accounts: accts, codexAccounts: cx)
            let err = u.persistError
            Task { @MainActor in
                self.refreshRows()
                if let err { self.banner = "Couldn't save usage history: \(err)." }
            }
        }
    }

    /// (Re)create the FSEvents stream; call after accounts change.
    func restartWatch() {
        if let s = AnchorRuntime.stream {
            FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s)
            AnchorRuntime.stream = nil
        }
        // Watch projects/ where it exists, else the account dir so projects/ appearing is noticed.
        let paths = accounts.map { a -> String in
            FileManager.default.fileExists(atPath: a.dir + "/projects") ? a.dir + "/projects" : a.dir
        } + codexAccounts.map { a -> String in
            FileManager.default.fileExists(atPath: a.dir + "/sessions") ? a.dir + "/sessions" : a.dir
        }
        guard !paths.isEmpty else { return }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let m = Unmanaged<AppModel>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { m.rescan() }   // stream is delivered on the main queue
        }
        guard let s = FSEventStreamCreate(nil, cb, &ctx, paths as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2.0,
                                          FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)) else { return }
        FSEventStreamSetDispatchQueue(s, .main)
        FSEventStreamStart(s)
        AnchorRuntime.stream = s
    }

    // MARK: config

    func load() {
        let fm = FileManager.default
        if fm.fileExists(atPath: Paths.config) {
            if let d = fm.contents(atPath: Paths.config), let c = try? JSONDecoder().decode(Config.self, from: d) {
                config = c
                // A hand-edited default pointing nowhere falls back to the first account.
                if account(config.defaultID) == nil, let first = config.accounts.first(where: { !$0.pending }) ?? config.accounts.first {
                    config.defaultID = first.id
                    save()
                } else {
                    writeRoutes()
                }
                return
            }
            // Unreadable or wrong shape: keep it for the user, start fresh.
            let bak = Paths.config + ".broken-\(Int(Date().timeIntervalSince1970))"
            do {
                try fm.moveItem(atPath: Paths.config, toPath: bak)
                seed()
                banner = "Your settings file was unreadable. A backup was saved and fresh settings were created."
            } catch {
                seed(persist: false)
                saveBlocked = true
                banner = "Your settings file was unreadable and couldn't be backed up. Fix or remove \(abbreviate(Paths.config)), then reopen Claude Anchor."
            }
            return
        }
        seed()
    }

    /// First run: the primary account, pending until Claude Code is signed in.
    private func seed(persist: Bool = true) {
        var a = Account(id: "primary", name: "Personal", flag: .a, dir: Paths.primaryDir)
        let oa = Self.claudeJSON(for: a)["oauthAccount"] as? [String: Any]
        // Auto-created orgs are named "<email>'s Organization"; that's not a useful label.
        let org = (oa?["organizationName"] as? String).flatMap { $0.hasSuffix("'s Organization") ? nil : $0 }
        a.name = org ?? "Personal"
        a.email = oa?["emailAddress"] as? String
        a.plan = Self.keychainPlan(for: a)
        a.pending = !Self.signedIn(a)
        config = Config(accounts: [a], defaultID: "primary")
        if persist { save() }
    }

    func save() {
        guard !saveBlocked else { return }
        do {
            try Self.ensureDir(Paths.anchor)
            let e = JSONEncoder()
            e.outputFormatting = [.prettyPrinted, .sortedKeys]
            try Self.writeSecure(try e.encode(config), to: Paths.config)
        } catch { reportSaveError(error); return }
        writeRoutes()
    }

    nonisolated static func routesText(config: Config, limits: [String: Limits], tool: Tool) -> String {
        let def = config.defaultID(tool)
        func dir(_ id: String) -> String { config.accounts(tool).first { $0.id == id }?.configDirEnv ?? "-" }
        func hot(_ id: String) -> Bool {
            guard let l = limits[id] else { return false }
            return max(l.fiveHour?.percent ?? 0, l.weekly?.percent ?? 0) >= config.overflowThreshold
        }
        var out = "# generated by Claude Anchor — edit in the app\n"
        for r in config.rules(tool).sorted(by: { $0.path.count > $1.path.count })
        where !r.path.contains(where: { $0 == "\t" || $0.isNewline }) {   // hand-edited config guard
            let id = (r.allowOverflow && hot(r.accountID)) ? def : r.accountID
            out += "\(r.path)\t\(dir(id))\n"
        }
        return out + "default\t\(dir(def))\n"
    }

    /// The account `claude` (or `codex`) gets in `cwd`, by the same rules as the routes file: longest matching
    /// folder rule (its overflow sends it to the default while hot), else the default.
    nonisolated static func routedAccount(cwd: String, config: Config, limits: [String: Limits], tool: Tool) -> String {
        let def = config.defaultID(tool)
        let rule = config.rules(tool).filter { $0.path == "/" || cwd == $0.path || cwd.hasPrefix($0.path + "/") }
            .max { $0.path.count < $1.path.count }
        guard let r = rule else { return def }
        let l = limits[r.accountID]
        let hot = max(l?.fiveHour?.percent ?? 0, l?.weekly?.percent ?? 0) >= config.overflowThreshold
        return r.allowOverflow && hot ? def : r.accountID
    }

    func writeRoutes() {
        guard !saveBlocked else { return }
        do {
            try Self.ensureDir(Paths.anchor)
            try Self.writeSecure(Data(Self.routesText(config: config, limits: limits, tool: .claude).utf8), to: Paths.routes)
            if config.codexAccounts.isEmpty {
                try? FileManager.default.removeItem(atPath: Paths.codexRoutes)
            } else {
                try Self.writeSecure(Data(Self.routesText(config: config, limits: limits, tool: .codex).utf8), to: Paths.codexRoutes)
            }
        } catch { reportSaveError(error) }
    }

    /// Who a Codex login belongs to, read from `<dir>/auth.json` without any network call. nil: not signed in by file
    /// (missing, a symlink, over 64 KB or unreadable). API-key logins give all-nil fields. The JWT payload is decoded
    /// for display only, never verified; no token or key is returned or kept.
    nonisolated static func codexAuth(dir: String) -> (email: String?, plan: String?, accountID: String?)? {
        let path = dir + "/auth.json"
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              attrs[.type] as? FileAttributeType == .typeRegular,
              (attrs[.size] as? Int ?? .max) <= 64 * 1024,
              let d = FileManager.default.contents(atPath: path), d.count <= 64 * 1024,
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        guard let tokens = o["tokens"] as? [String: Any] else {
            return o["OPENAI_API_KEY"] is String ? (nil, nil, nil) : nil
        }
        var b64 = ((tokens["id_token"] as? String)?.split(separator: ".").dropFirst().first).map(String.init) ?? ""
        b64 = b64.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        let claims = Data(base64Encoded: b64).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let auth = claims?["https://api.openai.com/auth"] as? [String: Any]
        return (claims?["email"] as? String, auth?["chatgpt_plan_type"] as? String,
                tokens["account_id"] as? String ?? auth?["chatgpt_account_id"] as? String)
    }

    func setDefault(_ id: String) {
        config.setDefaultID(id, account(id)?.kind ?? .claude)
        overflowSuggestion = nil
        save()
        if config.bell, let s = NSSound(named: "Tink") { s.volume = 0.3; s.play() }
    }

    // MARK: continue on another account

    /// Copies a transcript (and its sibling session folder) into targetDir's matching project folder.
    /// Returns every copied .jsonl path.
    nonisolated static func copyTranscript(file: String, to targetDir: String) throws -> [String] {
        let fm = FileManager.default
        let src = URL(fileURLWithPath: file)
        let sid = src.deletingPathExtension().lastPathComponent
        let dstDir = URL(fileURLWithPath: targetDir).appendingPathComponent("projects")
            .appendingPathComponent(src.deletingLastPathComponent().lastPathComponent)
        try fm.createDirectory(at: dstDir, withIntermediateDirectories: true)
        func put(_ from: URL, _ to: URL) throws {
            if fm.fileExists(atPath: to.path) { try fm.removeItem(at: to) }
            try fm.copyItem(at: from, to: to)
        }
        let dstFile = dstDir.appendingPathComponent(sid + ".jsonl")
        try put(src, dstFile)
        var copied = [dstFile.path]
        let side = src.deletingLastPathComponent().appendingPathComponent(sid)
        if fm.fileExists(atPath: side.path) {
            let dstSide = dstDir.appendingPathComponent(sid)
            try put(side, dstSide)
            for case let rel as String in fm.enumerator(atPath: dstSide.path) ?? NSEnumerator() where rel.hasSuffix(".jsonl") {
                copied.append(dstSide.path + "/" + rel)
            }
        }
        return copied
    }

    /// Copies the last conversation to `targetID` and opens Terminal to resume it. Outcome goes to `banner`.
    func continueSession(on targetID: String) {
        let fm = FileManager.default
        guard let s = lastSession, let file = s.file,
              let t = account(targetID), t.kind == .claude, !t.pending, t.id != s.accountID else { banner = "No recent conversation to continue."; return }
        guard fm.fileExists(atPath: file) else { banner = "That conversation's file is gone, so it can't be continued."; return }
        let sid = ((file as NSString).lastPathComponent as NSString).deletingPathExtension
        // Only real session ids reach the Terminal command line.
        guard UUID(uuidString: sid) != nil else { banner = "That conversation can't be continued."; return }
        if s.editor, let why = editorBlocked(s, on: t) { banner = why; return }
        let copied: [String]
        do { copied = try Self.copyTranscript(file: file, to: t.dir) } catch {
            banner = "Couldn't copy the conversation to \(t.name): \(Self.reason(error)). Check that \(abbreviate(t.dir)) is writable."
            return
        }
        copied.forEach(usage.markCopied)
        if s.editor {   // VS Code runs its own claude: anchor here and its next launch picks the conversation up
            overflowSuggestion = nil
            banner = nil
            if config.defaultID != t.id { setDefault(t.id) }
            return
        }
        var isDir: ObjCBool = false
        let cwdOK = fm.fileExists(atPath: s.cwd, isDirectory: &isDir) && isDir.boolValue
        let cwd = cwdOK ? s.cwd : Paths.home
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        // `command` is a shell builtin, so the primary case unsets the var instead of using env -u.
        let env = t.configDirEnv.map { "CLAUDE_CONFIG_DIR=" + q($0) + " " } ?? "unset CLAUDE_CONFIG_DIR; "
        let cmd = "cd \(q(cwd)) && \(env)command claude --resume \(q(sid))"
        let esc = cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        overflowSuggestion = nil
        let ok = cwdOK ? "Continuing on \(t.name). Close the old session so the two don't drift apart."
                       : "That project folder no longer exists, so the conversation opens in your home folder."
        banner = nil
        // Off the main thread: macOS may show an Automation permission prompt and osascript waits for it.
        Task.detached {
            let done = Self.run("/usr/bin/osascript", ["-e", "tell application \"Terminal\" to do script \"\(esc)\"",
                                                       "-e", "tell application \"Terminal\" to activate"]) != nil
            await MainActor.run {
                self.banner = done ? ok : "Couldn't open Terminal. Allow Claude Anchor to control Terminal in System Settings > Privacy & Security > Automation, then try again."
            }
        }
    }

    /// Opens the conversation through the Claude Code extension's link handler. A closed tab comes back with a new
    /// process, which the wrapper routes to the current anchor; an open tab is only brought forward.
    func reopenInEditor(_ s: LastSession) {
        guard let file = s.file else { return }
        let sid = ((file as NSString).lastPathComponent as NSString).deletingPathExtension
        guard UUID(uuidString: sid) != nil else { return }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let cursor = running.contains("com.todesktop.230313mzl4w4u92") && !running.contains("com.microsoft.VSCode")
        guard let url = URL(string: "\(cursor ? "cursor" : "vscode")://anthropic.claude-code/open?session=\(sid)"),
              NSWorkspace.shared.open(url) else {
            banner = "Couldn't open VS Code. Open the conversation from Claude Code's history there."
            return
        }
    }

    /// Continuing in VS Code means anchoring at `t`; nil when that would route the folder there, else why not.
    private func editorBlocked(_ s: LastSession, on t: Account) -> String? {
        var after = config
        after.defaultID = t.id
        if Self.routedAccount(cwd: s.cwd, config: after, limits: limits, tool: .claude) == t.id { return nil }
        let rule = config.rules.filter { s.cwd == $0.path || s.cwd.hasPrefix($0.path + "/") || $0.path == "/" }
            .max { $0.path.count < $1.path.count }
        let pinned = rule.flatMap { account($0.accountID) }?.name ?? "another account"
        return "\(abbreviate(rule?.path ?? s.cwd)) always uses \(pinned) (a folder rule). Change it in Rules to continue on \(t.name) in VS Code."
    }

    // MARK: accounts

    @discardableResult
    func addAccount(name: String, flag: SignalFlag, tool: Tool = .claude) -> Account? {
        var slug = String(name.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if slug.isEmpty { slug = "account" }
        var id = slug, n = 2
        // A folder still on disk may be a removal finishing in the background (it logs out and trashes that path).
        func taken(_ id: String) -> Bool {
            id == "primary" || id == "codex" || account(id) != nil
                || FileManager.default.fileExists(atPath: (tool == .codex ? Paths.codexAccounts : Paths.accounts) + "/" + id)
        }
        while taken(id) { id = "\(slug)-\(n)"; n += 1 }
        if tool == .codex {
            let dir = Paths.codexAccounts + "/" + id
            do { try Self.makeCodexDir(dir) } catch {
                banner = "Couldn't create a folder for \(name): \(Self.reason(error)). Check disk space and permissions, then try again."
                return nil
            }
            let a = Account(id: id, name: name, flag: flag, dir: dir, pending: true, tool: .codex)
            config.codexAccounts.append(a)
            save()
            restartWatch()
            signIn(id)
            return a
        }
        let dir = Paths.accounts + "/" + id
        let fm = FileManager.default
        do { try Self.ensureDir(Paths.anchor); try Self.ensureDir(Paths.accounts); try Self.ensureDir(dir) } catch {
            banner = "Couldn't create a folder for \(name): \(Self.reason(error)). Check disk space and permissions, then try again."
            return nil
        }
        for f in ["settings.json", "CLAUDE.md", "skills", "agents", "commands", "plugins", "hooks", "output-styles", "keybindings.json"]
        where fm.fileExists(atPath: Paths.primaryDir + "/" + f) {
            try? fm.createSymbolicLink(atPath: dir + "/" + f, withDestinationPath: Paths.primaryDir + "/" + f)
        }
        let a = Account(id: id, name: name, flag: flag, dir: dir, pending: true)
        config.accounts.append(a)
        save()
        restartWatch()
        signIn(id)
        return a
    }

    /// Known install locations; a stat each, safe to call on the main thread.
    nonisolated static func claudeFastPath() -> String? {
        let fm = FileManager.default
        return [Paths.home + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                Paths.home + "/.claude/local/claude"].first { fm.isExecutableFile(atPath: $0) }
    }

    /// The CLI's path; apps launched from Finder don't get the login shell's PATH.
    nonisolated static func claudePath() -> String? {
        if let p = claudeFastPath() { return p }
        // Login shells may print banners; the path is the last line.
        let out = run("/bin/zsh", ["-lc", "command -v claude"]).flatMap { String(data: $0, encoding: .utf8) }
        let last = out?.split(whereSeparator: \.isNewline).last.map { String($0).trimmingCharacters(in: .whitespaces) }
        return last.flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil }
    }

    /// Account folder (0700) plus symlinks to the shared settings in `primary`; never the login, history or databases.
    nonisolated static func makeCodexDir(_ dir: String, primary: String = Paths.codexPrimaryDir, base: String = Paths.anchor) throws {
        let fm = FileManager.default
        try ensureDir(base); try ensureDir((dir as NSString).deletingLastPathComponent); try ensureDir(dir)
        for f in ["config.toml", "AGENTS.md", "skills", "rules", "hooks.json"]
        where fm.fileExists(atPath: primary + "/" + f) && (try? fm.destinationOfSymbolicLink(atPath: dir + "/" + f)) == nil {
            try? fm.createSymbolicLink(atPath: dir + "/" + f, withDestinationPath: primary + "/" + f)
        }
    }

    /// Newest (by version-sorted names) bundled codex under editor extension folders; stat/readdir only.
    nonisolated static func extensionCodex(roots: [String]) -> String? {
        let fm = FileManager.default
        for root in roots {
            let exts = ((try? fm.contentsOfDirectory(atPath: root)) ?? []).filter { $0.hasPrefix("openai.chatgpt-") }
                .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            for e in exts {
                let bin = root + "/" + e + "/bin"
                for d in ((try? fm.contentsOfDirectory(atPath: bin)) ?? []).filter({ $0.hasPrefix("macos-") })
                    .sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }) {
                    if fm.isExecutableFile(atPath: bin + "/" + d + "/codex") { return bin + "/" + d + "/codex" }
                }
            }
        }
        return nil
    }

    /// Known install locations and editor-bundled copies; no subprocess, safe on the main thread.
    nonisolated static func codexFastPath() -> String? {
        let fm = FileManager.default
        return [Paths.home + "/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"].first { fm.isExecutableFile(atPath: $0) }
            ?? extensionCodex(roots: [Paths.home + "/.vscode/extensions", Paths.home + "/.cursor/extensions"])
    }

    /// The Codex CLI's path. The binary is often only inside the editor extension, so that is checked after the login shell.
    nonisolated static func codexPath() -> String? {
        let fm = FileManager.default
        if let p = [Paths.home + "/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"].first(where: { fm.isExecutableFile(atPath: $0) }) { return p }
        let out = run("/bin/zsh", ["-lc", "command -v codex"]).flatMap { String(data: $0, encoding: .utf8) }
        if let last = out?.split(whereSeparator: \.isNewline).last.map({ String($0).trimmingCharacters(in: .whitespaces) }),
           fm.isExecutableFile(atPath: last) { return last }
        return extensionCodex(roots: [Paths.home + "/.vscode/extensions", Paths.home + "/.cursor/extensions"])
    }

    /// Runs a Codex CLI command to completion with CODEX_HOME set to `home` (removed for the primary). Output is
    /// discarded; true when it exited 0.
    @discardableResult
    nonisolated static func codexRun(_ exe: String, _ args: [String], home: String?) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
        env["CODEX_HOME"] = home
        p.environment = env
        p.standardInput = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// Another Codex account signed in to the same ChatGPT account (compared by account id, never by email).
    nonisolated static func codexTwin(accountID: String?, excluding id: String, in list: [Account]) -> Account? {
        guard let accountID else { return nil }
        return list.first { $0.id != id && $0.accountID == accountID }
    }

    /// A Codex folder may be removed only if it's a standardized direct child of `root` and not the primary.
    nonisolated static func codexRemovable(_ dir: String, root: String = Paths.codexAccounts) -> Bool {
        (dir as NSString).standardizingPath == dir && (dir as NSString).deletingLastPathComponent == root && dir != Paths.codexPrimaryDir
    }

    /// Deletes the login so no refresh token travels to the Trash. False if it's still there.
    nonisolated static func prepareCodexRemoval(dir: String) -> Bool {
        let path = dir + "/auth.json"
        try? FileManager.default.removeItem(atPath: path)
        return (try? FileManager.default.attributesOfItem(atPath: path)) == nil
    }

    /// Runs `claude auth login` in the background for this account. The CLI opens the browser and
    /// exits once the browser hands the code back, so no Terminal is involved.
    func signIn(_ id: String) {
        guard let a = account(id), AnchorRuntime.logins[id] == nil else { return }
        let codex = a.kind == .codex, tool = codex ? "Codex" : "Claude Code"
        // `codex login` listens on a fixed local port, so two at once would clash.
        if codex, AnchorRuntime.logins.keys.contains(where: { account($0)?.kind == .codex }) { banner = "Finish the other Codex sign-in first."; return }
        guard let exe = codex ? Self.codexPath() : Self.claudePath() else { banner = "\(tool) isn't installed. Install it, then sign in again."; return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = codex ? ["login"] : ["auth", "login"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
        env[codex ? "CODEX_HOME" : "CLAUDE_CONFIG_DIR"] = a.configDirEnv
        p.environment = env
        p.standardInput = Pipe()            // kept open so the CLI waits for the browser instead of reading EOF
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { proc in
            let ok = proc.terminationStatus == 0, killed = proc.terminationReason == .uncaughtSignal
            Task { @MainActor in self.finishSignIn(id, ok: ok, cancelled: killed) }
        }
        if !a.isPrimary { try? Self.ensureDir(a.dir) }   // the CLI needs its config dir to exist
        do { try p.run() } catch {
            banner = "Couldn't start \(tool) to sign in \(a.name): \(Self.reason(error)). Check that `\(codex ? "codex" : "claude")` runs in Terminal, then try again."
            return
        }
        AnchorRuntime.logins[id] = p
        signingIn.insert(id)
        banner = nil
        // ponytail: fixed 10 min timeout; the CLI has its own, this just stops a forgotten tab holding a process
        DispatchQueue.main.asyncAfter(deadline: .now() + 600) {
            MainActor.assumeIsolated { if AnchorRuntime.logins[id] === p { self.banner = "Sign-in for \(a.name) timed out. Try again."; p.terminate() } }
        }
    }

    func cancelSignIn(_ id: String) { AnchorRuntime.logins[id]?.terminate() }

    private func finishSignIn(_ id: String, ok: Bool, cancelled: Bool) {
        AnchorRuntime.logins[id] = nil
        signingIn.remove(id)
        if let j = config.codexAccounts.firstIndex(where: { $0.id == id }) { finishCodexSignIn(j, ok: ok, cancelled: cancelled); return }
        guard let i = config.accounts.firstIndex(where: { $0.id == id }) else { return }
        let name = config.accounts[i].name
        guard ok, let mail = Self.email(of: config.accounts[i]) else {
            if !cancelled { banner = "Sign-in for \(name) didn't finish. Try again." }
            return
        }
        defer { restartWatch(); rescan() }
        // A browser already signed in to claude.ai hands back that same account.
        if let twin = config.accounts.first(where: { $0.id != id && $0.email == mail }) {
            banner = "\(name) signed in as \(mail), which is already \(twin.name). Switch accounts on claude.ai, then sign in again."
            config.accounts[i].pending = true
            save()
            return
        }
        config.accounts[i].email = mail
        config.accounts[i].plan = Self.keychainPlan(for: config.accounts[i])
        config.accounts[i].pending = false
        save()
        Task { await refreshLimits() }
    }

    private func finishCodexSignIn(_ i: Int, ok: Bool, cancelled: Bool) {
        let a = config.codexAccounts[i]
        guard ok, let auth = Self.codexAuth(dir: a.dir) else {
            if !cancelled { banner = "Sign-in for \(a.name) didn't finish. Try again." }
            return
        }
        defer { restartWatch(); rescan() }
        // A browser already signed in to ChatGPT hands back that same account.
        if let twin = Self.codexTwin(accountID: auth.accountID, excluding: a.id, in: config.codexAccounts) {
            banner = "\(a.name) signed in to the same ChatGPT account as \(twin.name). Switch accounts in ChatGPT in your browser, then sign in again."
            config.codexAccounts[i].pending = true
            save()
            return
        }
        config.codexAccounts[i].email = auth.email
        config.codexAccounts[i].plan = auth.plan
        config.codexAccounts[i].accountID = auth.accountID
        config.codexAccounts[i].pending = false
        save()
        Task { await refreshLimits() }
    }

    /// Codex: log out, delete auth.json, and only then trash the folder, so no refresh token lands in the Trash.
    private func removeCodexAccount(_ a: Account, reassignTo: String) {
        guard !a.isPrimary, a.id != reassignTo, Self.codexRemovable(a.dir),
              config.codexAccounts.contains(where: { $0.id == reassignTo }) else { return }
        for i in config.codexRules.indices where config.codexRules[i].accountID == a.id { config.codexRules[i].accountID = reassignTo }
        if config.codexDefaultID == a.id { config.codexDefaultID = reassignTo }
        config.removedNames[a.id] = a.name
        cancelSignIn(a.id)
        config.codexAccounts.removeAll { $0.id == a.id }
        limits[a.id] = nil
        save()
        restartWatch()
        let dir = a.dir, name = a.name
        Task.detached {
            if let exe = Self.codexPath() { Self.codexRun(exe, ["logout"], home: dir) }
            let msg: String?
            if !Self.prepareCodexRemoval(dir: dir) {
                msg = "Removed \(name), but couldn't delete its sign-in file. Delete the folder \(abbreviate(dir)) yourself."
            } else {
                do { try FileManager.default.trashItem(at: URL(fileURLWithPath: dir), resultingItemURL: nil); msg = nil } catch {
                    msg = "Removed \(name), but couldn't move its folder to the Trash: \(Self.reason(error)). You can delete \(abbreviate(dir)) yourself."
                }
            }
            if let msg { await MainActor.run { self.banner = msg } }
        }
    }

    func signOutCodexPrimary() {
        guard let exe = Self.codexPath() else { banner = "Codex isn't installed, so there's nothing to sign out of."; return }
        Task.detached {
            let ok = Self.codexRun(exe, ["logout"], home: nil)
            await MainActor.run {
                if ok { self.limits["codex"] = nil; self.reconcileCodexPrimary() } else { self.banner = "Sign-out didn't finish. Try again." }
                self.rescan()
            }
        }
    }

    func removeAccount(_ id: String, reassignTo: String) {
        if let a = account(id), a.kind == .codex { removeCodexAccount(a, reassignTo: reassignTo); return }
        // Only ever trash a direct child of ~/.claude-anchor/accounts (config.json is hand-editable).
        guard let a = account(id), a.kind == .claude, !a.isPrimary, id != reassignTo,
              (a.dir as NSString).standardizingPath == a.dir,
              (a.dir as NSString).deletingLastPathComponent == Paths.accounts else { return }
        for i in config.rules.indices where config.rules[i].accountID == id { config.rules[i].accountID = reassignTo }
        if config.defaultID == id { config.defaultID = reassignTo }
        config.removedNames[id] = a.name
        cancelSignIn(id)
        Self.run("/usr/bin/security", ["delete-generic-password", "-s", Self.keychainService(for: a)])
        do { try FileManager.default.trashItem(at: URL(fileURLWithPath: a.dir), resultingItemURL: nil) } catch {
            banner = "Removed \(a.name), but couldn't move its folder to the Trash: \(Self.reason(error)). You can delete \(abbreviate(a.dir)) yourself."
        }
        config.accounts.removeAll { $0.id == id }
        limits[id] = nil
        save()
        restartWatch()
    }

    func signOutPrimary() {
        guard let exe = Self.claudePath() else { banner = "Claude Code isn't installed, so there's nothing to sign out of."; return }
        var env = ProcessInfo.processInfo.environment
        env["CLAUDE_CONFIG_DIR"] = nil
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe); p.arguments = ["auth", "logout"]; p.environment = env
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        p.terminationHandler = { proc in
            let ok = proc.terminationStatus == 0
            Task { @MainActor in
                if ok { self.limits["primary"] = nil; self.reconcilePrimary() } else { self.banner = "Sign-out didn't finish. Try again." }
                self.rescan()
            }
        }
        do { try p.run() } catch { banner = "Couldn't start Claude Code to sign out: \(Self.reason(error)). Try again." }
    }

    func rename(_ id: String, to name: String) {
        if let i = config.codexAccounts.firstIndex(where: { $0.id == id }) { config.codexAccounts[i].name = name; save(); refreshRows(); return }
        guard let i = config.accounts.firstIndex(where: { $0.id == id }) else { return }
        config.accounts[i].name = name
        save()
        refreshRows()
    }

    func setFlag(_ id: String, _ flag: SignalFlag) {
        if let i = config.codexAccounts.firstIndex(where: { $0.id == id }) { config.codexAccounts[i].flag = flag; save(); return }
        guard let i = config.accounts.firstIndex(where: { $0.id == id }) else { return }
        config.accounts[i].flag = flag
        save()
    }

    func moveAccounts(fromOffsets: IndexSet, toOffset: Int) {
        let moving = fromOffsets.map { config.accounts[$0] }
        let dest = toOffset - fromOffsets.filter { $0 < toOffset }.count
        for i in fromOffsets.reversed() { config.accounts.remove(at: i) }
        config.accounts.insert(contentsOf: moving, at: dest)
        save()
    }

    // MARK: rules

    func addRule(path: String, accountID: String, tool: Tool) {
        var p = (path as NSString).standardizingPath
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        // The routes file is tab/newline separated; such a path could inject a rule line.
        guard p.hasPrefix("/"), !p.contains(where: { $0 == "\t" || $0.isNewline }) else {
            banner = "That folder name has a tab or line break in it, so it can't be used for a rule."; return
        }
        guard config.accounts(tool).contains(where: { $0.id == accountID }) else { return }   // other tool's id would route to the primary
        var r = config.rules(tool)
        r.removeAll { $0.path == p }
        r.append(Rule(path: p, accountID: accountID))
        config.setRules(r, tool)
        save()
    }

    func removeRule(_ path: String, tool: Tool) {
        config.setRules(config.rules(tool).filter { $0.path != path }, tool)
        save()
    }

    func setRuleOverflow(_ path: String, _ on: Bool, tool: Tool) {
        var r = config.rules(tool)
        guard let i = r.firstIndex(where: { $0.path == path }) else { return }
        r[i].allowOverflow = on
        config.setRules(r, tool)
        save()
    }

    // MARK: VS Code / Cursor

    static let editorSettingsFiles = ["Code", "Cursor", "Code - Insiders"].map { Paths.home + "/Library/Application Support/\($0)/User/settings.json" }
    static let wrapperPath = Paths.anchor + "/bin/claude-wrapper"
    nonisolated static let wrapperKey = "claudeCode.claudeProcessWrapper"

    nonisolated static let wrapperScript = """
    #!/bin/zsh -f
    # Claude Anchor: picks the account for this folder, then runs the Claude binary VS Code passed in.
    if [[ -z ${CLAUDE_CONFIG_DIR:-} && -r "$HOME/.claude-anchor/anchor.zsh" ]]; then
      source "$HOME/.claude-anchor/anchor.zsh"
      _anchor_resolve "$PWD"
      cfg=$REPLY
      (( $+functions[_anchor_sync] )) && _anchor_sync
      if [[ $cfg != - ]]; then export CLAUDE_CONFIG_DIR=$cfg CLAUDE_ANCHOR_ACCOUNT=${cfg:t}
      else export CLAUDE_ANCHOR_ACCOUNT=primary; fi
    fi
    exec "$@"

    """

    /// Runs `wrapperScript` with the repo's anchor.zsh in a scratch home, as VS Code would. The folder's account
    /// must reach Claude as an absolute CLAUDE_CONFIG_DIR: 0.6.0 passed the folder's slug, a fresh signed-out dir.
    /// Run from the repo root (as CI does), so the hook under test is shell/anchor.zsh.
    nonisolated static func wrapperSelfTest() {
        let fm = FileManager.default
        let hook = fm.currentDirectoryPath + "/shell/anchor.zsh"
        precondition(fm.fileExists(atPath: hook), "run --self-test from the repo root (no \(hook))")
        let tmp = NSTemporaryDirectory()
        for old in (try? fm.contentsOfDirectory(atPath: tmp)) ?? [] where old.hasPrefix("anchor-wrapper-") {
            try? fm.removeItem(atPath: tmp + "/" + old)   // left by a run whose assert crashed before its defer
        }
        let base = URL(fileURLWithPath: tmp).appendingPathComponent("anchor-wrapper-" + UUID().uuidString)
        try! fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        // The wrapper sees the physical cwd (/private/var/...); resolvingSymlinksInPath would strip /private again.
        let t = realpath(base.path, nil).map { p in defer { free(p) }; return String(cString: p) }!
        let home = t + "/home", work = home + "/.claude-anchor/accounts/work", wrapper = home + "/.claude-anchor/bin/claude-wrapper"
        let plain = t + "/w/plain", accented = t + "/w/café", long = t + "/w/" + String(repeating: "a", count: 220), primary = t + "/p/sub"
        for d in [home + "/.claude", work, home + "/.claude-anchor/bin", plain, accented, long, primary] {
            try! fm.createDirectory(atPath: d, withIntermediateDirectories: true)
        }
        try! fm.copyItem(atPath: hook, toPath: home + "/.claude-anchor/anchor.zsh")
        try! "\(t)/p\t-\ndefault\t\(work)\n".write(toFile: home + "/.claude-anchor/routes", atomically: true, encoding: .utf8)
        try! wrapperScript.write(toFile: wrapper, atomically: true, encoding: .utf8)
        try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper)

        func launch(in dir: String, env extra: [String: String] = [:]) -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: wrapper)
            p.arguments = ["/bin/sh", "-c", #"printf '%s|%s' "${CLAUDE_CONFIG_DIR--}" "${CLAUDE_ANCHOR_ACCOUNT-}""#]
            p.currentDirectoryURL = URL(fileURLWithPath: dir)
            p.environment = ["HOME": home, "PATH": "/usr/bin:/bin"].merging(extra) { $1 }
            let pipe = Pipe()
            p.standardOutput = pipe
            try! p.run()
            let d = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(decoding: d, as: UTF8.self)
        }
        for dir in [plain, accented, long] {
            let got = launch(in: dir)
            assert(got == work + "|work", "wrapper in \(dir) ran with \(got)")
        }
        assert(launch(in: primary) == "-|primary", "a rule to the primary leaves CLAUDE_CONFIG_DIR unset")
        assert(launch(in: plain, env: ["CLAUDE_CONFIG_DIR": "/elsewhere"]) == "/elsewhere|", "an explicit CLAUDE_CONFIG_DIR wins")
        // The wrapper must hold on to the account itself, not rely on _anchor_sync keeping REPLY.
        let h = try! FileHandle(forWritingTo: URL(fileURLWithPath: home + "/.claude-anchor/anchor.zsh"))
        h.seekToEndOfFile(); h.write(Data("\n_anchor_sync() { REPLY=clobbered }\n".utf8)); try! h.close()
        assert(launch(in: plain) == work + "|work", "wrapper with a sync that sets REPLY")
        print("Wrapper selfTest OK")
    }

    static let codexWrapperPath = Paths.anchor + "/bin/codex-wrapper"
    nonisolated static let codexWrapperKey = "chatgpt.cliExecutable"

    /// VS Code's Codex extension can't route per folder, so it follows the Codex default: the `default` line of
    /// codex-routes is read as plain data (no eval, no sourcing). The real binary is the last PATH entry's codex
    /// (the extension appends its own bin dir), or the newest bundled one.
    nonisolated static let codexWrapperScript = """
    #!/bin/zsh -f
    # Claude Anchor: points the Codex extension at the Codex default account, then runs the real codex.
    setopt numericglobsort
    if [[ -z ${CODEX_HOME:-} || $CODEX_HOME == "$HOME/.codex" ]]; then
      r=
      if [[ -r "$HOME/.claude-anchor/codex-routes" ]]; then
        while IFS=$'\t' read -r k v; do
          [[ $k == default ]] && r=$v
        done < "$HOME/.claude-anchor/codex-routes"
      fi
      [[ -n $r && $r != - ]] && export CODEX_HOME=$r
    fi
    self=${0:A}; bin=
    for e in ${(Oa)path}; do
      c=$e/codex
      if [[ -n $e && -f $c && -x $c && ${c:A} != $self ]]; then bin=$c; break; fi
    done
    if [[ -z $bin ]]; then
      for c in $HOME/.vscode/extensions/openai.chatgpt-*/bin/macos-*/codex(NOn) $HOME/.cursor/extensions/openai.chatgpt-*/bin/macos-*/codex(NOn); do
        if [[ -x $c && ${c:A} != $self ]]; then bin=$c; break; fi
      done
    fi
    if [[ -z $bin ]]; then print -u2 "Claude Anchor: couldn't find the codex program."; exit 127; fi
    exec "$bin" "$@"

    """

    /// Runs `codexWrapperScript` in a scratch home with fake binaries, as the Codex extension would.
    nonisolated static func codexWrapperSelfTest() {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("anchor-codexwrap-" + UUID().uuidString)
        try! fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let t = realpath(base.path, nil).map { p in defer { free(p) }; return String(cString: p) }!
        let home = t + "/home", acct = home + "/.claude-anchor/codex-accounts/work", wrapper = home + "/.claude-anchor/bin/codex-wrapper"
        let ext = t + "/ext/bin/macos-x", shim = t + "/shim", routes = home + "/.claude-anchor/codex-routes"
        for d in [acct, home + "/.claude-anchor/bin", ext, shim] { try! fm.createDirectory(atPath: d, withIntermediateDirectories: true) }
        try! codexWrapperScript.write(toFile: wrapper, atomically: true, encoding: .utf8)
        try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper)
        try! "#!/bin/sh\nprintf '%s|%s' \"${CODEX_HOME--}\" \"$*\"\n".write(toFile: ext + "/codex", atomically: true, encoding: .utf8)
        try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ext + "/codex")
        try! fm.createSymbolicLink(atPath: shim + "/codex", withDestinationPath: wrapper)

        func launch(path: String, env extra: [String: String] = [:]) -> (String, Int32) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: wrapper)
            p.arguments = ["app-server", "-c", "x"]
            p.environment = ["HOME": home, "PATH": path].merging(extra) { $1 }
            let pipe = Pipe()
            p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
            try! p.run()
            let d = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (String(decoding: d, as: UTF8.self), p.terminationStatus)
        }
        let withExt = "/usr/bin:/bin:" + ext
        try! "# generated\n/some/dir\t-\ndefault\t\(acct)\n".write(toFile: routes, atomically: true, encoding: .utf8)
        assert(launch(path: withExt).0 == acct + "|app-server -c x", "the default account becomes CODEX_HOME")
        assert(launch(path: withExt, env: ["CODEX_HOME": "/elsewhere"]).0 == "/elsewhere|app-server -c x", "an explicit CODEX_HOME wins")
        assert(launch(path: withExt, env: ["CODEX_HOME": home + "/.codex"]).0 == acct + "|app-server -c x", "~/.codex counts as unset")
        assert(launch(path: "/usr/bin:/bin:" + ext + ":" + shim).0 == acct + "|app-server -c x", "the wrapper on PATH never execs itself")
        try! "default\t-\n".write(toFile: routes, atomically: true, encoding: .utf8)
        assert(launch(path: withExt).0 == "-|app-server -c x", "a primary default leaves CODEX_HOME unset")
        let none = launch(path: "/usr/bin:/bin:" + shim)
        assert(none.1 == 127 && none.0.isEmpty, "no codex anywhere exits 127")
        print("Codex wrapper selfTest OK")
    }

    /// Scratch-dir checks for the Codex account helpers; no CLI, no real folders.
    nonisolated static func codexAccountsSelfTest() {
        let fm = FileManager.default
        let t = NSTemporaryDirectory() + "anchor-codexacct-" + UUID().uuidString
        try! fm.createDirectory(atPath: t, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: t) }
        let prim = t + "/.codex", root = t + "/codex-accounts", dir = root + "/work"
        try! fm.createDirectory(atPath: prim + "/skills", withIntermediateDirectories: true)
        for f in ["auth.json", "config.toml", "history.jsonl", "AGENTS.md"] { fm.createFile(atPath: prim + "/" + f, contents: Data("x".utf8)) }
        for d in ["sessions", "memories", "log", "archived_sessions"] { try! fm.createDirectory(atPath: prim + "/" + d, withIntermediateDirectories: true) }
        try! makeCodexDir(dir, primary: prim, base: t)
        let got = Set(try! fm.contentsOfDirectory(atPath: dir))
        assert(got == ["config.toml", "AGENTS.md", "skills"], "only the allowed symlinks: \(got)")
        assert((try? fm.destinationOfSymbolicLink(atPath: dir + "/skills")) == prim + "/skills", "skills is a symlink")
        assert((try! fm.attributesOfItem(atPath: dir)[.posixPermissions] as! Int) == 0o700, "account folder is 0700")
        try! makeCodexDir(dir, primary: prim, base: t)   // idempotent
        // Path guard.
        assert(codexRemovable(dir, root: root), "a direct child is removable")
        assert(!codexRemovable(root + "/../x", root: root) && !codexRemovable(root + "/work/../work", root: root), "../ is refused")
        assert(!codexRemovable(t + "/elsewhere/work", root: root) && !codexRemovable(root + "/a/b", root: root) && !codexRemovable(root, root: root), "outside or nested is refused")
        assert(!codexRemovable(Paths.codexPrimaryDir, root: (Paths.codexPrimaryDir as NSString).deletingLastPathComponent), "the primary is never removable")
        // auth.json is gone before the folder would be trashed.
        fm.createFile(atPath: dir + "/auth.json", contents: Data("{}".utf8))
        assert(prepareCodexRemoval(dir: dir) && !fm.fileExists(atPath: dir + "/auth.json"), "auth.json deleted first")
        assert(prepareCodexRemoval(dir: dir), "no auth.json is fine")
        try! fm.createSymbolicLink(atPath: dir + "/auth.json", withDestinationPath: prim + "/auth.json")
        assert(prepareCodexRemoval(dir: dir) && fm.fileExists(atPath: prim + "/auth.json"), "a symlinked auth.json is unlinked, not followed")
        // Twin check: by account id, other Codex accounts only.
        let list = [Account(id: "a", name: "A", flag: .a, dir: "/a", tool: .codex, accountID: "x"),
                    Account(id: "b", name: "B", flag: .b, dir: "/b", tool: .codex, accountID: "y")]
        assert(codexTwin(accountID: "x", excluding: "b", in: list)?.id == "a", "same account id is a twin")
        assert(codexTwin(accountID: "x", excluding: "a", in: list) == nil, "not its own twin")
        assert(codexTwin(accountID: nil, excluding: "b", in: list) == nil && codexTwin(accountID: "z", excluding: "b", in: list) == nil, "nil or new id: no twin")
        // Editor setting for the Codex key.
        let key = codexWrapperKey, ours = "/Users/u/.claude-anchor/bin/codex-wrapper", suf = "/.claude-anchor/bin/codex-wrapper"
        let ins = setSetting(in: "{\n}", key: key, path: ours, ourSuffix: suf)!
        assert(ins.contains("\"chatgpt.cliExecutable\": \"\(ours)\""), "inserted")
        assert(setSetting(in: ins, key: key, path: nil, ourSuffix: suf)?.contains("chatgpt") == false, "ours removed")
        let foreign = "{\n    \"chatgpt.cliExecutable\": \"/opt/mine\"\n}"
        assert(setSetting(in: foreign, key: key, path: ours, ourSuffix: suf) == nil, "foreign value is never overwritten")
        assert(setSetting(in: foreign, key: key, path: nil, ourSuffix: suf) == foreign, "foreign value is never removed")
        print("Codex accounts selfTest OK")
    }

    /// Writes the shim and the editor wrapper under ~/.claude-anchor, only when content differs.
    func installShellFiles() {
        var failure: Error?
        func put(_ path: String, _ text: String, mode: Int) {
            do {
                if (try? String(contentsOfFile: path, encoding: .utf8)) != text { try Self.writeSecure(Data(text.utf8), to: path, mode: mode) }
                else { try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path) }
            } catch { failure = failure ?? error }
        }
        do { try Self.ensureDir(Paths.anchor); try Self.ensureDir(Paths.anchor + "/bin") } catch { reportSaveError(error); return }
        if let u = Bundle.main.url(forResource: "anchor", withExtension: "zsh"),
           let t = try? String(contentsOf: u, encoding: .utf8) { put(Paths.anchor + "/anchor.zsh", t, mode: 0o644) }
        put(Self.wrapperPath, Self.wrapperScript, mode: 0o755)
        put(Self.codexWrapperPath, Self.codexWrapperScript, mode: 0o755)
        if let failure { reportSaveError(failure) }
    }

    /// Sets (path) or removes (nil) the wrapper key in settings text, editing as text to keep comments.
    /// Returns nil when a foreign wrapper is set and we were asked to set ours.
    nonisolated static func setWrapper(in text: String, path: String?) -> String? {
        setSetting(in: text, key: wrapperKey, path: path, ourSuffix: "/.claude-anchor/bin/claude-wrapper")
    }

    /// Same for any string setting: `ourSuffix` is what a value we wrote ends with; anything else is foreign.
    nonisolated static func setSetting(in text: String, key: String, path: String?, ourSuffix: String) -> String? {
        // try!: the pattern is built from a constant key, can't fail at runtime.
        let line = try! NSRegularExpression(
            pattern: "^[ \\t]*\"" + NSRegularExpression.escapedPattern(for: key) + "\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\"[ \\t]*(,?)[^\\n]*\\n?",
            options: .anchorsMatchLines)
        let ns = text as NSString
        if let m = line.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
            let value = ns.substring(with: m.range(at: 1)), comma = ns.substring(with: m.range(at: 2))
            let ours = value.hasSuffix(ourSuffix)
            guard let path else {
                if !ours { return text }
                var head = ns.substring(to: m.range.location)
                let tail = ns.substring(from: m.range.location + m.range.length)
                if comma.isEmpty, tail.drop(while: \.isWhitespace).first == "}" {   // was the last entry
                    head = head.replacingOccurrences(of: ",((?:\\s*//[^\\n]*)*\\s*)$", with: "$1", options: .regularExpression)
                }
                return head + tail
            }
            if value == path { return text }
            if !ours { return nil }
            return ns.replacingCharacters(in: m.range(at: 1), with: path)
        }
        guard let path, let brace = text.firstIndex(of: "{") else { return text }
        let rest = text[text.index(after: brace)...].replacingOccurrences(of: "(?m)^\\s*//.*$", with: "", options: .regularExpression)
        let comma = rest.drop(while: \.isWhitespace).first == "}" ? "" : ","
        var out = text
        out.insert(contentsOf: "\n    \"\(key)\": \"\(path)\"\(comma)", at: text.index(after: brace))
        return out
    }

    /// Turns the wrapper on or off in VS Code / Cursor user settings. Returns an error message or nil.
    func setEditorIntegration(_ on: Bool) -> String? {
        if let msg = editSettings(key: Self.wrapperKey, suffix: "/.claude-anchor/bin/claude-wrapper", path: Self.wrapperPath, on: on,
                                  foreign: "VS Code already uses a different Claude process wrapper. Remove it from settings, then try again.") { return msg }
        config.editorIntegration = on
        save()
        return nil
    }

    /// Points VS Code's Codex extension at the Codex wrapper (or back). Returns an error message or nil.
    func setCodexEditorIntegration(_ on: Bool) -> String? {
        if let msg = editSettings(key: Self.codexWrapperKey, suffix: "/.claude-anchor/bin/codex-wrapper", path: Self.codexWrapperPath, on: on,
                                  foreign: "VS Code already points Codex at a different program. Remove chatgpt.cliExecutable from settings, then try again.") { return msg }
        config.codexEditorIntegration = on
        save()
        return nil
    }

    private func editSettings(key: String, suffix: String, path: String, on: Bool, foreign: String) -> String? {
        installShellFiles()
        let fm = FileManager.default
        func parses(_ t: String) -> Bool {   // settings.json allows comments and trailing commas
            let t = t.replacingOccurrences(of: "(?m)^\\s*//.*$", with: "", options: .regularExpression)
                .replacingOccurrences(of: ",(\\s*[}\\]])", with: "$1", options: .regularExpression)
            return (try? JSONSerialization.jsonObject(with: Data(t.utf8))) != nil
        }
        let found = Self.editorSettingsFiles.filter { fm.fileExists(atPath: $0) }
        if found.isEmpty { return "No VS Code or Cursor settings found." }
        for f in found {
            guard let old = try? String(contentsOfFile: f, encoding: .utf8) else { return "Couldn't read \(abbreviate(f)). Check its permissions." }
            if old.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            if !parses(old) { return "\(abbreviate(f)) isn't valid JSON, so Anchor left it alone. Fix the file, then try again." }
            guard let new = Self.setSetting(in: old, key: key, path: on ? path : nil, ourSuffix: suffix) else { return foreign }
            if new == old { continue }
            if !parses(new) { return "Couldn't safely edit \(abbreviate(f)). Add the setting by hand." }
            let bak = f + ".anchor-backup"
            do {
                if !fm.fileExists(atPath: bak) { try fm.copyItem(atPath: f, toPath: bak) }
                try new.write(toFile: f, atomically: true, encoding: .utf8)
            } catch { return "Couldn't update \(abbreviate(f)): \(Self.reason(error)). Nothing was changed there." }
        }
        return nil
    }
}
