//! Live rate limits from api.anthropic.com/api/oauth/usage with the CLI's own token (never refreshed).
//! Port of Limits.swift `fetchLimits`, `parseLimits`, fresh/overflow evaluation.

use crate::model::{Account, Config, LimitWindow, Limits};
use crate::paths::Paths;
use crate::creds;
use serde_json::Value;
use std::collections::HashMap;
use std::time::Duration;

pub const OFFLINE_NOTE: &str = "Couldn't reach Anthropic. Showing the last known usage.";

/// CLAUDE_ANCHOR_USAGE_URL overrides the endpoint. Tests only (point it at an unreachable port).
fn usage_url() -> String {
    std::env::var("CLAUDE_ANCHOR_USAGE_URL").ok().filter(|u| !u.is_empty()).unwrap_or_else(|| "https://api.anthropic.com/api/oauth/usage".into())
}

pub fn parse_limits(v: &Value, fetched_at: i64, stale: bool) -> Limits {
    let win = |k: &str| {
        let w = v.get(k)?;
        Some(LimitWindow { percent: w.get("utilization")?.as_f64()?, resets_at: w.get("resets_at").and_then(Value::as_str).map(String::from) })
    };
    Limits { five_hour: win("five_hour"), weekly: win("seven_day"), fetched_at, stale, error: None, needs_sign_in: false, note: None }
}

fn failed(now: i64, error: String, needs_sign_in: bool) -> Limits {
    Limits { five_hour: None, weekly: None, fetched_at: now, stale: true, error: Some(error), needs_sign_in, note: None }
}

/// Blocking fetch for one account (20 s timeout). Falls back to `previous` or cachedUsageUtilization.
pub fn fetch(a: &Account, paths: &Paths, previous: Option<&Limits>) -> Limits {
    let now = chrono::Utc::now().timestamp();
    let (mut expired, mut unreachable) = (false, false);
    let oauth = creds::oauth(a, paths);
    if let Some(token) = oauth.as_ref().and_then(|o| o["accessToken"].as_str()) {
        let exp = oauth.as_ref().and_then(|o| o["expiresAt"].as_f64()).unwrap_or(0.0);
        if exp / 1000.0 > now as f64 {
            let agent = ureq::AgentBuilder::new().timeout(Duration::from_secs(20)).build();
            let res = agent.get(&usage_url()).set("Authorization", &format!("Bearer {token}"))
                .set("anthropic-beta", "oauth-2025-04-20").set("User-Agent", "claude-anchor").call();
            match res {
                Ok(r) if r.status() == 200 => match r.into_json::<Value>() {
                    Ok(o) if o.is_object() => {
                        let l = parse_limits(&o, now, false);
                        if l.five_hour.is_some() || l.weekly.is_some() { return l; }
                        unreachable = true; // 200 but not the shape we know
                    }
                    _ => unreachable = true,
                },
                Err(ureq::Error::Status(401, _)) => expired = true,
                _ => unreachable = true, // 5xx, 429, offline, DNS, timeout
            }
        } else {
            expired = true;
        }
    }
    if unreachable {
        if let Some(p) = previous.filter(|p| p.error.is_none() && (p.five_hour.is_some() || p.weekly.is_some())) {
            return Limits { stale: true, note: Some(OFFLINE_NOTE.into()), ..p.clone() };
        }
    }
    let cj = creds::claude_json(a, paths);
    if let Some(u) = cj["cachedUsageUtilization"]["utilization"].as_object() {
        let at = (cj["cachedUsageUtilization"]["fetchedAtMs"].as_f64().unwrap_or(0.0) / 1000.0) as i64;
        let mut l = parse_limits(&Value::Object(u.clone()), at, true);
        if now - at > 6 * 3600 { l.error = Some(format!("{}'s limits are out of date.", a.name)); }
        else if unreachable { l.note = Some(OFFLINE_NOTE.into()); }
        return l;
    }
    if unreachable {
        return failed(now, "Couldn't reach Anthropic. Check your connection; Anchor will try again shortly.".into(), false);
    }
    if expired { failed(now, format!("{}'s sign-in expired. Sign in again.", a.name), true) }
    else { failed(now, format!("Couldn't read {}'s limits.", a.name), false) }
}

/// Fetches every non-pending account in parallel.
pub fn fetch_all(cfg: &Config, paths: &Paths, previous: &HashMap<String, Limits>) -> HashMap<String, Limits> {
    std::thread::scope(|s| {
        let hs: Vec<_> = cfg.accounts.iter().filter(|a| !a.pending)
            .map(|a| (a.id.clone(), s.spawn(move || fetch(a, paths, previous.get(&a.id))))).collect();
        hs.into_iter().filter_map(|(id, h)| h.join().ok().map(|l| (id, l))).collect()
    })
}

