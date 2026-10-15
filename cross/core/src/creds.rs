//! Claude Code's own records per account: `.claude.json` and OAuth credentials.
//! Windows/Linux: `<config dir>/.credentials.json`. macOS (dev only): Keychain via `security`.

use crate::model::Account;
use crate::paths::Paths;
use serde_json::Value;
use std::path::PathBuf;

pub(crate) fn is_primary(a: &Account, paths: &Paths) -> bool { a.id == "primary" || paths.is_primary(&a.dir) }

/// CLAUDE_CONFIG_DIR for this account; None = primary (variable unset).
pub(crate) fn config_dir_env<'a>(a: &'a Account, paths: &Paths) -> Option<&'a str> {
    if is_primary(a, paths) { None } else { Some(&a.dir) }
}

fn read_json(p: PathBuf) -> Value {
    std::fs::read(p).ok().and_then(|d| serde_json::from_slice(&d).ok()).unwrap_or(Value::Null)
}

/// The account's .claude.json (primary's lives in HOME, others in their config dir). Null when missing.
pub fn claude_json(a: &Account, paths: &Paths) -> Value {
    read_json(if is_primary(a, paths) { paths.home.join(".claude.json") } else { PathBuf::from(&a.dir).join(".claude.json") })
}

#[cfg(target_os = "macos")]
fn service(a: &Account, paths: &Paths) -> String {
    use sha2::{Digest, Sha256};
    match config_dir_env(a, paths) {
        None => "Claude Code-credentials".into(),
        Some(d) => {
            let h: String = Sha256::digest(d.as_bytes()).iter().map(|b| format!("{b:02x}")).collect();
            format!("Claude Code-credentials-{}", &h[..8])
        }
    }
}

/// Keychain read; skipped under test so unit tests never touch the real Keychain.
#[cfg(all(target_os = "macos", not(test)))]
fn keychain(a: &Account, paths: &Paths) -> Option<Value> {
    let out = std::process::Command::new("/usr/bin/security")
        .args(["find-generic-password", "-s", &service(a, paths), "-w"]).stderr(std::process::Stdio::null()).output().ok()?;
    if !out.status.success() { return None; }
    serde_json::from_slice(&out.stdout).ok()
}
#[cfg(any(not(target_os = "macos"), test))]
fn keychain(_: &Account, _: &Paths) -> Option<Value> { None }

fn credentials(a: &Account, paths: &Paths) -> Option<Value> {
    keychain(a, paths).or_else(|| {
        let dir = if is_primary(a, paths) { paths.primary_dir.clone() } else { PathBuf::from(&a.dir) };
        Some(read_json(dir.join(".credentials.json"))).filter(|v| v.is_object())
    })
}

/// `claudeAiOauth` object from the account's credentials, if signed in.
pub fn oauth(a: &Account, paths: &Paths) -> Option<Value> {
    credentials(a, paths)?.get("claudeAiOauth").filter(|v| v.is_object()).cloned()
}

pub fn email(a: &Account, paths: &Paths) -> Option<String> {
    claude_json(a, paths)["oauthAccount"]["emailAddress"].as_str().map(String::from)
}
pub fn plan(a: &Account, paths: &Paths) -> Option<String> {
    oauth(a, paths)?["subscriptionType"].as_str().map(String::from)
}
/// Claude Code left an account record or a credential for this dir.
pub fn signed_in(a: &Account, paths: &Paths) -> bool { email(a, paths).is_some() || credentials(a, paths).is_some() }

/// Removes stored credentials outside the account folder (macOS Keychain only; elsewhere a no-op).
#[allow(unused_variables)]
pub fn forget(a: &Account, paths: &Paths) {
    #[cfg(all(target_os = "macos", not(test)))]
    let _ = std::process::Command::new("/usr/bin/security").args(["delete-generic-password", "-s", &service(a, paths)])
        .stdout(std::process::Stdio::null()).stderr(std::process::Stdio::null()).status();
}

#[cfg(test)]
mod tests {
    use super::*;

    fn acct(dir: &str) -> Account {
        Account { id: "work".into(), name: "Work".into(), flag: "b".into(), dir: dir.into(), email: None, plan: None, pending: false }
    }

    #[test]
    fn reads_credentials_and_claude_json() {
        let t = tempfile::tempdir().unwrap();
        let p = Paths::from_home(t.path());
        let d = t.path().join("acc");
        std::fs::create_dir_all(&d).unwrap();
        let a = acct(d.to_str().unwrap());
        assert!(!signed_in(&a, &p) && email(&a, &p).is_none() && claude_json(&a, &p).is_null());
        std::fs::write(d.join(".credentials.json"), r#"{"claudeAiOauth":{"accessToken":"t","subscriptionType":"max","expiresAt":1}}"#).unwrap();
        std::fs::write(d.join(".claude.json"), r#"{"oauthAccount":{"emailAddress":"a@b.c"}}"#).unwrap();
        assert_eq!(oauth(&a, &p).unwrap()["accessToken"], "t");
        assert_eq!(plan(&a, &p).as_deref(), Some("max"));
        assert_eq!(email(&a, &p).as_deref(), Some("a@b.c"));
        assert!(signed_in(&a, &p));
    }

    #[test]
    fn primary_uses_home_and_primary_dir() {
        let t = tempfile::tempdir().unwrap();
        let p = Paths::from_home(t.path());
        let a = Account { id: "primary".into(), dir: p.primary_dir.to_str().unwrap().into(), ..acct("") };
        std::fs::create_dir_all(&p.primary_dir).unwrap();
        std::fs::write(t.path().join(".claude.json"), r#"{"oauthAccount":{"emailAddress":"me@x.y"}}"#).unwrap();
        std::fs::write(p.primary_dir.join(".credentials.json"), r#"{"claudeAiOauth":{"subscriptionType":"pro"}}"#).unwrap();
        assert_eq!(email(&a, &p).as_deref(), Some("me@x.y"));
        assert_eq!(plan(&a, &p).as_deref(), Some("pro"));
        assert_eq!(config_dir_env(&a, &p), None);
    }

    #[test]
    fn invalid_json_is_null() {
        let t = tempfile::tempdir().unwrap();
        let p = Paths::from_home(t.path());
        std::fs::write(t.path().join(".claude.json"), "{nope").unwrap();
        let a = Account { id: "primary".into(), ..acct(p.primary_dir.to_str().unwrap()) };
        assert!(claude_json(&a, &p).is_null());
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn keychain_service_names() {
        let p = Paths::from_home("/h");
        let prim = Account { id: "primary".into(), ..acct("/h/.claude") };
        assert_eq!(service(&prim, &p), "Claude Code-credentials");
        // shasum -a 256 of "/x" starts with b3d1db31
        assert_eq!(service(&acct("/x"), &p), "Claude Code-credentials-b3d1db31");
    }
}
