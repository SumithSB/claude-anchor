//! Sharing conversations between accounts. Port of anchor.zsh `_anchor_sync` and Store.swift `copyTranscript`.

use std::collections::BTreeMap;
use std::fs;
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};

/// Before claude starts in `cwd`: for each transcript of this project in any of `dirs`, copy the largest
/// copy over smaller ones that are an exact prefix of it (diverged copies left alone). Logs to `ledger`.
pub fn sync_project(cwd: &Path, dirs: &[PathBuf], ledger: &Path) {
    sync_slug(&crate::routes::project_slug(&cwd.to_string_lossy()), dirs, ledger)
}

fn sync_slug(slug: &str, dirs: &[PathBuf], ledger: &Path) {
    if dirs.len() < 2 { return; }
    let mut best: BTreeMap<String, (PathBuf, u64)> = BTreeMap::new();
    for d in dirs {
        let Ok(rd) = fs::read_dir(d.join("projects").join(slug)) else { continue };
        for e in rd.flatten() {
            let name = e.file_name().to_string_lossy().into_owned();
            let Ok(m) = e.metadata() else { continue };
            if !name.ends_with(".jsonl") || !m.is_file() { continue }
            if best.get(&name).is_none_or(|b| m.len() > b.1) { best.insert(name, (e.path(), m.len())); }
        }
    }
    for (name, (src, size)) in &best {
        for d in dirs {
            let t = d.join("projects").join(slug).join(name);
            if t == *src { continue }
            if let Ok(m) = fs::metadata(&t) {
                if m.len() >= *size || !is_prefix(&t, src, m.len()) { continue } // diverged: leave both alone
            }
            if let Some(p) = t.parent() { if fs::create_dir_all(p).is_err() { continue } }
            log(ledger, &t, *size);
            if fs::copy(src, &t).is_err() { continue }
            if let Ok(mt) = fs::metadata(src).and_then(|m| m.modified()) {
                let _ = fs::File::options().write(true).open(&t).and_then(|f| f.set_modified(mt));
            }
            let (side, tside) = (src.with_extension(""), t.with_extension(""));
            if side.is_dir() { // subagent transcripts live beside the session
                let _ = fs::remove_dir_all(&tside);
                let _ = copy_all(&side, &tside);
                for f in jsonl_in(&tside) { if let Ok(m) = fs::metadata(&f) { log(ledger, &f, m.len()) } }
            }
        }
    }
}

/// Appends `<path>\t<size>` to the ledger; best effort.
fn log(ledger: &Path, path: &Path, size: u64) {
    if let Ok(mut f) = fs::OpenOptions::new().create(true).append(true).open(ledger) {
        let _ = writeln!(f, "{}\t{}", path.display(), size);
    }
}

/// Do the first `n` bytes of `src` equal all of `t`?
fn is_prefix(t: &Path, src: &Path, n: u64) -> bool {
    let (Ok(a), Ok(b)) = (fs::File::open(t), fs::File::open(src)) else { return false };
    let (mut a, mut b) = (io::BufReader::new(a), io::BufReader::new(b.take(n)));
    let (mut x, mut y) = ([0u8; 65536], [0u8; 65536]);
    loop {
        let Ok(k) = a.read(&mut x) else { return false };
        if k == 0 { return b.read(&mut y).is_ok_and(|j| j == 0) }
        if b.read_exact(&mut y[..k]).is_err() || x[..k] != y[..k] { return false }
    }
}

/// Recursive copy of a folder.
fn copy_all(from: &Path, to: &Path) -> io::Result<()> {
    fs::create_dir_all(to)?;
    for e in fs::read_dir(from)? {
        let e = e?;
        let dst = to.join(e.file_name());
        if e.file_type()?.is_dir() { copy_all(&e.path(), &dst)? } else { fs::copy(e.path(), &dst)?; }
    }
    Ok(())
}

/// Every .jsonl under `dir`, recursively, in a stable order.
fn jsonl_in(dir: &Path) -> Vec<PathBuf> {
    let mut out = vec![];
    for e in fs::read_dir(dir).into_iter().flatten().flatten() {
        let p = e.path();
        if e.file_type().is_ok_and(|t| t.is_dir()) { out.extend(jsonl_in(&p)) }
        else if p.extension().is_some_and(|x| x == "jsonl") { out.push(p) }
    }
    out.sort();
    out
}

/// Account config dirs: primary + every folder in `<anchor>/accounts`.
pub fn account_dirs(paths: &crate::paths::Paths) -> Vec<PathBuf> {
    let mut v: Vec<PathBuf> = fs::read_dir(paths.accounts()).into_iter().flatten().flatten()
        .map(|e| e.path()).filter(|p| p.is_dir()).collect();
    v.sort();
    if paths.primary_dir.is_dir() { v.insert(0, paths.primary_dir.clone()) }
    v
}