/// Accounts that just became fresh (not fresh in `before`, fresh in `after`), for notifications.
/// Like Swift, an account with no earlier reading never counts. Sorted by id.
pub fn newly_fresh(before: &HashMap<String, Limits>, after: &HashMap<String, Limits>) -> Vec<String> {
    let mut v: Vec<String> = after.iter()
        .filter(|(id, l)| l.is_fresh() && before.get(*id).is_some_and(|b| !b.is_fresh())).map(|(id, _)| id.clone()).collect();
    v.sort();
    v
}

/// Port of Limits.swift `evaluateOverflow` decision: when auto-overflow is on and the default account is at or
/// over the threshold, the account to switch to (fresh first, then lowest peak, errors and pending skipped).
/// The caller owns the 10 minute "last move" throttle, setting the default, and the banner/notification
/// ("Switched to X. Y hit N% of its 5h|weekly limit."). `last_account` is the last conversation's account;
/// the caller offers "continue there" only when it equals the default being left.
pub fn overflow_suggestion(cfg: &Config, limits: &HashMap<String, Limits>, _last_account: Option<&str>) -> Option<String> {
    let cur = cfg.active()?;
    let thr = cfg.overflow_threshold;
    if !cfg.auto_overflow || limits.get(&cur.id)?.peak() < thr { return None; }
    cfg.accounts.iter().filter(|a| !a.pending && a.id != cur.id)
        .filter_map(|a| limits.get(&a.id).filter(|l| l.error.is_none() && l.peak() < thr).map(|l| (a, l)))
        .min_by(|(_, x), (_, y)| (!x.is_fresh()).cmp(&!y.is_fresh()).then(x.peak().total_cmp(&y.peak())))
        .map(|(a, _)| a.id.clone())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn acct(id: &str, dir: &str) -> Account {
        Account { id: id.into(), name: id.into(), flag: "a".into(), dir: dir.into(), email: None, plan: None, pending: false }
    }
    fn lim(five: f64, weekly: f64) -> Limits {
        Limits { five_hour: Some(LimitWindow { percent: five, resets_at: None }), weekly: Some(LimitWindow { percent: weekly, resets_at: None }),
                 fetched_at: 0, stale: false, error: None, needs_sign_in: false, note: None }
    }

    #[test]
    fn parses_fixture() {
        let v: Value = serde_json::from_str(r#"{"five_hour":{"utilization":42.5,"resets_at":"2026-01-01T10:00:00.123456+00:00"},
            "seven_day":{"utilization":7,"resets_at":null},"seven_day_opus":null}"#).unwrap();
        let l = parse_limits(&v, 5, false);
        assert_eq!(l.five_hour.unwrap(), LimitWindow { percent: 42.5, resets_at: Some("2026-01-01T10:00:00.123456+00:00".into()) });
        assert_eq!(l.weekly.unwrap().percent, 7.0);
        assert_eq!(l.fetched_at, 5);
        assert!(parse_limits(&serde_json::json!({"five_hour":{}}), 0, false).five_hour.is_none());
    }

    // These set CLAUDE_ANCHOR_USAGE_URL (process-wide), so they run in one test to avoid racing.
    #[test]
    fn fetch_paths_without_network() {
        std::env::set_var("CLAUDE_ANCHOR_USAGE_URL", "http://127.0.0.1:9");
        let t = tempfile::tempdir().unwrap();
        let p = Paths::from_home(t.path());
        let d = t.path().join("w");
        std::fs::create_dir_all(&d).unwrap();
        let a = acct("work", d.to_str().unwrap());

        // No credentials, no cache.
        let l = fetch(&a, &p, None);
        assert_eq!(l.error.as_deref(), Some("Couldn't read work's limits.")); assert!(!l.needs_sign_in);

        // Expired token: no network call (the URL is unreachable, which would say "Couldn't reach").
        std::fs::write(d.join(".credentials.json"), r#"{"claudeAiOauth":{"accessToken":"t","expiresAt":1000}}"#).unwrap();
        let l = fetch(&a, &p, None);
        assert_eq!(l.error.as_deref(), Some("work's sign-in expired. Sign in again.")); assert!(l.needs_sign_in);

        // Fresh cache beats the error; old cache is "out of date".
        let now_ms = chrono::Utc::now().timestamp_millis();
        let cache = |ms: i64| format!(r#"{{"cachedUsageUtilization":{{"fetchedAtMs":{ms},"utilization":{{"five_hour":{{"utilization":30}}}}}}}}"#);
        std::fs::write(d.join(".claude.json"), cache(now_ms - 60_000)).unwrap();
        let l = fetch(&a, &p, None);
        assert!(l.error.is_none() && l.stale && l.note.is_none() && l.five_hour.unwrap().percent == 30.0);
        std::fs::write(d.join(".claude.json"), cache(now_ms - 7 * 3600 * 1000)).unwrap();
        assert_eq!(fetch(&a, &p, None).error.as_deref(), Some("work's limits are out of date."));
        std::fs::remove_file(d.join(".claude.json")).unwrap();

        // Valid token, unreachable server: previous is returned stale with the note; else a connection error.
        let exp = now_ms + 3_600_000;
        std::fs::write(d.join(".credentials.json"), format!(r#"{{"claudeAiOauth":{{"accessToken":"t","expiresAt":{exp}}}}}"#)).unwrap();
        let prev = lim(50.0, 10.0);
        let l = fetch(&a, &p, Some(&prev));
        assert!(l.stale && l.note.as_deref() == Some(OFFLINE_NOTE) && l.five_hour.as_ref().unwrap().percent == 50.0);
        let l = fetch(&a, &p, None);
        assert!(l.error.as_deref().unwrap().starts_with("Couldn't reach Anthropic. Check your connection"));
        std::fs::write(d.join(".claude.json"), cache(now_ms - 60_000)).unwrap();
        assert_eq!(fetch(&a, &p, None).note.as_deref(), Some(OFFLINE_NOTE));

        // fetch_all skips pending accounts.
        let mut cfg = Config::default();
        let mut pend = acct("new", "/nope"); pend.pending = true;
        cfg.accounts = vec![a, pend];
        let all = fetch_all(&cfg, &p, &HashMap::new());
        assert_eq!(all.len(), 1); assert!(all.contains_key("work"));
    }

    #[test]
    fn newly_fresh_needs_a_used_reading_before() {
        let m = |v: &[(&str, Limits)]| v.iter().map(|(k, l)| (k.to_string(), l.clone())).collect::<HashMap<_, _>>();
        let before = m(&[("a", lim(80.0, 5.0)), ("b", lim(0.0, 0.0)), ("c", lim(60.0, 0.0))]);
        let after = m(&[("a", lim(0.0, 5.0)), ("b", lim(0.0, 0.0)), ("c", lim(61.0, 0.0)), ("d", lim(0.0, 0.0))]);
        assert_eq!(newly_fresh(&before, &after), vec!["a"]);
        let mut stale = lim(0.0, 0.0); stale.stale = true;
        assert!(newly_fresh(&before, &m(&[("c", stale)])).is_empty());
    }

    #[test]
    fn overflow_picks_fresh_then_lowest() {
        let mut cfg = Config::default();
        cfg.accounts = ["a", "b", "c", "d"].iter().map(|i| acct(i, "/x")).collect();
        cfg.default_id = "a".into();
        let hot = lim(95.0, 10.0);
        let mut err = lim(0.0, 0.0); err.error = Some("x".into());
        let m = |v: Vec<(&str, Limits)>| v.into_iter().map(|(k, l)| (k.to_string(), l)).collect::<HashMap<_, _>>();
        let ls = m(vec![("a", hot.clone()), ("b", lim(40.0, 10.0)), ("c", lim(20.0, 30.0)), ("d", err.clone())]);
        assert_eq!(overflow_suggestion(&cfg, &ls, None).as_deref(), Some("c"));
        let ls = m(vec![("a", hot.clone()), ("b", lim(40.0, 10.0)), ("c", lim(20.0, 30.0)), ("d", lim(0.0, 3.0))]);
        assert_eq!(overflow_suggestion(&cfg, &ls, None).as_deref(), Some("d"));
        assert_eq!(overflow_suggestion(&cfg, &m(vec![("a", lim(10.0, 10.0)), ("b", lim(0.0, 0.0))]), None), None);
        assert_eq!(overflow_suggestion(&cfg, &m(vec![("a", hot.clone()), ("b", lim(99.0, 0.0))]), None), None);
        cfg.auto_overflow = false;
        assert_eq!(overflow_suggestion(&cfg, &m(vec![("a", hot), ("b", lim(0.0, 0.0))]), None), None);
    }
}
