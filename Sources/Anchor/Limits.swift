import Foundation
import CryptoKit
import UserNotifications
import os

private let log = Logger(subsystem: "dev.claude-anchor", category: "limits")

extension AppModel {
    /// Keychain service Claude Code uses for this config dir.
    nonisolated static func keychainService(for account: Account) -> String {
        guard let d = account.configDirEnv else { return "Claude Code-credentials" }
        let h = SHA256.hash(data: Data(d.precomposedStringWithCanonicalMapping.utf8))
        return "Claude Code-credentials-" + String(h.map { String(format: "%02x", $0) }.joined().prefix(8))
    }

    nonisolated static func parseDate(_ s: String) -> Date? {
        var s = s
        if let dot = s.firstIndex(of: ".") {   // drop fraction; 6-digit micros break the formatter
            let end = s[dot...].firstIndex { "+-Z".contains($0) } ?? s.endIndex
            s.removeSubrange(dot..<end)
        }
        return ISO8601DateFormatter().date(from: s)
    }

    nonisolated static func parseLimits(_ d: [String: Any], fetchedAt: Date, stale: Bool) -> Limits {
        func win(_ k: String) -> LimitWindow? {
            guard let w = d[k] as? [String: Any], let u = (w["utilization"] as? NSNumber)?.doubleValue else { return nil }
            return LimitWindow(percent: u, resetsAt: (w["resets_at"] as? String).flatMap(parseDate))
        }
        return Limits(fiveHour: win("five_hour"), weekly: win("seven_day"), fetchedAt: fetchedAt, stale: stale)
    }

    /// One missed check (a 429 because Claude Code polls the same endpoint, or a network blip) isn't worth a
    /// warning: the last live numbers stand as they are until they're 10 minutes old.
    nonisolated static func keptQuietly(_ p: Limits?, now: Date) -> Limits? {
        guard let p, p.error == nil, !p.stale, p.fiveHour != nil || p.weekly != nil,
              now.timeIntervalSince(p.fetchedAt) < 600 else { return nil }
        return p
    }

    nonisolated static let offlineNote = "Couldn't reach Anthropic. Showing the last known usage."

