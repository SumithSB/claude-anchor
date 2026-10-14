import Foundation

/// Incremental token/cost index over every account's Claude Code transcripts.
final class UsageIndex: @unchecked Sendable {
    private struct Agg: Codable { var input = 0, output = 0, cacheRead = 0, cacheWrite = 0; var cost = 0.0 }
    private struct FileState: Codable { var offset: UInt64; var size: UInt64; var inode: UInt64 }
    private struct Last: Codable { var cwd: String; var accountID: String; var ts: Double; var file: String? }
    private struct State: Codable {
        var agg: [String: Agg] = [:]       // "day\u{1F}account\u{1F}cwd\u{1F}model"
        var files: [String: FileState] = [:]
        var recent: [String] = []          // last dedup keys, so a rescan after truncation doesn't double count
        var last: Last?
    }
    private struct Rec { var key: String, day: String, cwd: String, model: String, ts: Double
                         var input: Int, output: Int, cacheRead: Int, cacheWrite: Int }

    private static let sep = "\u{1F}"
    private static let maxRecent = 5000
    private static let keepDays = 90

    private let lock = NSLock()
    private let scanGate = NSLock()
    private let storePath: String
    private var state = State()
    private var seen = Set<String>()

    var lastSession: (cwd: String, accountID: String, file: String?)? {
        lock.lock(); defer { lock.unlock() }
        return state.last.map { ($0.cwd, $0.accountID, $0.file) }
    }

