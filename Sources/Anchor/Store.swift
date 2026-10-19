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
    nonisolated static func claudeJSON(for a: Account) -> [String: Any] {
        let path = a.isPrimary ? Paths.home + "/.claude.json" : a.dir + "/.claude.json"
        guard let d = FileManager.default.contents(atPath: path),
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

    /// Keeps the primary account's pending flag in step with what the CLI actually has (sign-in or sign-out in Terminal).
    func reconcilePrimary() {
        guard live, let i = config.accounts.firstIndex(where: { $0.isPrimary }), !signingIn.contains(config.accounts[i].id) else { return }
        let a = config.accounts[i], ok = Self.signedIn(a)
        if ok && a.pending {
            config.accounts[i].email = Self.email(of: a)
            config.accounts[i].plan = Self.keychainPlan(for: a)
            config.accounts[i].pending = false
            save()
            Task { await refreshLimits() }
        } else if !ok && !a.pending {
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
        if Self.claudeFastPath() != nil { cliInstalled = true; return }
        Task.detached {
            let found = Self.claudePath() != nil
            await MainActor.run { self.cliInstalled = found }
        }
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
        let accts = accounts, u = usage
        AnchorRuntime.queue.async {
            u.scan(accounts: accts)
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

    nonisolated static func routesText(config: Config, limits: [String: Limits]) -> String {
        func dir(_ id: String) -> String { config.accounts.first { $0.id == id }?.configDirEnv ?? "-" }
        func hot(_ id: String) -> Bool {
            guard let l = limits[id] else { return false }
            return max(l.fiveHour?.percent ?? 0, l.weekly?.percent ?? 0) >= config.overflowThreshold
        }
        var out = "# generated by Claude Anchor — edit in the app\n"
        for r in config.rules.sorted(by: { $0.path.count > $1.path.count })
        where !r.path.contains(where: { $0 == "\t" || $0.isNewline }) {   // hand-edited config guard
            let id = (r.allowOverflow && hot(r.accountID)) ? config.defaultID : r.accountID
            out += "\(r.path)\t\(dir(id))\n"
        }
        return out + "default\t\(dir(config.defaultID))\n"
    }

    /// The account `claude` gets in `cwd`, by the same rules as the routes file: longest matching folder rule
    /// (its overflow sends it to the default while hot), else the default.
    nonisolated static func routedAccount(cwd: String, config: Config, limits: [String: Limits]) -> String {
        let rule = config.rules.filter { $0.path == "/" || cwd == $0.path || cwd.hasPrefix($0.path + "/") }
            .max { $0.path.count < $1.path.count }
        guard let r = rule else { return config.defaultID }
        let l = limits[r.accountID]
        let hot = max(l?.fiveHour?.percent ?? 0, l?.weekly?.percent ?? 0) >= config.overflowThreshold
        return r.allowOverflow && hot ? config.defaultID : r.accountID
    }

    func writeRoutes() {
        guard !saveBlocked else { return }
        do {
            try Self.ensureDir(Paths.anchor)
            try Self.writeSecure(Data(Self.routesText(config: config, limits: limits).utf8), to: Paths.routes)
        } catch { reportSaveError(error) }
    }

    func setDefault(_ id: String) {
        config.defaultID = id
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
              let t = account(targetID), !t.pending, t.id != s.accountID else { banner = "No recent conversation to continue."; return }
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
        if Self.routedAccount(cwd: s.cwd, config: after, limits: limits) == t.id { return nil }
        let rule = config.rules.filter { s.cwd == $0.path || s.cwd.hasPrefix($0.path + "/") || $0.path == "/" }
            .max { $0.path.count < $1.path.count }
        let pinned = rule.flatMap { account($0.accountID) }?.name ?? "another account"
        return "\(abbreviate(rule?.path ?? s.cwd)) always uses \(pinned) (a folder rule). Change it in Rules to continue on \(t.name) in VS Code."
    }

    // MARK: accounts

    @discardableResult
    func addAccount(name: String, flag: SignalFlag) -> Account? {
        var slug = String(name.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if slug.isEmpty { slug = "account" }
        var id = slug, n = 2
        while id == "primary" || account(id) != nil { id = "\(slug)-\(n)"; n += 1 }
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

    /// Runs `claude auth login` in the background for this account. The CLI opens the browser and
    /// exits once the browser hands the code back, so no Terminal is involved.
    func signIn(_ id: String) {
        guard let a = account(id), AnchorRuntime.logins[id] == nil else { return }
        guard let exe = Self.claudePath() else { banner = "Claude Code isn't installed. Install it, then sign in again."; return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["auth", "login"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
        if let d = a.configDirEnv { env["CLAUDE_CONFIG_DIR"] = d } else { env["CLAUDE_CONFIG_DIR"] = nil }
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
            banner = "Couldn't start Claude Code to sign in \(a.name): \(Self.reason(error)). Check that `claude` runs in Terminal, then try again."
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

    func removeAccount(_ id: String, reassignTo: String) {
        // Only ever trash a direct child of ~/.claude-anchor/accounts (config.json is hand-editable).
        guard let a = account(id), !a.isPrimary, id != reassignTo,
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
        guard let i = config.accounts.firstIndex(where: { $0.id == id }) else { return }
        config.accounts[i].name = name
        save()
        refreshRows()
    }

    func setFlag(_ id: String, _ flag: SignalFlag) {
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

    func addRule(path: String, accountID: String) {
        var p = (path as NSString).standardizingPath
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        // The routes file is tab/newline separated; such a path could inject a rule line.
        guard p.hasPrefix("/"), !p.contains(where: { $0 == "\t" || $0.isNewline }) else {
            banner = "That folder name has a tab or line break in it, so it can't be used for a rule."; return
        }
        config.rules.removeAll { $0.path == p }
        config.rules.append(Rule(path: p, accountID: accountID))
        save()
    }

    func removeRule(_ path: String) {
        config.rules.removeAll { $0.path == path }
        save()
    }

    func setRuleOverflow(_ path: String, _ on: Bool) {
        guard let i = config.rules.firstIndex(where: { $0.path == path }) else { return }
        config.rules[i].allowOverflow = on
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
      (( $+functions[_anchor_sync] )) && _anchor_sync
      if [[ $REPLY != - ]]; then export CLAUDE_CONFIG_DIR=$REPLY CLAUDE_ANCHOR_ACCOUNT=${REPLY:t}
      else export CLAUDE_ANCHOR_ACCOUNT=primary; fi
    fi
    exec "$@"

    """

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
        if let failure { reportSaveError(failure) }
    }

    /// Sets (path) or removes (nil) the wrapper key in settings text, editing as text to keep comments.
    /// Returns nil when a foreign wrapper is set and we were asked to set ours.
    nonisolated static func setWrapper(in text: String, path: String?) -> String? {
        // try!: constant pattern, can't fail at runtime.
        let line = try! NSRegularExpression(
            pattern: "^[ \\t]*\"claudeCode\\.claudeProcessWrapper\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\"[ \\t]*(,?)[^\\n]*\\n?",
            options: .anchorsMatchLines)
        let ns = text as NSString
        if let m = line.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
            let value = ns.substring(with: m.range(at: 1)), comma = ns.substring(with: m.range(at: 2))
            let ours = value.hasSuffix("/.claude-anchor/bin/claude-wrapper")
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
        out.insert(contentsOf: "\n    \"\(wrapperKey)\": \"\(path)\"\(comma)", at: text.index(after: brace))
        return out
    }

    /// Turns the wrapper on or off in VS Code / Cursor user settings. Returns an error message or nil.
    func setEditorIntegration(_ on: Bool) -> String? {
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
            guard let new = Self.setWrapper(in: old, path: on ? Self.wrapperPath : nil) else {
                return "VS Code already uses a different Claude process wrapper. Remove it from settings, then try again."
            }
            if new == old { continue }
            if !parses(new) { return "Couldn't safely edit \(abbreviate(f)). Add the setting by hand." }
            let bak = f + ".anchor-backup"
            do {
                if !fm.fileExists(atPath: bak) { try fm.copyItem(atPath: f, toPath: bak) }
                try new.write(toFile: f, atomically: true, encoding: .utf8)
            } catch { return "Couldn't update \(abbreviate(f)): \(Self.reason(error)). Nothing was changed there." }
        }
        config.editorIntegration = on
        save()
        return nil
    }
}
