//! VS Code / Cursor integration: sets `claudeCode.claudeProcessWrapper` in user settings.json,
//! editing as text so comments survive. Port of Store.swift `setWrapper` / `setEditorIntegration`.

use crate::fsx;
use crate::paths::{abbreviate, Paths};
use regex::Regex;
use std::path::PathBuf;

pub const WRAPPER_KEY: &str = "claudeCode.claudeProcessWrapper";

const APPS: [&str; 4] = ["Code", "Cursor", "Code - Insiders", "VSCodium"];

/// User settings.json candidates for Code, Cursor, Code - Insiders, VSCodium on this OS (existing or not).
pub fn settings_files(paths: &Paths) -> Vec<PathBuf> {
    let base = if cfg!(target_os = "macos") {
        paths.home.join("Library/Application Support")
    } else if cfg!(windows) {
        dirs::config_dir().unwrap_or_else(|| paths.home.join("AppData/Roaming"))
    } else {
        match std::env::var_os("XDG_CONFIG_HOME").filter(|v| !v.is_empty()) {
            Some(x) => PathBuf::from(x),
            None => paths.home.join(".config"),
        }
    };
    APPS.iter().map(|app| base.join(app).join("User").join("settings.json")).collect()
}

/// `<anchor>/bin/claude-wrapper` (`.exe` on Windows).
pub fn wrapper_path(paths: &Paths) -> PathBuf {
    paths.bin().join(if cfg!(windows) { "claude-wrapper.exe" } else { "claude-wrapper" })
}

/// Sets (Some) or removes (None) our wrapper key in settings text. None when a foreign wrapper is set
/// and we were asked to set ours. `path` is the raw path; JSON escaping is done here.
pub fn set_wrapper(text: &str, path: Option<&str>) -> Option<String> {
    let line = Regex::new(
        // Swift's tail was `[^\n]*`, which also ate a `}` sharing the line (`{\n  "k": "v"}`); only a comment is eaten here.
        r#"(?m)^[ \t]*"claudeCode\.claudeProcessWrapper"\s*:\s*"((?:[^"\\]|\\.)*)"[ \t]*(,?)[ \t]*(?://[^\n]*)?\n?"#,
    )
    .expect("constant pattern");
    if let Some(m) = line.captures(text) {
        let whole = m.get(0).expect("whole match");
        let value = unescape(&m[1]);
        let ours = value.ends_with("/.claude-anchor/bin/claude-wrapper")
            || value.to_lowercase().ends_with("\\.claude-anchor\\bin\\claude-wrapper.exe");
        let Some(path) = path else {
            if !ours { return Some(text.to_string()); }
            let mut head = text[..whole.start()].to_string();
            let tail = &text[whole.end()..];
            if m[2].is_empty() && tail.trim_start().starts_with('}') {   // was the last entry
                head = Regex::new(r",((?:\s*//[^\n]*)*\s*)$").expect("constant pattern").replace(&head, "$1").into_owned();
            }
            return Some(head + tail);
        };
        if value == path { return Some(text.to_string()); }
        if !ours { return None; }
        let g = m.get(1).expect("value group");
        return Some(format!("{}{}{}", &text[..g.start()], escape(path), &text[g.end()..]));
    }
    let Some(path) = path else { return Some(text.to_string()) };
    let Some(brace) = text.find('{') else { return Some(text.to_string()) };
    let rest = Regex::new(r"(?m)^\s*//.*$").expect("constant pattern").replace_all(&text[brace + 1..], "");
    let comma = if rest.trim_start().starts_with('}') { "" } else { "," };
    Some(format!("{}\n    \"{}\": \"{}\"{}{}", &text[..=brace], WRAPPER_KEY, escape(path), comma, &text[brace + 1..]))
}

/// Applies set_wrapper to every existing settings file (backup `<file>.anchor-backup` once).
/// Err is a user-facing message; Ok(false) when no editor settings exist.
pub fn apply(on: bool, paths: &Paths) -> Result<bool, String> {
    let found: Vec<PathBuf> = settings_files(paths).into_iter().filter(|f| f.exists()).collect();
    if found.is_empty() { return Ok(false); }
    let wrapper = wrapper_path(paths).display().to_string();
    for f in &found {
        let ab = abbreviate(f, &paths.home);
        let old = std::fs::read_to_string(f).map_err(|_| format!("Couldn't read {ab}. Check its permissions."))?;
        if old.trim().is_empty() { continue; }
        if !parses(&old) {
            return Err(format!("{ab} isn't valid JSON, so Anchor left it alone. Fix the file, then try again."));
        }
        let new = set_wrapper(&old, on.then_some(wrapper.as_str())).ok_or(
            "VS Code already uses a different Claude process wrapper. Remove it from settings, then try again.",
        )?;
        if new == old { continue; }
        if !parses(&new) { return Err(format!("Couldn't safely edit {ab}. Add the setting by hand.")); }
        let mut bak = f.clone().into_os_string();
        bak.push(".anchor-backup");
        let bak = PathBuf::from(bak);
        let write = || -> std::io::Result<()> {
            if !bak.exists() { std::fs::copy(f, &bak)?; }
            std::fs::write(f, &new)
        };
        write().map_err(|e| format!("Couldn't update {ab}: {}. Nothing was changed there.", fsx::reason(&e)))?;
    }
    Ok(true)
}

/// settings.json allows comments and trailing commas: drop comment lines and commas before a closer.
fn parses(t: &str) -> bool {
    let t = Regex::new(r"(?m)^\s*//.*$").expect("constant pattern").replace_all(t, "");
    let t = Regex::new(r",(\s*[}\]])").expect("constant pattern").replace_all(&t, "$1");
    serde_json::from_str::<serde_json::Value>(&t).is_ok()
}

