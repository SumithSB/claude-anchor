//! Installs the `anchor` binary, the editor wrapper and the shell hook line (bash/zsh rc, PowerShell profile).

use crate::paths::Paths;
use std::path::{Path, PathBuf};

pub const MARK: &str = "# claude-anchor";
const SH_LINE: &str = r#"[ -x "$HOME/.claude-anchor/bin/anchor" ] && claude() { "$HOME/.claude-anchor/bin/anchor" exec -- claude "$@"; }  # claude-anchor"#;
const PS_LINE: &str = r#"if (Test-Path "$HOME\.claude-anchor\bin\anchor.exe") { function claude { & "$HOME\.claude-anchor\bin\anchor.exe" exec -- claude @args } }  # claude-anchor"#;

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

fn hook_files(home: &Path, docs: Option<&Path>, windows: bool) -> Files {
    if windows {
        let d = docs.unwrap_or(home);
        return ["PowerShell", "WindowsPowerShell"].iter()
            .map(|p| (d.join(p).join("Microsoft.PowerShell_profile.ps1"), PS_LINE, true)).collect();
    }
    let (bash, zsh) = (home.join(".bashrc"), home.join(".zshrc"));
    let none = !bash.exists() && !zsh.exists();
    vec![(bash, SH_LINE, none), (zsh, SH_LINE, false)]
}

fn files(paths: &Paths) -> Files {
    hook_files(&paths.home, dirs::document_dir().as_deref(), cfg!(windows))
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
        std::fs::write(&f, out).map_err(|e| format!("Couldn't update {}: {}.", f.display(), crate::fsx::reason(&e)))?;
        changed.push(f);
    }
    Ok(changed)
}

/// Adds the hook line to every rc/profile file; returns the files changed.
pub fn install_hook(paths: &Paths) -> Result<Vec<PathBuf>, String> {
    if cfg!(target_os = "macos") { return Err("On macOS the Claude Anchor app installs its own shell hook.".into()); }
    add(files(paths))
}

/// Removes hook lines; returns the files changed.
pub fn uninstall_hook(paths: &Paths) -> Result<Vec<PathBuf>, String> {
    if cfg!(target_os = "macos") { return Ok(vec![]); } // the Swift app owns ~/.zshrc there
    remove(files(paths))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn add_is_idempotent_and_remove_keeps_the_rest() {
        let t = tempfile::tempdir().unwrap();
        let zsh = t.path().join(".zshrc");
        std::fs::write(&zsh, "alias a=b\r\nexport X=1").unwrap();
        let go = || hook_files(t.path(), None, false);
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
        assert_eq!(add(hook_files(t.path(), None, false)).unwrap(), vec![t.path().join(".bashrc")]);
        let d = tempfile::tempdir().unwrap();
        let got = add(hook_files(t.path(), Some(d.path()), true)).unwrap();
        assert_eq!(got.len(), 2);
        assert!(std::fs::read_to_string(&got[0]).unwrap().contains("anchor.exe"));
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
