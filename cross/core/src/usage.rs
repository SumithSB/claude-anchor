//! Incremental token/cost index over every account's transcripts. Port of Usage.swift `UsageIndex`.

use crate::model::Account;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GroupBy { Account, Project, Model }

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct UsageRow {
    pub id: String,                 // group key (account id / cwd / model)
    pub label: String,              // account name, "~/code/website", "Opus 5.5"
    #[serde(rename = "accountID")]
    pub account_id: Option<String>, // set when grouping by account
    pub tokens: u64,                // input + output + cache read + cache write
    #[serde(rename = "outputTokens")]
    pub output_tokens: u64,
    pub cost: f64,                  // estimated USD
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct LastSession {
    pub cwd: String,
    #[serde(rename = "accountID")]
    pub account_id: String,
    pub file: Option<String>,
}

const SEP: char = '\u{1F}';
const MAX_RECENT: usize = 5000;
const KEEP_DAYS: i64 = 90;

#[derive(Default, Serialize, Deserialize)]
struct Agg { input: u64, output: u64, cache_read: u64, cache_write: u64, cost: f64 }

#[derive(Clone, Serialize, Deserialize)]
struct FileState { offset: u64, size: u64, inode: u64 }

#[derive(Serialize, Deserialize)]
struct Last { cwd: String, account_id: String, ts: f64, file: Option<String> }

#[derive(Default, Serialize, Deserialize)]
struct State {
    agg: HashMap<String, Agg>, // "day\u{1F}account\u{1F}cwd\u{1F}model"
    files: HashMap<String, FileState>,
    recent: Vec<String>, // last dedup keys, so a rescan after truncation doesn't double count
    last: Option<Last>,
}

#[derive(Default)]
struct Inner { state: State, seen: HashSet<String> }

struct Rec { key: String, day: String, cwd: String, model: String, ts: f64, input: u64, output: u64, cache_read: u64, cache_write: u64 }

pub struct UsageIndex { store: PathBuf, ledger: PathBuf, inner: Mutex<Inner>, gate: Mutex<()> }

/// Same-file check across rotation: inode on Unix, creation time (ns) elsewhere, 0 if unknown.
fn file_id(m: &std::fs::Metadata) -> u64 {
    #[cfg(unix)]
    { use std::os::unix::fs::MetadataExt; m.ino() }
    #[cfg(not(unix))]
    { m.created().ok().and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok()).map_or(0, |d| d.as_nanos() as u64) }
}

fn day_of(d: chrono::DateTime<chrono::Local>) -> String { d.format("%Y-%m-%d").to_string() }

fn jsonl_in(dir: &Path, out: &mut Vec<PathBuf>) {
    for e in std::fs::read_dir(dir).into_iter().flatten().flatten() {
        let p = e.path();
        if e.file_type().is_ok_and(|t| t.is_dir()) { jsonl_in(&p, out) }
        else if p.extension().is_some_and(|x| x == "jsonl") { out.push(p) }
    }
}

/// Assistant lines with usage; synthetic ones get an empty key (they only feed last_session).
fn parse(line: &[u8]) -> Option<Rec> {
    if line.len() <= 2 || !line.windows(7).any(|w| w == b"\"usage\"") { return None }
    let o: serde_json::Value = serde_json::from_slice(line).ok()?;
    if o["type"].as_str()? != "assistant" { return None }
    let cwd = o["cwd"].as_str()?;
    let date = chrono::DateTime::parse_from_rfc3339(o["timestamp"].as_str()?).ok()?;
    let msg = o["message"].as_object()?;
    let u = msg.get("usage")?.as_object()?;
    let model = msg.get("model").and_then(|m| m.as_str()).unwrap_or("unknown");
    let n = |k: &str| u.get(k).and_then(|v| v.as_u64()).unwrap_or(0);
    let key = if model == "<synthetic>" { String::new() } else {
        format!("{}|{}", msg.get("id").and_then(|v| v.as_str()).unwrap_or(""), o["requestId"].as_str().unwrap_or(""))
    };
    Some(Rec {
        key, day: day_of(date.with_timezone(&chrono::Local)), cwd: cwd.into(), model: model.into(),
        ts: date.timestamp_millis() as f64 / 1000.0,
        input: n("input_tokens"), output: n("output_tokens"),
        cache_read: n("cache_read_input_tokens"), cache_write: n("cache_creation_input_tokens"),
    })
}