/// Copies a transcript and its sibling session folder into `target_dir/projects/<same slug>/`.
/// Returns every copied .jsonl path.
pub fn copy_transcript(file: &Path, target_dir: &Path) -> io::Result<Vec<PathBuf>> {
    let bad = || io::Error::new(io::ErrorKind::InvalidInput, "not a transcript path");
    let sid = file.file_stem().ok_or_else(bad)?;
    let slug = file.parent().and_then(|p| p.file_name()).ok_or_else(bad)?;
    let dst_dir = target_dir.join("projects").join(slug);
    fs::create_dir_all(&dst_dir)?;
    let dst = dst_dir.join(file.file_name().ok_or_else(bad)?);
    remove_any(&dst)?;
    fs::copy(file, &dst)?;
    let mut copied = vec![dst];
    let side = file.with_extension("");
    if side.is_dir() {
        let dside = dst_dir.join(sid);
        remove_any(&dside)?;
        copy_all(&side, &dside)?;
        copied.extend(jsonl_in(&dside));
    }
    Ok(copied)
}

fn remove_any(p: &Path) -> io::Result<()> {
    match fs::symlink_metadata(p) {
        Ok(m) if m.is_dir() => fs::remove_dir_all(p),
        Ok(_) => fs::remove_file(p),
        Err(_) => Ok(()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn put(p: &Path, s: &str) { fs::create_dir_all(p.parent().unwrap()).unwrap(); fs::write(p, s).unwrap(); }

    #[test]
    fn prefix_extends_diverged_stays() {
        let tmp = tempfile::tempdir().unwrap();
        let (a, b, led) = (tmp.path().join("a"), tmp.path().join("b"), tmp.path().join("copied"));
        let rel = |d: &Path, n: &str| d.join("projects").join("s").join(n);
        put(&rel(&a, "x.jsonl"), "one\ntwo\n");
        put(&rel(&b, "x.jsonl"), "one\n");          // prefix: extended
        put(&rel(&a, "y.jsonl"), "aaa\nbbb\n");
        put(&rel(&b, "y.jsonl"), "zzz\n");          // diverged: left alone
        put(&rel(&b, "z.jsonl"), "new\n");          // missing in a: created
        sync_slug("s", &[a.clone(), b.clone()], &led);
        assert_eq!(fs::read_to_string(rel(&b, "x.jsonl")).unwrap(), "one\ntwo\n");
        assert_eq!(fs::read_to_string(rel(&b, "y.jsonl")).unwrap(), "zzz\n");
        assert_eq!(fs::read_to_string(rel(&a, "y.jsonl")).unwrap(), "aaa\nbbb\n");
        assert_eq!(fs::read_to_string(rel(&a, "z.jsonl")).unwrap(), "new\n");
        let l = fs::read_to_string(&led).unwrap();
        assert!(l.contains(&format!("{}\t8\n", rel(&b, "x.jsonl").display())));
        assert!(l.contains(&format!("{}\t4\n", rel(&a, "z.jsonl").display())));
        assert_eq!(l.lines().count(), 2);
    }

    #[test]
    fn sibling_folder_synced_and_logged() {
        let tmp = tempfile::tempdir().unwrap();
        let (a, b, led) = (tmp.path().join("a"), tmp.path().join("b"), tmp.path().join("copied"));
        put(&a.join("projects").join("s").join("x.jsonl"), "main\n");
        let sub = |d: &Path| d.join("projects").join("s").join("x").join("subagents").join("agent-1.jsonl");
        put(&sub(&a), "sub\n");
        fs::create_dir_all(b.join("projects")).unwrap();
        sync_slug("s", &[a, b.clone()], &led);
        assert_eq!(fs::read_to_string(sub(&b)).unwrap(), "sub\n");
        let l = fs::read_to_string(&led).unwrap();
        assert!(l.contains(&format!("{}\t4\n", sub(&b).display())));
    }

    #[test]
    fn copy_transcript_replaces_and_lists() {
        let tmp = tempfile::tempdir().unwrap();
        let (src, dst) = (tmp.path().join("a"), tmp.path().join("b"));
        put(&src.join("projects/s/id.jsonl"), "new\n");
        put(&src.join("projects/s/id/sub/x.jsonl"), "x\n");
        put(&dst.join("projects/s/id.jsonl"), "old old old\n");
        put(&dst.join("projects/s/id/stale.jsonl"), "stale\n");
        let got = copy_transcript(&src.join("projects/s/id.jsonl"), &dst).unwrap();
        assert_eq!(got, vec![dst.join("projects/s/id.jsonl"), dst.join("projects/s/id/sub/x.jsonl")]);
        assert_eq!(fs::read_to_string(&got[0]).unwrap(), "new\n");
        assert!(!dst.join("projects/s/id/stale.jsonl").exists());
    }

    #[test]
    fn dirs_primary_first() {
        let tmp = tempfile::tempdir().unwrap();
        let p = crate::paths::Paths::from_home(tmp.path());
        assert!(account_dirs(&p).is_empty());
        fs::create_dir_all(&p.primary_dir).unwrap();
        fs::create_dir_all(p.accounts().join("b")).unwrap();
        fs::create_dir_all(p.accounts().join("a")).unwrap();
        assert_eq!(account_dirs(&p), vec![p.primary_dir.clone(), p.accounts().join("a"), p.accounts().join("b")]);
    }
}