/// Reads a JSON string body (without its quotes) back to the raw value.
fn unescape(v: &str) -> String {
    serde_json::from_str::<String>(&format!("\"{v}\"")).unwrap_or_else(|_| v.to_string())
}

fn escape(p: &str) -> String {
    p.replace('\\', "\\\\").replace('"', "\\\"")
}

#[cfg(test)]
mod tests {
    use super::*;

    const OURS: &str = "/h/.claude-anchor/bin/claude-wrapper";

    #[test]
    fn inserts_into_empty_and_nonempty_objects() {
        assert_eq!(
            set_wrapper("{}", Some(OURS)).unwrap(),
            format!("{{\n    \"{WRAPPER_KEY}\": \"{OURS}\"}}")
        );
        let new = set_wrapper("{\n  \"editor.fontSize\": 14\n}", Some(OURS)).unwrap();
        assert_eq!(new, format!("{{\n    \"{WRAPPER_KEY}\": \"{OURS}\",\n  \"editor.fontSize\": 14\n}}"));
        assert!(parses(&new));
    }

    #[test]
    fn keeps_comments() {
        let old = "// top\n{\n  // keep me\n  \"a\": 1\n}";
        let new = set_wrapper(old, Some(OURS)).unwrap();
        assert!(new.contains("// top") && new.contains("// keep me"), "{new}");
        assert!(parses(&new));
        assert_eq!(set_wrapper(&new, None).unwrap().matches("// keep me").count(), 1);
    }

    #[test]
    fn replaces_our_entry() {
        let old = format!("{{\n  \"{WRAPPER_KEY}\": \"/old/.claude-anchor/bin/claude-wrapper\",\n  \"a\": 1\n}}");
        let new = set_wrapper(&old, Some(OURS)).unwrap();
        assert_eq!(new, format!("{{\n  \"{WRAPPER_KEY}\": \"{OURS}\",\n  \"a\": 1\n}}"));
        assert_eq!(set_wrapper(&new, Some(OURS)), Some(new));
    }

    #[test]
    fn refuses_foreign_wrapper() {
        let old = format!("{{\n  \"{WRAPPER_KEY}\": \"/usr/bin/other\"\n}}");
        assert_eq!(set_wrapper(&old, Some(OURS)), None);
        assert_eq!(set_wrapper(&old, None), Some(old));
    }

    #[test]
    fn removes_entry_and_fixes_trailing_comma() {
        let last = format!("{{\n  \"a\": 1,\n  \"{WRAPPER_KEY}\": \"{OURS}\"\n}}");
        assert_eq!(set_wrapper(&last, None).unwrap(), "{\n  \"a\": 1\n}");
        let first = format!("{{\n  \"{WRAPPER_KEY}\": \"{OURS}\",\n  \"a\": 1\n}}");
        assert_eq!(set_wrapper(&first, None).unwrap(), "{\n  \"a\": 1\n}");
    }

    #[test]
    fn windows_path_is_escaped_and_recognised() {
        let win = r"C:\Users\me\.claude-anchor\bin\claude-wrapper.exe";
        let new = set_wrapper("{}", Some(win)).unwrap();
        assert!(new.contains(r#""C:\\Users\\me\\.claude-anchor\\bin\\claude-wrapper.exe""#), "{new}");
        let v: serde_json::Value = serde_json::from_str(&new).unwrap();
        assert_eq!(v[WRAPPER_KEY], win);
        let removed = set_wrapper(&new, None).unwrap();
        assert!(!removed.contains(WRAPPER_KEY) && parses(&removed));
    }

    #[test]
    fn settings_paths_end_in_user_settings() {
        let paths = Paths::from_home("/h");
        let files = settings_files(&paths);
        assert_eq!(files.len(), 4);
        assert!(files.iter().all(|f| f.ends_with("User/settings.json") || f.ends_with("User\\settings.json")));
    }

    #[cfg(not(windows))]
    #[test]
    fn apply_backs_up_and_toggles() {
        let home = tempfile::tempdir().unwrap();
        let paths = Paths::from_home(home.path());
        assert_eq!(apply(true, &paths), Ok(false));
        let files = settings_files(&paths);
        // Only touch files under the temp home (XDG_CONFIG_HOME may point elsewhere).
        if !files.iter().all(|f| f.starts_with(home.path())) { return; }
        let file = &files[0];
        std::fs::create_dir_all(file.parent().unwrap()).unwrap();
        std::fs::write(file, "{}\n").unwrap();
        assert_eq!(apply(true, &paths), Ok(true));
        assert!(std::fs::read_to_string(file).unwrap().contains(WRAPPER_KEY));
        let bak = PathBuf::from(format!("{}.anchor-backup", file.display()));
        assert_eq!(std::fs::read_to_string(&bak).unwrap(), "{}\n");
        assert_eq!(apply(false, &paths), Ok(true));
        let off = std::fs::read_to_string(file).unwrap();
        assert!(!off.contains(WRAPPER_KEY) && parses(&off));

        std::fs::write(file, format!("{{\n  \"{WRAPPER_KEY}\": \"/usr/bin/other\"\n}}")).unwrap();
        assert!(apply(true, &paths).unwrap_err().starts_with("VS Code already uses a different"));
        std::fs::write(file, "{ nope").unwrap();
        assert!(apply(true, &paths).unwrap_err().contains("isn't valid JSON"));
    }
}