    /// Live fetch with the CLI's own access token. Never refreshes it (that would rotate the refresh token).
    /// When Anthropic can't be reached, `previous` (or the CLI's cache) is returned marked stale with a note.
    nonisolated static func fetchLimits(_ a: Account, previous: Limits? = nil) async -> Limits {
        let now = Date()
        var expired = false, unreachable = false
        let oauth = keychainJSON(service: keychainService(for: a))?["claudeAiOauth"] as? [String: Any]
        if let token = oauth?["accessToken"] as? String, let url = URL(string: "https://api.anthropic.com/api/oauth/usage") {
            let exp = (oauth?["expiresAt"] as? NSNumber)?.doubleValue ?? 0
            if exp / 1000 > now.timeIntervalSince1970 {
                var req = URLRequest(url: url)
                req.timeoutInterval = 20
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
                req.setValue("claude-anchor", forHTTPHeaderField: "User-Agent")
                if let (data, resp) = try? await URLSession.shared.data(for: req), let h = resp as? HTTPURLResponse {
                    if h.statusCode == 401 { expired = true }
                    else if h.statusCode == 200, let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        let l = parseLimits(o, fetchedAt: now, stale: false)
                        if l.fiveHour != nil || l.weekly != nil { return l }
                        unreachable = true     // 200 but not the shape we know
                    } else { unreachable = true }   // 5xx, 429, or not JSON
                    if unreachable { log.notice("usage check for \(a.id, privacy: .public): HTTP \(h.statusCode, privacy: .public)") }
                } else {
                    unreachable = true              // offline, DNS, timeout
                    log.notice("usage check for \(a.id, privacy: .public): no response")
                }
            } else {
                expired = true
            }
        }
        if unreachable, let p = keptQuietly(previous, now: now) { return p }
        if unreachable, let p = previous, p.error == nil, p.fiveHour != nil || p.weekly != nil {
            var l = p
            l.stale = true; l.note = offlineNote
            return l
        }
        if let c = claudeJSON(for: a)["cachedUsageUtilization"] as? [String: Any],
           let u = c["utilization"] as? [String: Any] {
            let at = Date(timeIntervalSince1970: ((c["fetchedAtMs"] as? NSNumber)?.doubleValue ?? 0) / 1000)
            var l = parseLimits(u, fetchedAt: at, stale: true)
            if now.timeIntervalSince(at) > 6 * 3600 { l.error = "\(a.name)'s limits are out of date." }
            else if unreachable { l.note = offlineNote }
            return l
        }
        if unreachable {
            return Limits(fiveHour: nil, weekly: nil, fetchedAt: now, stale: true,
                          error: "Couldn't reach Anthropic. Check your connection; Anchor will try again shortly.")
        }
        return Limits(fiveHour: nil, weekly: nil, fetchedAt: now, stale: true,
                      error: expired ? "\(a.name)'s sign-in expired. Sign in again." : "Couldn't read \(a.name)'s limits.",
                      needsSignIn: expired)
    }

    nonisolated static func selfTest() {
        let now = Date()
        let live = Limits(fiveHour: LimitWindow(percent: 40, resetsAt: nil), weekly: nil, fetchedAt: now.addingTimeInterval(-300))
        assert(keptQuietly(live, now: now)?.stale == false, "recent live numbers are kept as is")
        assert(keptQuietly(live, now: now.addingTimeInterval(400)) == nil, "10 minutes old: say so")
        var cached = live; cached.stale = true
        assert(keptQuietly(cached, now: now) == nil, "cached numbers are never passed off as live")
        var failed = live; failed.error = "x"
        assert(keptQuietly(failed, now: now) == nil && keptQuietly(nil, now: now) == nil)
        let empty = Limits(fiveHour: nil, weekly: nil, fetchedAt: now)
        assert(keptQuietly(empty, now: now) == nil)
        var c = Config()
        c.defaultID = "d"
        c.rules = [Rule(path: "/w", accountID: "a"), Rule(path: "/w/x", accountID: "b", allowOverflow: true)]
        assert(routedAccount(cwd: "/elsewhere", config: c, limits: [:]) == "d")
        assert(routedAccount(cwd: "/w/y", config: c, limits: [:]) == "a", "rule wins over the default")
        assert(routedAccount(cwd: "/wx", config: c, limits: [:]) == "d", "prefix match is per folder")
        assert(routedAccount(cwd: "/w/x/z", config: c, limits: [:]) == "b", "longest rule wins")
        let hot = ["b": Limits(fiveHour: LimitWindow(percent: 95, resetsAt: nil), weekly: nil, fetchedAt: now)]
        assert(routedAccount(cwd: "/w/x", config: c, limits: hot) == "d", "overflow rule follows the default when hot")
        print("Limits selfTest OK")
    }

    func refreshLimits() async {
        let list = accounts.filter { !$0.pending }.map { ($0, limits[$0.id]) }
        let before = limits
        let started = Date()
        let results = await withTaskGroup(of: (String, Limits).self) { g -> [String: Limits] in
            for (a, prev) in list { g.addTask { (a.id, await Self.fetchLimits(a, previous: prev)) } }
            var r: [String: Limits] = [:]
            for await (id, l) in g { r[id] = l }
            return r
        }
        AnchorRuntime.limitsAttempted = true
        for (id, l) in results { limits[id] = l }
        // A kept-over result still has its old fetchedAt; only a real fetch counts as "updated".
        if results.values.contains(where: { $0.error == nil && $0.fetchedAt >= started }) { lastRefreshed = Date() }
        evaluateFresh(before: before)
        evaluateOverflow()
    }

    /// Manual refresh: limits and usage rows. Fire-and-forget; ignored while one is running.
    func refreshNow() {
        guard live, !isRefreshing else { return }   // snapshot models must never read real usage or call the API
        isRefreshing = true
        rescan()
        Task {
            await refreshLimits()
            isRefreshing = false
        }
    }

    /// Called when the popover opens.
    func refreshIfStale() {
        guard !isRefreshing else { return }
        if let t = lastRefreshed, Date().timeIntervalSince(t) <= 30 { return }
        refreshNow()
    }

    var lastRefreshedText: String {
        if isRefreshing { return "Updating…" }
        guard let t = lastRefreshed else { return "Not updated yet" }
        let s = max(0, Int(Date().timeIntervalSince(t)))
        if s < 60 { return "Updated just now" }
        if s < 3600 { return "Updated \(s / 60) min ago" }
        return "Updated \(s / 3600) h ago"
    }

    /// True when the numbers on screen are old enough to distrust.
    var isOutdated: Bool {
        guard let t = lastRefreshed else { return AnchorRuntime.limitsAttempted }
        return Date().timeIntervalSince(t) > Double(max(600, 3 * config.refreshSeconds))
    }

    // MARK: fresh (full 5h window available)

    func isFresh(_ id: String) -> Bool { limits[id]?.isFresh == true }

    /// Signed-in accounts other than the default whose 5h window is unused, in config order.
    var freshAccounts: [Account] {
        accounts.filter { !$0.pending && $0.id != config.defaultID && limits[$0.id]?.isFresh == true }
    }

    /// The default account itself has a full, unused 5h window (it just reset).
    var activeIsFresh: Bool { active.map { isFresh($0.id) } ?? false }

    /// Short time until the 5h window resets ("22m", "1h 39m"), only once it is at least 75% used.
    func resetCountdown(_ id: String) -> String? {
        guard let w = limits[id]?.fiveHour, w.percent >= 75, let at = w.resetsAt else { return nil }
        let secs = at.timeIntervalSinceNow
        guard secs > 0 else { return nil }
        let mins = (Int(secs) + 59) / 60
        let h = mins / 60, m = mins % 60
        if h == 0 { return "\(m)m" }
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    /// Notifies once when an account goes from used to fresh between refreshes.
    func evaluateFresh(before: [String: Limits]) {
        for a in accounts where !a.pending {
            guard let l = limits[a.id] else { continue }
            if l.isFresh {
                let wasFresh = before[a.id]?.isFresh == true || freshNotified.contains(a.id)
                let seenBefore = before[a.id] != nil
                freshNotified.insert(a.id)
                guard !wasFresh, seenBefore, config.notifyFresh,
                      Bundle.main.bundleIdentifier != nil else { continue }
                let c = UNMutableNotificationContent()
                c.title = "Claude Anchor"
                c.body = a.id == config.defaultID ? "\(a.name)'s 5-hour window reset. You're on a full window."
                                                  : "\(a.name)'s 5-hour window reset. Full window available."
                UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
            } else if l.error == nil, !l.stale {
                freshNotified.remove(a.id)   // a failed fetch must not re-arm the notice
            }
        }
        freshNotified = freshNotified.filter { id in accounts.contains { $0.id == id } }
    }

    nonisolated static func peakUsage(_ l: Limits?) -> Double {
        max(l?.fiveHour?.percent ?? 0, l?.weekly?.percent ?? 0)
    }

    /// Accounts the last conversation could move to: fresh first, then least used, errors last.
    var continueTargets: [Account] {
        let from = lastSession?.accountID ?? config.defaultID
        return accounts.filter { !$0.pending && $0.id != from }.sorted { a, b in
            let la = limits[a.id], lb = limits[b.id]
            let ea = la?.error != nil, eb = lb?.error != nil
            if ea != eb { return !ea }
            let fa = la?.isFresh == true, fb = lb?.isFresh == true
            if fa != fb { return fa }
            return Self.peakUsage(la) < Self.peakUsage(lb)
        }
    }

    func evaluateOverflow() {
        defer { writeRoutes() }
        func peak(_ l: Limits) -> Double { max(l.fiveHour?.percent ?? 0, l.weekly?.percent ?? 0) }
        let thr = config.overflowThreshold
        guard config.autoOverflow, let cur = active, let cl = limits[cur.id], peak(cl) >= thr else { return }
        if let t = AnchorRuntime.lastMove, Date().timeIntervalSince(t) < 600 { return }
        let best = accounts
            .filter { !$0.pending && $0.id != cur.id }
            .compactMap { a -> (Account, Double, Bool)? in
                guard let l = limits[a.id], l.error == nil, peak(l) < thr else { return nil }
                return (a, peak(l), l.isFresh)
            }
            .min { x, y in x.2 != y.2 ? x.2 : x.1 < y.1 }   // fresh first, then lowest peak
        guard let new = best?.0 else { return }
        let five = (cl.fiveHour?.percent ?? 0) >= (cl.weekly?.percent ?? 0)
        let text = "Switched to \(new.name). \(cur.name) hit \(Int(peak(cl)))% of its \(five ? "5h" : "weekly") limit."
        AnchorRuntime.lastMove = Date()
        config.defaultID = new.id
        save()
        if lastSession?.accountID == cur.id { overflowSuggestion = new.id }
        banner = text
        if Bundle.main.bundleIdentifier != nil {
            let c = UNMutableNotificationContent()
            c.title = "Claude Anchor"
            c.body = text
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
        }
    }
}
