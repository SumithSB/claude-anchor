import Foundation

/// Incremental token/cost index over every account's Claude Code transcripts.
final class UsageIndex: @unchecked Sendable {
    private struct Agg: Codable { var input = 0, output = 0, cacheRead = 0, cacheWrite = 0; var cost = 0.0 }
    private struct FileState: Codable { var offset: UInt64; var size: UInt64; var inode: UInt64 }
    private struct Last: Codable { var cwd: String; var accountID: String; var ts: Double; var file: String?; var editor: Bool? }
    private struct State: Codable {
        var agg: [String: Agg] = [:]       // "day\u{1F}account\u{1F}cwd\u{1F}model"
        var files: [String: FileState] = [:]
        var recent: [String] = []          // last dedup keys, so a rescan after truncation doesn't double count
        var last: Last?
        var pricing: Int?                  // price table the stored costs were computed with
    }
    private struct Rec { var key: String, day: String, cwd: String, model: String, ts: Double, editor: Bool
                         var input: Int, output: Int, cacheRead: Int, cacheWrite: Int, cacheWrite1h: Int }

    private static let pricingVersion = 2

    private static let sep = "\u{1F}"
    private static let maxRecent = 5000
    private static let keepDays = 90

    private let lock = NSLock()
    private let scanGate = NSLock()
    private let storePath: String
    private var state = State()
    private var seen = Set<String>()
    private var dirty = false   // state differs from what's on disk; a rescan with nothing new skips the write