    /// Marks a copied transcript as already read, so its history never counts as the target account's usage.
    func markCopied(path: String) {
        guard let at = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (at[.size] as? NSNumber)?.uint64Value else { return }
        let inode = (at[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        setFile(path, FileState(offset: size, size: size, inode: inode))
    }

    /// Conversations the shell hook copied between accounts (`<path>\t<copied size>` per line): start those
    /// files at the copied size, so shared history isn't counted again for the account it was copied to.
    private func applyLedger() {
        let fm = FileManager.default
        let path = (storePath as NSString).deletingLastPathComponent + "/copied", work = path + ".processing"
        if !fm.fileExists(atPath: work) { guard (try? fm.moveItem(atPath: path, toPath: work)) != nil else { return } }
        defer { try? fm.removeItem(atPath: work) }
        guard let text = try? String(contentsOfFile: work, encoding: .utf8) else { return }
        for line in text.split(separator: "\n") {
            let p = line.split(separator: "\t", maxSplits: 1)
            guard p.count == 2, let size = UInt64(p[1]),
                  let at = try? fm.attributesOfItem(atPath: String(p[0])) else { continue }
            let inode = (at[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            lock.lock()
            let cur = state.files[String(p[0])]
            if cur == nil || cur?.inode != inode || (cur?.offset ?? 0) < size {
                state.files[String(p[0])] = FileState(offset: size, size: size, inode: inode)
            }
            lock.unlock()
        }
    }

    convenience init() { self.init(storePath: Paths.usage) }

    init(storePath: String) {
        self.storePath = storePath
        if let d = FileManager.default.contents(atPath: storePath),
           let s = try? JSONDecoder().decode(State.self, from: d) { state = s; seen = Set(s.recent) }
    }

    // MARK: pricing / labels

    // ponytail: estimate table (USD per million tokens), update when pricing changes.
    static func price(_ model: String) -> (input: Double, output: Double) {
        let m = model.lowercased()
        if m.contains("opus") { return m.contains("opus-4-5") || m.contains("opus-5") ? (5, 25) : (15, 75) }
        if m.contains("fable") { return (5, 25) }
        if m.contains("haiku") { return (1, 5) }
        return (3, 15)
    }

    static func prettyModel(_ id: String) -> String {
        var parts = id.hasPrefix("claude-") ? String(id.dropFirst(7)).split(separator: "-").map(String.init) : []
        if let l = parts.last, l.count == 8, l.allSatisfy(\.isNumber) { parts.removeLast() }
        guard let fam = parts.first, fam.allSatisfy(\.isLetter) else { return id }
        let ver = parts.dropFirst()
        guard ver.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return id }
        return ([fam.capitalized] + (ver.isEmpty ? [] : [ver.joined(separator: ".")])).joined(separator: " ")
    }

    // MARK: scan

    func scan(accounts: [Account]) {
        scanGate.lock(); defer { scanGate.unlock() }
        applyLedger()
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso2 = ISO8601DateFormatter()
        let dayFmt = DateFormatter(); dayFmt.locale = Locale(identifier: "en_US_POSIX"); dayFmt.dateFormat = "yyyy-MM-dd"
        let fm = FileManager.default
        for acct in accounts {
            let root = acct.dir + "/projects"
            guard let en = fm.enumerator(atPath: root) else { continue }
            for case let rel as String in en where rel.hasSuffix(".jsonl") {
                let path = root + "/" + rel
                guard let at = try? fm.attributesOfItem(atPath: path),
                      let size = (at[.size] as? NSNumber)?.uint64Value else { continue }
                let inode = (at[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
                lock.lock(); var fs = state.files[path] ?? FileState(offset: 0, size: 0, inode: inode); lock.unlock()
                if fs.inode != inode || size < fs.offset { fs.offset = 0 }   // rotated or truncated
                if size == fs.offset { fs.size = size; fs.inode = inode; setFile(path, fs); continue }
                readNew(path: path, acct: acct.id, from: fs.offset, size: size, inode: inode) { line in
                    Self.parse(line, iso, iso2, dayFmt)
                }
            }
        }
        lock.lock()
        let cutoff = dayFmt.string(from: Calendar.current.date(byAdding: .day, value: -Self.keepDays, to: Date()) ?? .distantPast)
        state.agg = state.agg.filter { $0.key.prefix(while: { $0 != "\u{1F}" }) >= cutoff[...] }
        lock.unlock()
        persist()
    }

    private func setFile(_ path: String, _ fs: FileState) { lock.lock(); state.files[path] = fs; lock.unlock() }

    /// Reads [from, size) in chunks, processing only complete lines; offset advances per chunk.
    private func readNew(path: String, acct: String, from: UInt64, size: UInt64, inode: UInt64,
                         parse: (UnsafeRawBufferPointer) -> Rec?) {
        guard let fh = FileHandle(forReadingAtPath: path) else { return }
        defer { try? fh.close() }
        var offset = from
        try? fh.seek(toOffset: offset)
        var carry = Data()
        while offset + UInt64(carry.count) < size {
            let chunk = (try? fh.read(upToCount: 1 << 20)) ?? Data()
            if chunk.isEmpty { break }
            carry.append(chunk)
            guard let nl = carry.lastIndex(of: 10) else { continue }   // no complete line yet
            let n = nl - carry.startIndex + 1
            var recs: [Rec] = []
            // Drain JSONSerialization temporaries per chunk; GCD only drains at the end of the whole scan.
            autoreleasepool { carry.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var start = 0
                while start < n, let p = memchr(base + start, 10, n - start) {
                    let end = base.distance(to: UnsafeRawPointer(p))
                    if let r = parse(UnsafeRawBufferPointer(rebasing: raw[start..<end])) { recs.append(r) }
                    start = end + 1
                }
            } }
            offset += UInt64(n)
            carry.removeSubrange(carry.startIndex..<carry.startIndex + n)
            lock.lock()
            for r in recs { apply(r, acct: acct, file: path) }
            state.files[path] = FileState(offset: offset, size: size, inode: inode)
            lock.unlock()
        }
    }

    /// Assistant lines with usage; synthetic ones get an empty key (they only feed lastSession).
    private static func parse(_ line: UnsafeRawBufferPointer, _ iso: ISO8601DateFormatter,
                              _ iso2: ISO8601DateFormatter, _ dayFmt: DateFormatter) -> Rec? {
        guard line.count > 2, let base = line.baseAddress, memmem(base, line.count, "\"usage\"", 7) != nil,
              let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              o["type"] as? String == "assistant",
              let cwd = o["cwd"] as? String, let tsStr = o["timestamp"] as? String,
              let date = iso.date(from: tsStr) ?? iso2.date(from: tsStr),
              let msg = o["message"] as? [String: Any], let u = msg["usage"] as? [String: Any]
        else { return nil }
        let model = msg["model"] as? String ?? "unknown"
        func n(_ k: String) -> Int { (u[k] as? NSNumber)?.intValue ?? 0 }
        let key = model == "<synthetic>" ? "" : "\(msg["id"] as? String ?? "")|\(o["requestId"] as? String ?? "")"
        return Rec(key: key, day: dayFmt.string(from: date), cwd: cwd, model: model, ts: date.timeIntervalSince1970,
                    input: n("input_tokens"), output: n("output_tokens"),
                    cacheRead: n("cache_read_input_tokens"), cacheWrite: n("cache_creation_input_tokens"))
    }

    private func apply(_ r: Rec, acct: String, file: String) {   // lock held
        if r.ts >= (state.last?.ts ?? 0) { state.last = Last(cwd: r.cwd, accountID: acct, ts: r.ts, file: file) }
        if r.key.isEmpty || r.key == "|" || !seen.insert(r.key).inserted { return }
        state.recent.append(r.key)
        if state.recent.count > Self.maxRecent * 2 {
            state.recent.removeFirst(state.recent.count - Self.maxRecent)
            seen = Set(state.recent)
        }
        let p = Self.price(r.model)
        let cost = (Double(r.input) * p.input + Double(r.output) * p.output
                    + Double(r.cacheRead) * p.input * 0.1 + Double(r.cacheWrite) * p.input * 1.25) / 1e6
        let k = [r.day, acct, r.cwd, r.model].joined(separator: Self.sep)
        var a = state.agg[k] ?? Agg()
        a.input += r.input; a.output += r.output; a.cacheRead += r.cacheRead; a.cacheWrite += r.cacheWrite; a.cost += cost
        state.agg[k] = a
    }

    /// Set when the last save failed (disk full, permissions); read after a scan to tell the user.
    var persistError: String? { lock.lock(); defer { lock.unlock() }; return _persistError }
    private var _persistError: String?

    private func persist() {
        lock.lock()
        let data = try? JSONEncoder().encode(state)
        lock.unlock()
        guard let data else { return }
        do {
            try AppModel.ensureDir((storePath as NSString).deletingLastPathComponent)
            try AppModel.writeSecure(data, to: storePath)
            lock.lock(); _persistError = nil; lock.unlock()
        } catch {
            lock.lock(); _persistError = AppModel.reason(error); lock.unlock()
        }
    }

    func purge(accountID: String) {
        lock.lock()
        state.agg = state.agg.filter { $0.key.components(separatedBy: Self.sep).dropFirst().first != accountID }
        if state.last?.accountID == accountID { state.last = nil }
        lock.unlock()
        persist()
    }

    // MARK: rows

    func rows(by: GroupBy, days: Int, accounts: [Account], removed: [String: String]) -> [UsageRow] {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        let cutoff = f.string(from: Calendar.current.date(byAdding: .day, value: -(max(days, 1) - 1), to: Date()) ?? .distantPast)
        lock.lock(); let agg = state.agg; lock.unlock()
        var groups: [String: (tokens: Int, out: Int, cost: Double)] = [:]
        for (k, a) in agg {
            let p = k.components(separatedBy: Self.sep)
            guard p.count == 4, p[0] >= cutoff else { continue }
            let id = by == .account ? p[1] : by == .project ? p[2] : p[3]
            var g = groups[id] ?? (0, 0, 0)
            g.tokens += a.input + a.output + a.cacheRead + a.cacheWrite; g.out += a.output; g.cost += a.cost
            groups[id] = g
        }
        func label(_ id: String) -> String {
            switch by {
            case .account: return accounts.first { $0.id == id }?.name ?? removed[id].map { "\($0) (removed)" } ?? id
            case .project: return id.hasPrefix(Paths.home) ? "~" + id.dropFirst(Paths.home.count) : id
            case .model: return Self.prettyModel(id)
            }
        }
        return groups.sorted { $0.value.tokens > $1.value.tokens }.map { id, g in
            UsageRow(id: id, label: label(id), accountID: by == .account ? id : nil,
                     tokens: g.tokens, outputTokens: g.out, cost: g.cost)
        }
    }

    // MARK: self test

    static func selfTest() {
        assert(prettyModel("claude-opus-5-5") == "Opus 5.5")
        assert(prettyModel("claude-sonnet-4-5-20250929") == "Sonnet 4.5")
        assert(prettyModel("claude-haiku-5-5") == "Haiku 5.5")
        assert(prettyModel("gpt-4") == "gpt-4")

        let tmp = NSTemporaryDirectory() + "anchor-usage-\(UUID().uuidString)"
        let dir = tmp + "/acct/projects/p"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let ts = ISO8601DateFormatter().string(from: Date())
        func line(_ id: String, _ model: String, _ i: Int, _ o: Int, _ cr: Int, _ cw: Int) -> String {
            #"{"type":"assistant","cwd":"/w/x","timestamp":"\#(ts)","requestId":"r\#(id)","message":{"id":"m\#(id)","model":"\#(model)","usage":{"input_tokens":\#(i),"cache_creation_input_tokens":\#(cw),"cache_read_input_tokens":\#(cr),"output_tokens":\#(o)}}}"#
        }
        let a = line("1", "claude-opus-5-5", 10, 20, 100, 1000)
        let file = dir + "/s.jsonl"
        let text = [a, a, #"{"type":"user","message":{"content":"usage"}}"#, line("9", "<synthetic>", 5, 5, 0, 0),
                    #"{"type":"assistant", "usage" broken"#, line("2", "claude-sonnet-4-5-20250929", 1, 2, 0, 0)]
            .joined(separator: "\n") + "\n"
        try? text.write(toFile: file, atomically: true, encoding: .utf8)

        let acct = Account(id: "t", name: "T", flag: .a, dir: tmp + "/acct")
        let ix = UsageIndex(storePath: tmp + "/store/usage.json")
        func total() -> (Int, Int, Double) {
            let r = ix.rows(by: .model, days: 1, accounts: [acct], removed: [:])
            return (r.reduce(0) { $0 + $1.tokens }, r.reduce(0) { $0 + $1.outputTokens }, r.reduce(0) { $0 + $1.cost })
        }
        ix.scan(accounts: [acct])
        var t = total()
        assert(t.0 == 1133 && t.1 == 22, "dedup/totals: \(t)")
        let opus = ix.rows(by: .model, days: 1, accounts: [acct], removed: [:]).first { $0.label == "Opus 5.5" }
        assert(abs((opus?.cost ?? 0) - 0.00685) < 1e-9, "cost")
        assert(ix.lastSession?.cwd == "/w/x" && ix.lastSession?.accountID == "t")
        ix.scan(accounts: [acct])
        assert(total().0 == 1133, "rescan must not recount")

        let h = FileHandle(forWritingAtPath: file)!
        h.seekToEndOfFile(); h.write((line("3", "claude-haiku-5-5", 5, 5, 0, 0) + "\n").data(using: .utf8)!); try? h.close()
        ix.scan(accounts: [acct])
        t = total()
        assert(t.0 == 1143 && t.1 == 27, "delta: \(t)")

        let ix2 = UsageIndex(storePath: tmp + "/store/usage.json")   // persisted state reloads
        ix2.scan(accounts: [acct])
        let r2 = ix2.rows(by: .account, days: 1, accounts: [acct], removed: [:])
        assert(r2.first?.tokens == 1143 && r2.first?.label == "T" && r2.first?.accountID == "t", "persist")
        ix2.purge(accountID: "t")
        assert(ix2.rows(by: .account, days: 1, accounts: [acct], removed: [:]).isEmpty)
        print("Usage selfTest OK")
    }
}
