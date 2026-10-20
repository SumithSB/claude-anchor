//! Installs the `anchor` binary, the editor wrapper and the shell hook line (bash/zsh rc, PowerShell profile).

use crate::paths::Paths;
use std::path::{Path, PathBuf};

pub const MARK: &str = "# claude-anchor";
const SH_LINE: &str = r#"[ -x "$HOME/.claude-anchor/bin/anchor" ] && claude() { "$HOME/.claude-anchor/bin/anchor" exec -- claude "$@"; }  # claude-anchor"#;
const PS_LINE: &str = r#"if (Test-Path "$HOME\.claude-anchor\bin\anchor.exe") { function claude { & "$HOME\.claude-anchor\bin\anchor.exe" exec -- claude @args } }  # claude-anchor"#;

const FISH_LINE: &str = r#"if test -x "$HOME/.claude-anchor/bin/anchor"; function claude; "$HOME/.claude-anchor/bin/anchor" exec -- claude $argv; end; end  # claude-anchor"#;
/// cmd.exe: a doskey macro in the AutoRun registry value; our segment is matched exactly for removal.
const CMD_SEG: &str = r#"doskey claude="%USERPROFILE%\.claude-anchor\bin\anchor.exe" exec -- claude $* 2>nul"#;
#[cfg(windows)]
const AUTORUN_KEY: &str = r"HKCU\Software\Microsoft\Command Processor";