    var lastSession: LastSession? {
        lock.lock(); defer { lock.unlock() }
        return state.last.map { ($0.cwd, $0.accountID, $0.file, $0.editor ?? false) }
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
                dirty = true
            }
            lock.unlock()
        }
    }

    convenience init() { self.init(storePath: Paths.usage) }

    init(storePath: String) {
        self.storePath = storePath
        if let d = FileManager.default.contents(atPath: storePath),
           let s = try? JSONDecoder().decode(State.self, from: d) { state = s; seen = Set(s.recent) }
        if state.pricing != Self.pricingVersion {   // costs from an older price table: re-price the stored tokens
            for (k, a) in state.agg {
                let model = k.components(separatedBy: Self.sep).last ?? ""
                // The split by cache duration wasn't kept; Claude Code writes with the 1-hour TTL.
                state.agg[k]?.cost = Self.cost(model: model, input: a.input, output: a.output, cacheRead: a.cacheRead,
                                               cacheWrite5m: 0, cacheWrite1h: a.cacheWrite)
            }
            state.pricing = Self.pricingVersion
            dirty = true
        }
    }

    // MARK: pricing / labels

    /// First-party API list prices, USD per million tokens: input, output, cache read. Cache writes are
    /// 1.25x input (5-minute TTL) or 2x (1-hour). `prompt` is the request's whole input, for Haiku 5.5's tier.
    // ponytail: hand-kept table (Oct 2026); bump pricingVersion when it changes so stored costs are re-priced.
    static func price(_ model: String, prompt: Int = 0) -> (input: Double, output: Double, read: Double) {
        var m = model.lowercased()
        if let b = m.firstIndex(of: "[") { m = String(m[..<b]) }   // "claude-opus-5-5[1m]"
        func has(_ p: String) -> Bool { m.hasPrefix("claude-" + p) }
        if has("fable-5-1") || has("mythos-5-1") { return (10, 50, 0.25) }
        if has("fable") || has("mythos") { return (10, 50, 1) }
        if has("opus-5-5") { return (4, 20, 0.2) }
        if has("opus-5") || ["4-8", "4-7", "4-6", "4-5"].contains(where: { has("opus-" + $0) }) { return (5, 25, 0.5) }
        if m.contains("opus") { return (15, 75, 1.5) }
        if has("sonnet-5") { return (2, 10, 0.2) }
        if has("haiku-5-5") { return prompt > 100_000 ? (0.5, 2.5, 0.05) : (0.1, 0.5, 0.01) }
        if m.contains("haiku") { return (1, 5, 0.1) }
        return (3, 15, 0.3)   // Sonnet 4.x, and anything unrecognised
    }

    static func cost(model: String, input: Int, output: Int, cacheRead: Int, cacheWrite5m: Int, cacheWrite1h: Int) -> Double {
        let p = price(model, prompt: input + cacheRead + cacheWrite5m + cacheWrite1h)
        return (Double(input) * p.input + Double(output) * p.output + Double(cacheRead) * p.read
                + Double(cacheWrite5m) * p.input * 1.25 + Double(cacheWrite1h) * p.input * 2) / 1e6
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
        let n = state.agg.count
        state.agg = state.agg.filter { $0.key.prefix(while: { $0 != "\u{1F}" }) >= cutoff[...] }
        if state.agg.count != n { dirty = true }
        let write = dirty
        lock.unlock()
        // Scans run every couple of seconds while a session writes; re-encoding the whole index each time was
        // most of the app's idle CPU.
        if write { persist() }
    }

    private func setFile(_ path: String, _ fs: FileState) {
        lock.lock()
        if state.files[path].map({ $0.offset != fs.offset || $0.size != fs.size || $0.inode != fs.inode }) ?? true { dirty = true }
        state.files[path] = fs
        lock.unlock()
    }

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
            dirty = true
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
        let write = n("cache_creation_input_tokens")
        let write1h = ((u["cache_creation"] as? [String: Any])?["ephemeral_1h_input_tokens"] as? NSNumber)?.intValue ?? 0
        let key = model == "<synthetic>" ? "" : "\(msg["id"] as? String ?? "")|\(o["requestId"] as? String ?? "")"
        return Rec(key: key, day: dayFmt.string(from: date), cwd: cwd, model: model, ts: date.timeIntervalSince1970,
                   editor: o["entrypoint"] as? String == "claude-vscode",   // Cursor runs the same extension
                    input: n("input_tokens"), output: n("output_tokens"),
                    cacheRead: n("cache_read_input_tokens"), cacheWrite: write, cacheWrite1h: min(write1h, write))
    }

    private func apply(_ r: Rec, acct: String, file: String) {   // lock held
        if r.ts >= (state.last?.ts ?? 0) { state.last = Last(cwd: r.cwd, accountID: acct, ts: r.ts, file: file, editor: r.editor) }
        if r.key.isEmpty || r.key == "|" || !seen.insert(r.key).inserted { return }
        state.recent.append(r.key)
        if state.recent.count > Self.maxRecent * 2 {
            state.recent.removeFirst(state.recent.count - Self.maxRecent)
            seen = Set(state.recent)
        }
        let cost = Self.cost(model: r.model, input: r.input, output: r.output, cacheRead: r.cacheRead,
                             cacheWrite5m: r.cacheWrite - r.cacheWrite1h, cacheWrite1h: r.cacheWrite1h)
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
        dirty = false   // cleared with the snapshot, so a change made during the write still marks it dirty
        lock.unlock()
        guard let data else { return }
        do {
            try AppModel.ensureDir((storePath as NSString).deletingLastPathComponent)
            try AppModel.writeSecure(data, to: storePath)
            lock.lock(); _persistError = nil; lock.unlock()
        } catch {
            lock.lock(); _persistError = AppModel.reason(error); dirty = true; lock.unlock()
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
        // Opus 5.5: $4 in, $20 out, $0.20 cache read, 5-minute writes at 1.25x input.
        assert(abs((opus?.cost ?? 0) - (10 * 4 + 20 * 20 + 100 * 0.2 + 1000 * 4 * 1.25) / 1e6) < 1e-12, "cost")
        assert(ix.lastSession?.cwd == "/w/x" && ix.lastSession?.accountID == "t" && ix.lastSession?.editor == false)
        let store = tmp + "/store/usage.json"
        let m0 = (try? FileManager.default.attributesOfItem(atPath: store)[.modificationDate]) as? Date
        Thread.sleep(forTimeInterval: 0.05)
        ix.scan(accounts: [acct])
        assert(total().0 == 1133, "rescan must not recount")
        let m1 = (try? FileManager.default.attributesOfItem(atPath: store)[.modificationDate]) as? Date
        assert(m0 != nil && m0 == m1, "a rescan with nothing new must not rewrite the index")

        let h = FileHandle(forWritingAtPath: file)!
        h.seekToEndOfFile(); h.write((line("3", "claude-haiku-5-5", 5, 5, 0, 0) + "\n").data(using: .utf8)!); try? h.close()
        ix.scan(accounts: [acct])
        t = total()
        assert(t.0 == 1143 && t.1 == 27, "delta: \(t)")
        let h2 = FileHandle(forWritingAtPath: file)!
        let vs = line("4", "claude-haiku-5-5", 0, 0, 0, 0).replacingOccurrences(of: #""cwd""#, with: #""entrypoint":"claude-vscode","cwd""#)
        h2.seekToEndOfFile(); h2.write((vs + "\n").data(using: .utf8)!); try? h2.close()
        ix.scan(accounts: [acct])
        assert(ix.lastSession?.editor == true, "a VS Code conversation is marked as one")

        let ix2 = UsageIndex(storePath: tmp + "/store/usage.json")   // persisted state reloads
        ix2.scan(accounts: [acct])
        let r2 = ix2.rows(by: .account, days: 1, accounts: [acct], removed: [:])
        assert(r2.first?.tokens == 1143 && r2.first?.label == "T" && r2.first?.accountID == "t", "persist")
        ix2.purge(accountID: "t")
        assert(ix2.rows(by: .account, days: 1, accounts: [acct], removed: [:]).isEmpty)
        // Pricing: 1-hour writes at 2x, per-model cache reads, Haiku 5.5's long-prompt tier, the [1m] suffix.
        func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-12 }
        assert(near(cost(model: "claude-opus-5-5[1m]", input: 0, output: 0, cacheRead: 1_000_000, cacheWrite5m: 0, cacheWrite1h: 1_000_000), 0.2 + 8))
        assert(near(cost(model: "claude-fable-5-1", input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000, cacheWrite5m: 0, cacheWrite1h: 0), 10 + 50 + 0.25))
        assert(near(cost(model: "claude-fable-5", input: 0, output: 0, cacheRead: 1_000_000, cacheWrite5m: 0, cacheWrite1h: 0), 1))
        assert(near(cost(model: "claude-sonnet-5-5", input: 1_000_000, output: 1_000_000, cacheRead: 0, cacheWrite5m: 0, cacheWrite1h: 0), 12))
        assert(near(cost(model: "claude-sonnet-4-6", input: 1_000_000, output: 0, cacheRead: 0, cacheWrite5m: 0, cacheWrite1h: 0), 3))
        assert(near(cost(model: "claude-opus-4-8", input: 1_000_000, output: 0, cacheRead: 0, cacheWrite5m: 0, cacheWrite1h: 0), 5))
        assert(near(cost(model: "claude-haiku-5-5", input: 100_000, output: 0, cacheRead: 0, cacheWrite5m: 0, cacheWrite1h: 0), 0.01))
        assert(near(cost(model: "claude-haiku-5-5", input: 100_001, output: 0, cacheRead: 0, cacheWrite5m: 0, cacheWrite1h: 0), 100_001 * 0.5 / 1e6))

        // A transcript line with a 1-hour write is priced by its split.
        let h3 = FileHandle(forWritingAtPath: file)!
        let oneH = line("5", "claude-sonnet-5-5", 0, 0, 0, 1000)
            .replacingOccurrences(of: #""output_tokens":0}"#, with: #""output_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":400,"ephemeral_1h_input_tokens":600}}"#)
        h3.seekToEndOfFile(); h3.write((oneH + "\n").data(using: .utf8)!); try? h3.close()
        ix.scan(accounts: [acct])
        let son = ix.rows(by: .model, days: 1, accounts: [acct], removed: [:]).first { $0.label == "Sonnet 5.5" }
        assert(near(son?.cost ?? 0, (400 * 2 * 1.25 + 600 * 2 * 2) / 1e6), "1h split: \(son?.cost ?? -1)")

        // Costs stored under an older table are re-priced on load (writes taken as 1-hour, Claude Code's TTL).
        let old = tmp + "/old.json"
        try? #"{"agg":{"2026-10-01\u001ft\u001f/w\u001fclaude-opus-5-5":{"input":0,"output":1000000,"cacheRead":1000000,"cacheWrite":1000000,"cost":999}},"files":{},"recent":[]}"#
            .write(toFile: old, atomically: true, encoding: .utf8)
        let rep = UsageIndex(storePath: old).rows(by: .model, days: 400, accounts: [acct], removed: [:])
        assert(rep.count == 1 && near(rep[0].cost, 20 + 0.2 + 8), "re-priced: \(rep)")
        print("Usage selfTest OK")
    }
}
