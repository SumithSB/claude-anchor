import Foundation
import CryptoKit
import UserNotifications

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
                } else { unreachable = true }       // offline, DNS, timeout
            } else {
                expired = true
            }
        }
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

    func refreshLimits() async {
        let list = accounts.filter { !$0.pending }.map { ($0, limits[$0.id]) }
        let results = await withTaskGroup(of: (String, Limits).self) { g -> [String: Limits] in
            for (a, prev) in list { g.addTask { (a.id, await Self.fetchLimits(a, previous: prev)) } }
            var r: [String: Limits] = [:]
            for await (id, l) in g { r[id] = l }
            return r
        }
        for (id, l) in results { limits[id] = l }
        evaluateOverflow()
    }

    func evaluateOverflow() {
        defer { writeRoutes() }
        func peak(_ l: Limits) -> Double { max(l.fiveHour?.percent ?? 0, l.weekly?.percent ?? 0) }
        let thr = config.overflowThreshold
        guard config.autoOverflow, let cur = active, let cl = limits[cur.id], peak(cl) >= thr else { return }
        if let t = AnchorRuntime.lastMove, Date().timeIntervalSince(t) < 600 { return }
        let best = accounts
            .filter { !$0.pending && $0.id != cur.id }
            .compactMap { a -> (Account, Double)? in
                guard let l = limits[a.id], l.error == nil, peak(l) < thr else { return nil }
                return (a, peak(l))
            }
            .min { $0.1 < $1.1 }
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