type Files = Vec<(PathBuf, &'static str, bool)>; // (file, line to add, create when missing)

/// Copies `src` to `dst` unless identical. A running exe can't be overwritten on Windows: move it to `.old` first.
fn place(src: &Path, dst: &Path) -> std::io::Result<()> {
    let new = std::fs::read(src)?;
    if std::fs::read(dst).is_ok_and(|d| d == new) { return Ok(()); }
    let mut old = dst.as_os_str().to_owned();
    old.push(".old");
    let old = PathBuf::from(old);
    let _ = std::fs::remove_file(&old);
    if std::fs::write(dst, &new).is_err() {
        std::fs::rename(dst, &old)?;
        std::fs::write(dst, &new)?;
    }
    let _ = std::fs::remove_file(&old);
    #[cfg(unix)]
    { use std::os::unix::fs::PermissionsExt; std::fs::set_permissions(dst, std::fs::Permissions::from_mode(0o755))?; }
    Ok(())
}

/// Copies the `anchor` binary at `src` (the CLI itself, or the tray's sidecar) to `<anchor>/bin/anchor[.exe]`
/// and `<anchor>/bin/claude-wrapper[.exe]`, only when content differs.
pub fn install_binaries(paths: &Paths, src: &std::path::Path) -> Result<(), String> {
    let ext = if cfg!(windows) { ".exe" } else { "" };
    let bin = paths.bin();
    crate::fsx::ensure_dir(&bin).map_err(|e| format!("Couldn't create {}: {}.", bin.display(), crate::fsx::reason(&e)))?;
    for name in ["anchor", "claude-wrapper"] {
        let dst = bin.join(format!("{name}{ext}"));
        place(src, &dst).map_err(|e| format!("Couldn't install {}: {}.", dst.display(), crate::fsx::reason(&e)))?;
    }
    Ok(())
}

/// AutoRun value with our segment appended (` & `-joined), never clobbering what's there.
pub fn merge_autorun(existing: Option<&str>) -> String {
    match existing.map(str::trim).filter(|e| !e.is_empty()) {
        Some(e) if e.contains(CMD_SEG) => e.to_string(),
        Some(e) => format!("{e} & {CMD_SEG}"),
        None => CMD_SEG.to_string(),
    }
}

/// AutoRun value without our segment (and its joining ` & `); None when it wasn't there. Empty string = delete the value.
pub fn strip_autorun(existing: &str) -> Option<String> {
    if !existing.contains(CMD_SEG) { return None; }
    let s = existing.replace(&format!(" & {CMD_SEG}"), "").replace(&format!("{CMD_SEG} & "), "").replace(CMD_SEG, "");
    Some(s.trim().to_string())
}

#[cfg(windows)]
fn reg(args: &[&str]) -> Option<String> {
    use std::os::windows::process::CommandExt;
    let o = std::process::Command::new("reg").args(args).creation_flags(0x0800_0000).output().ok()?;
    o.status.success().then(|| String::from_utf8_lossy(&o.stdout).into_owned())
}

/// Current AutoRun as (registry type, value).
#[cfg(windows)]
fn autorun_get() -> Option<(String, String)> {
    let out = reg(&["query", AUTORUN_KEY, "/v", "AutoRun"])?;
    let rest = out.lines().find_map(|l| l.trim_start().strip_prefix("AutoRun"))?.trim_start();
    let (ty, val) = rest.split_once(char::is_whitespace)?;
    Some((ty.to_string(), val.trim().to_string()))
}

/// Applies `f` to the AutoRun value; Some(new) writes it (empty deletes). Returns whether it changed.
#[cfg(windows)]
fn autorun_edit(f: impl Fn(Option<&str>) -> Option<String>) -> Result<bool, String> {
    let cur = autorun_get();
    let Some(new) = f(cur.as_ref().map(|c| c.1.as_str())) else { return Ok(false) };
    let ty = cur.as_ref().map_or("REG_SZ", |c| c.0.as_str());
    let ok = if new.is_empty() { reg(&["delete", AUTORUN_KEY, "/v", "AutoRun", "/f"]) }
        else { reg(&["add", AUTORUN_KEY, "/v", "AutoRun", "/t", ty, "/d", &new, "/f"]) };
    ok.map(|_| true).ok_or_else(|| "Couldn't update the cmd.exe AutoRun registry value.".to_string())
}

fn hook_files(home: &Path, docs: Option<&Path>, windows: bool, xdg: Option<&Path>) -> Files {
    if windows {
        let d = docs.unwrap_or(home);
        return ["PowerShell", "WindowsPowerShell"].iter()
            .map(|p| (d.join(p).join("Microsoft.PowerShell_profile.ps1"), PS_LINE, true)).collect();
    }
    let (bash, zsh) = (home.join(".bashrc"), home.join(".zshrc"));
    let none = !bash.exists() && !zsh.exists();
    let fish = xdg.map_or_else(|| home.join(".config"), Path::to_path_buf).join("fish");
    let has_fish = fish.is_dir();
    vec![(bash, SH_LINE, none), (zsh, SH_LINE, false), (fish.join("conf.d/claude-anchor.fish"), FISH_LINE, has_fish)]
}

fn files(paths: &Paths) -> Files {
    let xdg = std::env::var_os("XDG_CONFIG_HOME").filter(|v| !v.is_empty()).map(PathBuf::from);
    hook_files(&paths.home, dirs::document_dir().as_deref(), cfg!(windows), xdg.as_deref())
}

fn add(files: Files) -> Result<Vec<PathBuf>, String> {
    let mut changed = vec![];
    for (f, line, create) in files {
        let text = match std::fs::read_to_string(&f) {
            Ok(t) => t,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound && create => String::new(),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => continue,
            Err(e) => return Err(format!("Couldn't read {}: {}.", f.display(), crate::fsx::reason(&e))),
        };
        if text.lines().any(|l| l.contains(MARK)) { continue; }
        let nl = if text.contains("\r\n") { "\r\n" } else { "\n" };
        let sep = if text.is_empty() || text.ends_with('\n') { "" } else { nl };
        let out = format!("{text}{sep}{line}{nl}");
        let write = || -> std::io::Result<()> {
            if let Some(d) = f.parent() { std::fs::create_dir_all(d)?; }
            std::fs::write(&f, out)
        };
        write().map_err(|e| format!("Couldn't update {}: {}.", f.display(), crate::fsx::reason(&e)))?;
        changed.push(f);
    }
    Ok(changed)
}

fn remove(files: Files) -> Result<Vec<PathBuf>, String> {
    let mut changed = vec![];
    for (f, _, _) in files {
        let Ok(text) = std::fs::read_to_string(&f) else { continue };
        let out: String = text.split_inclusive('\n').filter(|l| !l.contains(MARK)).collect();
        if out == text { continue; }
        let w = if out.trim().is_empty() && f.extension().is_some_and(|e| e == "fish") { std::fs::remove_file(&f) } else { std::fs::write(&f, out) };
        w.map_err(|e| format!("Couldn't update {}: {}.", f.display(), crate::fsx::reason(&e)))?;
        changed.push(f);
    }
    Ok(changed)
}

/// Adds the hook line to every rc/profile file; returns the files changed.
pub fn install_hook(paths: &Paths) -> Result<Vec<PathBuf>, String> {
    if cfg!(target_os = "macos") { return Err("On macOS the Claude Anchor app installs its own shell hook.".into()); }
    #[allow(unused_mut)]
    let mut changed = add(files(paths))?;
    #[cfg(windows)]
    if autorun_edit(|c| { let m = merge_autorun(c); (Some(m.as_str()) != c).then_some(m) })? {
        changed.push(PathBuf::from(format!(r"{AUTORUN_KEY}\AutoRun")));
    }
    Ok(changed)
}

/// Removes hook lines; returns the files changed.
pub fn uninstall_hook(paths: &Paths) -> Result<Vec<PathBuf>, String> {
    if cfg!(target_os = "macos") { return Ok(vec![]); } // the Swift app owns ~/.zshrc there
    #[allow(unused_mut)]
    let mut changed = remove(files(paths))?;
    #[cfg(windows)]
    if autorun_edit(|c| c.and_then(strip_autorun))? { changed.push(PathBuf::from(format!(r"{AUTORUN_KEY}\AutoRun"))); }
    Ok(changed)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn add_is_idempotent_and_remove_keeps_the_rest() {
        let t = tempfile::tempdir().unwrap();
        let zsh = t.path().join(".zshrc");
        std::fs::write(&zsh, "alias a=b\r\nexport X=1").unwrap();
        let go = || hook_files(t.path(), None, false, None);
        assert_eq!(add(go()).unwrap(), vec![zsh.clone()]);
        let once = std::fs::read_to_string(&zsh).unwrap();
        assert_eq!(once, format!("alias a=b\r\nexport X=1\r\n{SH_LINE}\r\n"));
        assert!(add(go()).unwrap().is_empty());
        assert_eq!(std::fs::read_to_string(&zsh).unwrap(), once);
        assert!(!t.path().join(".bashrc").exists(), "bashrc only created when neither rc exists");
        assert_eq!(remove(go()).unwrap(), vec![zsh.clone()]);
        assert_eq!(std::fs::read_to_string(&zsh).unwrap(), "alias a=b\r\nexport X=1\r\n");
        assert!(remove(go()).unwrap().is_empty());
    }

    #[test]
    fn creates_bashrc_or_powershell_profiles() {
        let t = tempfile::tempdir().unwrap();
        assert_eq!(add(hook_files(t.path(), None, false, None)).unwrap(), vec![t.path().join(".bashrc")]);
        let d = tempfile::tempdir().unwrap();
        let got = add(hook_files(t.path(), Some(d.path()), true, None)).unwrap();
        assert_eq!(got.len(), 2);
        assert!(std::fs::read_to_string(&got[0]).unwrap().contains("anchor.exe"));
    }

    #[test]
    fn fish_hook_only_when_fish_dir_exists_and_file_is_deleted_on_remove() {
        let t = tempfile::tempdir().unwrap();
        let f = t.path().join(".config/fish/conf.d/claude-anchor.fish");
        assert!(!add(hook_files(t.path(), None, false, None)).unwrap().contains(&f));
        std::fs::create_dir_all(t.path().join(".config/fish")).unwrap();
        assert!(add(hook_files(t.path(), None, false, None)).unwrap().contains(&f));
        assert_eq!(std::fs::read_to_string(&f).unwrap(), format!("{FISH_LINE}\n"));
        assert!(remove(hook_files(t.path(), None, false, None)).unwrap().contains(&f));
        assert!(!f.exists());
        let x = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(x.path().join("fish")).unwrap();
        assert!(add(hook_files(t.path(), None, false, Some(x.path()))).unwrap().contains(&x.path().join("fish/conf.d/claude-anchor.fish")));
    }

    #[test]
    fn autorun_merge_and_strip() {
        assert_eq!(merge_autorun(None), CMD_SEG);
        let m = merge_autorun(Some("echo hi"));
        assert_eq!(m, format!("echo hi & {CMD_SEG}"));
        assert_eq!(merge_autorun(Some(&m)), m);
        assert_eq!(strip_autorun(&m).as_deref(), Some("echo hi"));
        assert_eq!(strip_autorun(CMD_SEG).as_deref(), Some(""));
        assert_eq!(strip_autorun(&format!("{CMD_SEG} & echo hi")).as_deref(), Some("echo hi"));
        assert_eq!(strip_autorun("echo hi"), None);
    }

    #[test]
    fn binaries_copy_once_and_replace_changes() {
        let t = tempfile::tempdir().unwrap();
        let paths = Paths::from_home(t.path());
        let src = t.path().join("src");
        std::fs::write(&src, b"v1").unwrap();
        install_binaries(&paths, &src).unwrap();
        std::fs::write(&src, b"v2").unwrap();
        install_binaries(&paths, &src).unwrap();
        let ext = if cfg!(windows) { ".exe" } else { "" };
        assert_eq!(std::fs::read(paths.bin().join(format!("claude-wrapper{ext}"))).unwrap(), b"v2");
    }
}