impl Inner {
    fn apply(&mut self, r: &Rec, acct: &str, file: &str) {
        if r.ts >= self.state.last.as_ref().map_or(0.0, |l| l.ts) {
            self.state.last = Some(Last { cwd: r.cwd.clone(), account_id: acct.into(), ts: r.ts, file: Some(file.into()) });
        }
        if r.key.is_empty() || r.key == "|" || !self.seen.insert(r.key.clone()) { return }
        self.state.recent.push(r.key.clone());
        if self.state.recent.len() > MAX_RECENT * 2 {
            let drop = self.state.recent.len() - MAX_RECENT;
            self.state.recent.drain(..drop);
            self.seen = self.state.recent.iter().cloned().collect();
        }
        let (pi, po) = UsageIndex::price(&r.model);
        let cost = (r.input as f64 * pi + r.output as f64 * po + r.cache_read as f64 * pi * 0.1 + r.cache_write as f64 * pi * 1.25) / 1e6;
        let a = self.state.agg.entry([r.day.as_str(), acct, &r.cwd, &r.model].join(&SEP.to_string())).or_default();
        a.input += r.input; a.output += r.output; a.cache_read += r.cache_read; a.cache_write += r.cache_write; a.cost += cost;
    }
}

impl UsageIndex {
    /// Loads state from `store` (usage.json); `ledger` is the `copied` file written by sync.
    pub fn open(store: PathBuf, ledger: PathBuf) -> Self {
        let state: State = std::fs::read(&store).ok().and_then(|d| serde_json::from_slice(&d).ok()).unwrap_or_default();
        let seen = state.recent.iter().cloned().collect();
        UsageIndex { store, ledger, inner: Mutex::new(Inner { state, seen }), gate: Mutex::new(()) }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Inner> { self.inner.lock().unwrap_or_else(|e| e.into_inner()) }

    /// Reads new lines of every `<dir>/projects/**/*.jsonl`, persists. Err = user-facing persist error.
    pub fn scan(&self, accounts: &[Account]) -> Result<(), String> {
        let _gate = self.gate.lock().unwrap_or_else(|e| e.into_inner());
        self.apply_ledger();
        for acct in accounts {
            let mut files = vec![];
            jsonl_in(&Path::new(&acct.dir).join("projects"), &mut files);
            for path in files {
                let Ok(m) = std::fs::metadata(&path) else { continue };
                let (size, inode) = (m.len(), file_id(&m));
                let key = path.to_string_lossy().into_owned();
                let cur = self.lock().state.files.get(&key).cloned();
                let mut fs = cur.unwrap_or(FileState { offset: 0, size: 0, inode });
                if fs.inode != inode || size < fs.offset { fs.offset = 0 } // rotated or truncated
                if size == fs.offset {
                    fs.size = size;
                    fs.inode = inode;
                    self.lock().state.files.insert(key, fs);
                    continue;
                }
                self.read_new(&path, &key, &acct.id, fs.offset, size, inode);
            }
        }
        let cutoff = day_of(chrono::Local::now() - chrono::Duration::days(KEEP_DAYS));
        self.lock().state.agg.retain(|k, _| k.split(SEP).next().unwrap_or("") >= cutoff.as_str());
        self.persist()
    }

    /// Reads [from, size) in chunks, processing only complete lines; offset advances per chunk.
    fn read_new(&self, path: &Path, key: &str, acct: &str, from: u64, size: u64, inode: u64) {
        let Ok(mut f) = std::fs::File::open(path) else { return };
        if f.seek(SeekFrom::Start(from)).is_err() { return }
        let (mut offset, mut carry, mut buf) = (from, Vec::<u8>::new(), vec![0u8; 1 << 20]);
        while offset + (carry.len() as u64) < size {
            let k = f.read(&mut buf).unwrap_or(0);
            if k == 0 { break }
            carry.extend_from_slice(&buf[..k]);
            let Some(nl) = carry.iter().rposition(|&b| b == b'\n') else { continue }; // no complete line yet
            let recs: Vec<Rec> = carry[..nl].split(|&b| b == b'\n').filter_map(parse).collect();
            offset += (nl + 1) as u64;
            carry.drain(..=nl);
            let mut g = self.lock();
            for r in &recs { g.apply(r, acct, key) }
            g.state.files.insert(key.into(), FileState { offset, size, inode });
        }
    }

    /// Conversations the shell hook copied between accounts (`<path>\t<copied size>` per line): start those
    /// files at the copied size, so shared history isn't counted again for the account it was copied to.
    fn apply_ledger(&self) {
        let mut name = self.ledger.file_name().unwrap_or_default().to_os_string();
        name.push(".processing");
        let work = self.ledger.with_file_name(name);
        if !work.exists() && std::fs::rename(&self.ledger, &work).is_err() { return }
        if let Ok(text) = std::fs::read_to_string(&work) {
            for line in text.split('\n') {
                let Some((p, sz)) = line.split_once('\t') else { continue };
                let (Ok(size), Ok(m)) = (sz.trim().parse::<u64>(), std::fs::metadata(p)) else { continue };
                let inode = file_id(&m);
                let mut g = self.lock();
                let stale = g.state.files.get(p).is_none_or(|c| c.inode != inode || c.offset < size);
                if stale { g.state.files.insert(p.into(), FileState { offset: size, size, inode }); }
            }
        }
        let _ = std::fs::remove_file(&work);
    }

    fn persist(&self) -> Result<(), String> {
        let Ok(data) = serde_json::to_vec(&self.lock().state) else { return Ok(()) };
        let dir = self.store.parent().unwrap_or(Path::new("."));
        crate::fsx::ensure_dir(dir).and_then(|_| crate::fsx::write_secure(&self.store, &data, 0o600))
            .map_err(|e| crate::fsx::reason(&e))
    }

    pub fn rows(&self, by: GroupBy, days: u32, accounts: &[Account], removed: &BTreeMap<String, String>, home: &Path) -> Vec<UsageRow> {
        let cutoff = day_of(chrono::Local::now() - chrono::Duration::days(days.max(1) as i64 - 1));
        let mut groups: HashMap<String, (u64, u64, f64)> = HashMap::new();
        for (k, a) in &self.lock().state.agg {
            let p: Vec<&str> = k.split(SEP).collect();
            if p.len() != 4 || p[0] < cutoff.as_str() { continue }
            let id = match by { GroupBy::Account => p[1], GroupBy::Project => p[2], GroupBy::Model => p[3] };
            let g = groups.entry(id.into()).or_default();
            g.0 += a.input + a.output + a.cache_read + a.cache_write;
            g.1 += a.output;
            g.2 += a.cost;
        }
        let label = |id: &str| match by {
            GroupBy::Account => accounts.iter().find(|a| a.id == id).map(|a| a.name.clone())
                .or_else(|| removed.get(id).map(|n| format!("{n} (removed)"))).unwrap_or_else(|| id.into()),
            GroupBy::Project => crate::paths::abbreviate(Path::new(id), home),
            GroupBy::Model => Self::pretty_model(id),
        };
        let mut v: Vec<_> = groups.into_iter().collect();
        v.sort_by(|a, b| b.1 .0.cmp(&a.1 .0).then_with(|| a.0.cmp(&b.0)));
        v.into_iter().map(|(id, g)| UsageRow {
            label: label(&id), account_id: (by == GroupBy::Account).then(|| id.clone()),
            id, tokens: g.0, output_tokens: g.1, cost: g.2,
        }).collect()
    }

    pub fn last_session(&self) -> Option<LastSession> {
        self.lock().state.last.as_ref().map(|l| LastSession { cwd: l.cwd.clone(), account_id: l.account_id.clone(), file: l.file.clone() })
    }

    /// Marks a copied transcript as already read, so its history never counts again.
    pub fn mark_copied(&self, path: &Path) {
        let Ok(m) = std::fs::metadata(path) else { return };
        let size = m.len();
        self.lock().state.files.insert(path.to_string_lossy().into_owned(), FileState { offset: size, size, inode: file_id(&m) });
    }

    // ponytail: estimate table (USD per million tokens), update when pricing changes.
    pub fn price(model: &str) -> (f64, f64) {
        let m = model.to_lowercase();
        if m.contains("opus") { return if m.contains("opus-4-5") || m.contains("opus-5") { (5.0, 25.0) } else { (15.0, 75.0) } }
        if m.contains("fable") { return (5.0, 25.0) }
        if m.contains("haiku") { return (1.0, 5.0) }
        (3.0, 15.0)
    }

    pub fn pretty_model(id: &str) -> String {
        let Some(rest) = id.strip_prefix("claude-") else { return id.into() };
        let mut parts: Vec<&str> = rest.split('-').filter(|p| !p.is_empty()).collect();
        if parts.last().is_some_and(|l| l.len() == 8 && l.chars().all(|c| c.is_numeric())) { parts.pop(); }
        let Some((fam, ver)) = parts.split_first() else { return id.into() };
        if !fam.chars().all(|c| c.is_alphabetic()) || !ver.iter().all(|v| v.chars().all(|c| c.is_numeric())) { return id.into() }
        let mut c = fam.chars();
        let name: String = c.next().map(|f| f.to_uppercase().chain(c.flat_map(|x| x.to_lowercase())).collect()).unwrap_or_default();
        if ver.is_empty() { name } else { format!("{name} {}", ver.join(".")) }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn line(ts: &str, id: &str, model: &str, i: u64, o: u64, cr: u64, cw: u64) -> String {
        format!(r#"{{"type":"assistant","cwd":"/w/x","timestamp":"{ts}","requestId":"r{id}","message":{{"id":"m{id}","model":"{model}","usage":{{"input_tokens":{i},"cache_creation_input_tokens":{cw},"cache_read_input_tokens":{cr},"output_tokens":{o}}}}}}}"#)
    }
    fn acct(id: &str, dir: &Path) -> Account {
        Account { id: id.into(), name: id.to_uppercase(), flag: "a".into(), dir: dir.display().to_string(), email: None, plan: None, pending: false }
    }
    fn totals(ix: &UsageIndex, by: GroupBy, a: &[Account]) -> Vec<UsageRow> { ix.rows(by, 1, a, &BTreeMap::new(), Path::new("/h")) }

    #[test]
    fn names_and_prices() {
        assert_eq!(UsageIndex::pretty_model("claude-opus-4-5-20251101"), "Opus 4.5");
        assert_eq!(UsageIndex::pretty_model("claude-sonnet-4-5-20250929"), "Sonnet 4.5");
        assert_eq!(UsageIndex::pretty_model("claude-haiku-5-5"), "Haiku 5.5");
        assert_eq!(UsageIndex::pretty_model("gpt-4"), "gpt-4");
        assert_eq!(UsageIndex::price("claude-opus-4-1"), (15.0, 75.0));
        assert_eq!(UsageIndex::price("claude-opus-4-5-2025"), (5.0, 25.0));
        assert_eq!(UsageIndex::price("claude-haiku-4-5"), (1.0, 5.0));
        assert_eq!(UsageIndex::price("claude-sonnet-4"), (3.0, 15.0));
    }

    #[test]
    fn scan_dedups_increments_and_ledger() {
        let tmp = tempfile::tempdir().unwrap();
        let ts = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true);
        let (da, db) = (tmp.path().join("a"), tmp.path().join("b"));
        let file = da.join("projects/p/s.jsonl");
        std::fs::create_dir_all(file.parent().unwrap()).unwrap();
        let a = line(&ts, "1", "claude-opus-5-5", 10, 20, 100, 1000);
        let text = [a.clone(), a, r#"{"type":"user","message":{"content":"usage"}}"#.into(),
            line(&ts, "9", "<synthetic>", 5, 5, 0, 0), r#"{"type":"assistant", "usage" broken"#.into(),
            line(&ts, "2", "claude-sonnet-4-5-20250929", 1, 2, 0, 0)].join("\n") + "\n";
        std::fs::write(&file, text).unwrap();
        let accts = [acct("a", &da), acct("b", &db)];
        let ix = UsageIndex::open(tmp.path().join("store/usage.json"), tmp.path().join("store/copied"));
        ix.scan(&accts).unwrap();
        let by_model = totals(&ix, GroupBy::Model, &accts);
        assert_eq!(by_model.iter().map(|r| r.tokens).sum::<u64>(), 1133);
        assert_eq!(by_model.iter().map(|r| r.output_tokens).sum::<u64>(), 22);
        let opus = by_model.iter().find(|r| r.label == "Opus 5.5").unwrap();
        assert!((opus.cost - 0.00685).abs() < 1e-9);
        let ls = ix.last_session().unwrap();
        assert_eq!((ls.cwd.as_str(), ls.account_id.as_str()), ("/w/x", "a"));
        ix.scan(&accts).unwrap();
        assert_eq!(totals(&ix, GroupBy::Account, &accts)[0].tokens, 1133, "rescan must not recount");

        let mut f = std::fs::OpenOptions::new().append(true).open(&file).unwrap();
        writeln!(f, "{}", line(&ts, "3", "claude-haiku-5-5", 5, 5, 0, 0)).unwrap();
        write!(f, "{}", line(&ts, "4", "claude-haiku-5-5", 7, 7, 0, 0)).unwrap(); // partial: no newline yet
        drop(f);
        ix.scan(&accts).unwrap();
        let acc = totals(&ix, GroupBy::Account, &accts);
        assert_eq!((acc[0].tokens, acc[0].output_tokens), (1143, 27));
        assert_eq!((acc[0].label.as_str(), acc[0].account_id.as_deref()), ("A", Some("a")));

        // a copy into account b, logged in the ledger, is not b's usage
        let copy = db.join("projects/p/s.jsonl");
        std::fs::create_dir_all(copy.parent().unwrap()).unwrap();
        std::fs::copy(&file, &copy).unwrap();
        let size = std::fs::metadata(&copy).unwrap().len();
        std::fs::write(tmp.path().join("store/copied"), format!("{}\t{}\n", copy.display(), size)).unwrap();
        ix.scan(&accts).unwrap();
        assert!(!tmp.path().join("store/copied").exists() && !tmp.path().join("store/copied.processing").exists());
        assert_eq!(totals(&ix, GroupBy::Account, &accts).len(), 1, "copy not counted for b");

        // mark_copied does the same without the ledger
        let copy2 = db.join("projects/p/t.jsonl");
        std::fs::copy(&file, &copy2).unwrap();
        ix.mark_copied(&copy2);
        ix.scan(&accts).unwrap();
        assert_eq!(totals(&ix, GroupBy::Account, &accts).len(), 1);

        // persisted state reloads; project labels abbreviate; removed accounts keep a label
        let ix2 = UsageIndex::open(tmp.path().join("store/usage.json"), tmp.path().join("store/copied"));
        ix2.scan(&accts).unwrap();
        assert_eq!(totals(&ix2, GroupBy::Account, &accts)[0].tokens, 1143);
        let r = ix2.rows(GroupBy::Project, 1, &accts, &BTreeMap::new(), Path::new("/w"));
        assert_eq!(r[0].label, format!("~{}x", std::path::MAIN_SEPARATOR));
        let rm = BTreeMap::from([("a".to_string(), "Old".to_string())]);
        assert_eq!(ix2.rows(GroupBy::Account, 1, &[], &rm, Path::new("/h"))[0].label, "Old (removed)");
    }
}
