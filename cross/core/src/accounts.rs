//! App state shared by the CLI and the tray app: config, accounts, rules, sign-in, continue-on.
//! Port of Store.swift (load/seed/save, accounts, rules, continueSession, claudePath, signIn).

use crate::model::{Account, Config, Limits, Rule};
use crate::paths::{abbreviate, same_path, Paths};
use crate::{creds, editor, fsx, routes, sync, terminal};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};

pub struct Store {
    pub paths: Paths,
    pub config: Config,
    pub limits: HashMap<String, Limits>,
    pub save_blocked: bool, // config.json unreadable and couldn't be backed up: never overwrite it
}

const SHARED: [&str; 9] = ["settings.json", "CLAUDE.md", "skills", "agents", "commands", "plugins", "hooks", "output-styles", "keybindings.json"];

fn save_err(e: &dyn std::fmt::Display) -> String { format!("Couldn't save settings: {}.", fsx::reason(e)) }

impl Store {
    /// Loads config.json (seeding the primary account on first run, backing up an unreadable file).
    /// The String is a banner for the user, if any.
    pub fn load(paths: Paths) -> (Store, Option<String>) {
        let mut s = Store { paths, config: Config::default(), limits: HashMap::new(), save_blocked: false };
        let file = s.paths.config();
        if !file.exists() {
            s.seed(true);
            return (s, None);
        }
        if let Some(c) = std::fs::read(&file).ok().and_then(|d| serde_json::from_slice::<Config>(&d).ok()) {
            s.config = c;
            // A hand-edited default pointing nowhere falls back to the first account.
            let banner = if s.config.account(&s.config.default_id).is_none() {
                if let Some(first) = s.config.accounts.iter().find(|a| !a.pending).or(s.config.accounts.first()) {
                    s.config.default_id = first.id.clone();
                }
                s.save().err()
            } else {
                routes::write_routes(&s.config, &s.limits, &s.paths).err().map(|e| save_err(&e))
            };
            return (s, banner);
        }
        // Unreadable or wrong shape: keep it for the user, start fresh.
        let bak = PathBuf::from(format!("{}.broken-{}", file.display(), chrono::Utc::now().timestamp()));
        if std::fs::rename(&file, &bak).is_ok() {
            s.seed(true);
            (s, Some("Your settings file was unreadable. A backup was saved and fresh settings were created.".into()))
        } else {
            s.seed(false);
            s.save_blocked = true;
            let msg = format!("Your settings file was unreadable and couldn't be backed up. Fix or remove {}, then reopen Claude Anchor.", abbreviate(&file, &s.paths.home));
            (s, Some(msg))
        }
    }

    /// First run: the primary account, pending until Claude Code is signed in.
    fn seed(&mut self, persist: bool) {
        let mut a = Account { id: "primary".into(), name: "Personal".into(), flag: "a".into(), dir: self.paths.primary_dir.to_string_lossy().into_owned(),
                              email: None, plan: None, pending: false };
        let cj = creds::claude_json(&a, &self.paths);
        // Auto-created orgs are named "<email>'s Organization"; that's not a useful label.
        if let Some(org) = cj["oauthAccount"]["organizationName"].as_str().filter(|o| !o.ends_with("'s Organization")) { a.name = org.into(); }
        a.email = creds::email(&a, &self.paths);
        a.plan = creds::plan(&a, &self.paths);
        a.pending = !creds::signed_in(&a, &self.paths);
        self.config = Config { accounts: vec![a], default_id: "primary".into(), ..Config::default() };
        if persist { let _ = self.save(); }
    }

    /// Writes config.json (pretty, 0600) and the routes file.
    pub fn save(&mut self) -> Result<(), String> {
        if self.save_blocked { return Ok(()); }
        fsx::ensure_dir(&self.paths.anchor).map_err(|e| save_err(&e))?;
        let data = serde_json::to_vec_pretty(&self.config).map_err(|e| save_err(&e))?;
        fsx::write_secure(&self.paths.config(), &data, 0o600).map_err(|e| save_err(&e))?;
        routes::write_routes(&self.config, &self.limits, &self.paths).map_err(|e| save_err(&e))
    }

    /// Rewrites routes only (after limits change).
    pub fn set_limits(&mut self, limits: HashMap<String, Limits>) -> Result<(), String> {
        self.limits = limits;
        if self.save_blocked { return Ok(()); }
        routes::write_routes(&self.config, &self.limits, &self.paths).map_err(|e| save_err(&e))
    }

    /// Keeps the primary's pending flag in step with the CLI. Returns true when config changed.
    pub fn reconcile_primary(&mut self) -> bool {
        let Some(i) = self.config.accounts.iter().position(|a| a.id == "primary") else { return false };
        let a = self.config.accounts[i].clone();
        let ok = creds::signed_in(&a, &self.paths);
        let acc = &mut self.config.accounts[i];
        if ok && a.pending {
            acc.email = creds::email(&a, &self.paths);
            acc.plan = creds::plan(&a, &self.paths);
            acc.pending = false;
        } else if !ok && !a.pending {
            acc.pending = true;
            acc.email = None;
            acc.plan = None;
            self.limits.remove("primary");
        } else {
            return false;
        }
        let _ = self.save();
        true
    }

    /// Creates `<anchor>/accounts/<slug>` sharing settings/skills/etc. with ~/.claude. Returns the new id.
    pub fn add_account(&mut self, name: &str, flag: &str) -> Result<String, String> {
        let mut slug: String = name.to_lowercase().chars().map(|c| if c.is_ascii_alphanumeric() { c } else { '-' }).collect();
        slug = slug.trim_matches('-').to_string();
        if slug.is_empty() { slug = "account".into(); }
        let (mut id, mut n) = (slug.clone(), 2);
        while id == "primary" || self.config.account(&id).is_some() { id = format!("{slug}-{n}"); n += 1; }
        let dir = self.paths.accounts().join(&id);
        let made = fsx::ensure_dir(&self.paths.anchor).and_then(|_| fsx::ensure_dir(&self.paths.accounts())).and_then(|_| fsx::ensure_dir(&dir));
        if let Err(e) = made {
            return Err(format!("Couldn't create a folder for {name}: {}. Check disk space and permissions, then try again.", fsx::reason(&e)));
        }
        for f in SHARED {
            let target = self.paths.primary_dir.join(f);
            if target.exists() { let _ = share(&target, &dir.join(f)); }
        }
        self.config.accounts.push(Account { id: id.clone(), name: name.into(), flag: flag.into(), dir: dir.to_string_lossy().into_owned(), email: None, plan: None, pending: true });
        self.save()?;
        Ok(id)
    }

    /// Err also covers "removed, but the folder couldn't go to the Trash" (the account is gone either way).
    pub fn remove_account(&mut self, id: &str, reassign_to: &str) -> Result<(), String> {
        // Only ever trash a direct child of ~/.claude-anchor/accounts (config.json is hand-editable).
        let a = self.config.account(id).cloned().ok_or("That account doesn't exist.")?;
        let dir = Path::new(&a.dir);
        let plain = dir.components().all(|c| !matches!(c, std::path::Component::ParentDir | std::path::Component::CurDir));
        if creds::is_primary(&a, &self.paths) || id == reassign_to || !plain || !dir.parent().is_some_and(|p| same_path(p, &self.paths.accounts())) {
            return Err(format!("{} can't be removed.", a.name));
        }
        if self.config.account(reassign_to).is_none() { return Err("Pick an account to move its folders to.".into()); }
        for r in self.config.rules.iter_mut().filter(|r| r.account_id == id) { r.account_id = reassign_to.into(); }
        if self.config.default_id == id { self.config.default_id = reassign_to.into(); }
        self.config.removed_names.insert(id.into(), a.name.clone());
        creds::forget(&a, &self.paths);
        // Tests delete outright: never fill the developer's Trash, and CI runners may have none.
        let trashed = if cfg!(test) { std::fs::remove_dir_all(dir).map_err(|e| e.to_string()) } else { trash::delete(dir).map_err(|e| e.to_string()) };
        self.config.accounts.retain(|x| x.id != id);
        self.limits.remove(id);
        self.save()?;
        trashed.map_err(|e| format!("Removed {}, but couldn't move its folder to the Trash: {}. You can delete {} yourself.",
                                    a.name, fsx::reason(&e), abbreviate(dir, &self.paths.home)))
    }

    fn account_mut(&mut self, id: &str) -> Result<&mut Account, String> {
        self.config.accounts.iter_mut().find(|a| a.id == id).ok_or_else(|| "That account doesn't exist.".into())
    }

    pub fn rename(&mut self, id: &str, name: &str) -> Result<(), String> {
        self.account_mut(id)?.name = name.into();
        self.save()
    }
    pub fn set_flag(&mut self, id: &str, flag: &str) -> Result<(), String> {
        if flag.len() != 1 || !flag.as_bytes()[0].is_ascii_lowercase() { return Err("Pick a flag from a to z.".into()); }
        self.account_mut(id)?.flag = flag.into();
        self.save()
    }
    pub fn set_default(&mut self, id: &str) -> Result<(), String> {
        self.account_mut(id)?;
        self.config.default_id = id.into();
        self.save()
    }
    /// `to` is the insertion offset in the list before the move (SwiftUI `move(fromOffsets:toOffset:)`).
    pub fn move_account(&mut self, from: usize, to: usize) -> Result<(), String> {
        let n = self.config.accounts.len();
        if from >= n || to > n { return Err("That position doesn't exist.".into()); }
        let a = self.config.accounts.remove(from);
        self.config.accounts.insert(to - usize::from(from < to), a);
        self.save()
    }

    pub fn add_rule(&mut self, path: &str, account_id: &str) -> Result<(), String> {
        let p = routes::normalize_rule_path(path)?;
        if self.config.account(account_id).is_none() { return Err("That account doesn't exist.".into()); }
        self.config.rules.retain(|r| !same_path(Path::new(&r.path), Path::new(&p)));
        self.config.rules.push(Rule { path: p, account_id: account_id.into(), allow_overflow: false });
        self.save()
    }
    pub fn remove_rule(&mut self, path: &str) -> Result<(), String> {
        self.config.rules.retain(|r| r.path != path);
        self.save()
    }
    pub fn set_rule_overflow(&mut self, path: &str, on: bool) -> Result<(), String> {
        let r = self.config.rules.iter_mut().find(|r| r.path == path).ok_or("That rule doesn't exist.")?;
        r.allow_overflow = on;
        self.save()
    }
    pub fn set_editor_integration(&mut self, on: bool) -> Result<(), String> {
        if !editor::apply(on, &self.paths)? { return Err("No VS Code or Cursor settings found.".into()); }
        self.config.editor_integration = Some(on);
        self.save()
    }

    /// After `claude auth login` exits for `id`. Ok(message) or Err(message), both user-facing.
    pub fn finish_sign_in(&mut self, id: &str, ok: bool) -> Result<String, String> {
        let i = self.config.accounts.iter().position(|a| a.id == id).ok_or("That account doesn't exist.")?;
        let a = self.config.accounts[i].clone();
        let Some(mail) = creds::email(&a, &self.paths).filter(|_| ok) else {
            return Err(format!("Sign-in for {} didn't finish. Try again.", a.name));
        };
        // A browser already signed in to claude.ai hands back that same account.
        if let Some(twin) = self.config.accounts.iter().find(|t| t.id != id && t.email.as_deref() == Some(&mail)) {
            let msg = format!("{} signed in as {mail}, which is already {}. Switch accounts on claude.ai, then sign in again.", a.name, twin.name);
            self.config.accounts[i].pending = true;
            self.save()?;
            return Err(msg);
        }
        let acc = &mut self.config.accounts[i];
        acc.email = Some(mail.clone());
        acc.plan = creds::plan(&a, &self.paths);
        acc.pending = false;
        self.save()?;
        Ok(format!("{} is signed in as {mail}.", a.name))
    }

    /// Copies the last conversation to `target_id` and opens a terminal to resume it. Ok(banner) / Err(banner).
    pub fn continue_session(&mut self, last: &crate::usage::LastSession, target_id: &str, usage: &crate::usage::UsageIndex) -> Result<String, String> {
        let none = || "No recent conversation to continue.".to_string();
        let file = last.file.as_deref().ok_or_else(none)?;
        let t = self.config.account(target_id).filter(|t| !t.pending && t.id != last.account_id).cloned().ok_or_else(none)?;
        let file = Path::new(file);
        if !file.exists() { return Err("That conversation's file is gone, so it can't be continued.".into()); }
        let sid = file.file_stem().and_then(|s| s.to_str()).unwrap_or("");
        // Only real session ids reach the terminal command line.
        if !is_uuid(sid) { return Err("That conversation can't be continued.".into()); }
        let copied = sync::copy_transcript(file, Path::new(&t.dir)).map_err(|e| format!(
            "Couldn't copy the conversation to {}: {}. Check that {} is writable.", t.name, fsx::reason(&e), abbreviate(Path::new(&t.dir), &self.paths.home)))?;
        for p in &copied { usage.mark_copied(p); }
        let cwd_ok = Path::new(&last.cwd).is_dir();
        let cwd = if cwd_ok { Path::new(&last.cwd) } else { self.paths.home.as_path() };
        terminal::open_resume(cwd, creds::config_dir_env(&t, &self.paths), &t.id, sid)?;
        Ok(if cwd_ok { format!("Continuing on {}. Close the old session so the two don't drift apart.", t.name) }
           else { "That project folder no longer exists, so the conversation opens in your home folder.".into() })
    }
}

/// 8-4-4-4-12 hex.
fn is_uuid(s: &str) -> bool {
    s.len() == 36 && s.char_indices().all(|(i, c)| if matches!(i, 8 | 13 | 18 | 23) { c == '-' } else { c.is_ascii_hexdigit() })
}

#[cfg(unix)]
fn share(target: &Path, link: &Path) -> std::io::Result<()> { std::os::unix::fs::symlink(target, link) }

/// Windows: folders as junctions (no admin rights needed), files copied.
#[cfg(windows)]
fn share(target: &Path, link: &Path) -> std::io::Result<()> {
    if target.is_dir() {
        let ok = Command::new("cmd").arg("/C").arg("mklink").arg("/J").arg(link).arg(target)
            .stdout(Stdio::null()).stderr(Stdio::null()).status()?.success();
        if ok { Ok(()) } else { Err(std::io::Error::other("mklink failed")) }
    } else {
        std::fs::copy(target, link).map(|_| ())
    }
}

fn is_exe(p: &Path) -> bool {
    #[cfg(unix)]
    { use std::os::unix::fs::PermissionsExt; p.metadata().is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0) }
    #[cfg(not(unix))]
    { p.is_file() }
}

/// Claude Code CLI path: known install locations, then the login shell / `where`.
pub fn claude_path(paths: &Paths) -> Option<PathBuf> {
    if let Some(p) = claude_fast_path(paths) { return Some(p); }
    let out = if cfg!(windows) { Command::new("where").arg("claude").output() }
              else { Command::new("bash").args(["-lc", "command -v claude"]).stderr(Stdio::null()).output() }.ok()?;
    let text = String::from_utf8_lossy(&out.stdout);
    // Login shells may print banners; the path is the last line. `where` lists the best match first.
    let line = if cfg!(windows) { text.lines().next() } else { text.lines().last() };
    line.map(|l| PathBuf::from(l.trim())).filter(|p| is_exe(p))
}

/// Fast check (stats only) used to show "Claude Code isn't installed".
pub fn claude_fast_path(paths: &Paths) -> Option<PathBuf> {
    let h = &paths.home;
    let env = |k: &str| std::env::var_os(k).map(PathBuf::from);
    let list: Vec<PathBuf> = if cfg!(windows) {
        [Some(h.join(".local/bin/claude.exe")), env("APPDATA").map(|d| d.join("npm/claude.cmd")),
         env("LOCALAPPDATA").map(|d| d.join("Programs/claude/claude.exe"))].into_iter().flatten().collect()
    } else {
        let mut v = vec![h.join(".local/bin/claude"), "/usr/local/bin/claude".into(), "/usr/bin/claude".into(),
                         h.join(".claude/local/claude"), h.join(".npm-global/bin/claude")];
        if cfg!(target_os = "macos") { v.insert(1, "/opt/homebrew/bin/claude".into()); }
        v
    };
    list.into_iter().find(|p| is_exe(p))
}

/// The CLI as a Command; Windows batch shims run through `cmd /C`.
fn claude_command(exe: &Path) -> Command {
    let ext = exe.extension().and_then(|e| e.to_str()).unwrap_or("").to_lowercase();
    let mut c = if cfg!(windows) && (ext == "cmd" || ext == "bat") { let mut c = Command::new("cmd"); c.arg("/C").arg(exe); c } else { Command::new(exe) };
    #[cfg(windows)]
    { use std::os::windows::process::CommandExt; c.creation_flags(0x0800_0000); } // CREATE_NO_WINDOW
    c.stdout(Stdio::null()).stderr(Stdio::null());
    c
}

/// Starts `claude auth login` for the account (browser flow, stdin kept open, output discarded).
pub fn spawn_login(store: &Store, id: &str) -> Result<Child, String> {
    let a = store.config.account(id).ok_or("That account doesn't exist.")?;
    let exe = claude_path(&store.paths).ok_or("Claude Code isn't installed. Install it, then sign in again.")?;
    let mut c = claude_command(&exe);
    c.args(["auth", "login"]);
    match creds::config_dir_env(a, &store.paths) {
        Some(d) => { let _ = fsx::ensure_dir(Path::new(d)); c.env("CLAUDE_CONFIG_DIR", d); } // the CLI needs its config dir to exist
        None => { c.env_remove("CLAUDE_CONFIG_DIR"); }
    }
    c.stdin(Stdio::piped()); // kept open (it stays in the Child) so the CLI waits for the browser instead of reading EOF
    c.spawn().map_err(|e| format!("Couldn't start Claude Code to sign in {}: {}. Check that `claude` runs in a terminal, then try again.", a.name, fsx::reason(&e)))
}

/// Starts `claude auth logout` for the primary account.
pub fn spawn_logout_primary(paths: &Paths) -> Result<Child, String> {
    let exe = claude_path(paths).ok_or("Claude Code isn't installed, so there's nothing to sign out of.")?;
    let mut c = claude_command(&exe);
    c.args(["auth", "logout"]).env_remove("CLAUDE_CONFIG_DIR").stdin(Stdio::null());
    c.spawn().map_err(|e| format!("Couldn't start Claude Code to sign out: {}. Try again.", fsx::reason(&e)))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn home() -> (tempfile::TempDir, Paths) {
        let t = tempfile::tempdir().unwrap();
        let p = Paths::from_home(t.path());
        (t, p)
    }
    fn two() -> (tempfile::TempDir, Store) {
        let (t, p) = home();
        let (mut s, _) = Store::load(p);
        s.add_account("Work", "b").unwrap();
        (t, s)
    }

    #[test]
    fn seeds_primary_on_first_run() {
        let (t, p) = home();
        std::fs::write(t.path().join(".claude.json"), r#"{"oauthAccount":{"emailAddress":"me@x.y","organizationName":"Acme"}}"#).unwrap();
        let (s, banner) = Store::load(p.clone());
        assert!(banner.is_none() && !s.save_blocked);
        let a = &s.config.accounts[0];
        assert_eq!((a.id.as_str(), a.name.as_str(), a.flag.as_str(), a.email.as_deref(), a.pending), ("primary", "Acme", "a", Some("me@x.y"), false));
        assert_eq!(s.config.default_id, "primary");
        assert!(p.config().exists());
        let (s2, _) = Store::load(p);
        assert_eq!(s2.config, s.config);
    }

    #[test]
    fn seed_names_and_pending() {
        let (t, p) = home();
        std::fs::write(t.path().join(".claude.json"), r#"{"oauthAccount":{"organizationName":"me@x.y's Organization"}}"#).unwrap();
        let (s, _) = Store::load(p);
        assert_eq!(s.config.accounts[0].name, "Personal");
        assert!(s.config.accounts[0].pending, "no email and no credentials");
    }

    #[test]
    fn broken_config_is_backed_up() {
        let (_t, p) = home();
        std::fs::create_dir_all(&p.anchor).unwrap();
        std::fs::write(p.config(), "{oops").unwrap();
        let (s, banner) = Store::load(p.clone());
        assert_eq!(banner.as_deref(), Some("Your settings file was unreadable. A backup was saved and fresh settings were created."));
        assert_eq!(s.config.accounts.len(), 1);
        let bak: Vec<_> = std::fs::read_dir(&p.anchor).unwrap().flatten().filter(|e| e.file_name().to_string_lossy().starts_with("config.json.broken-")).collect();
        assert_eq!(bak.len(), 1);
        assert_eq!(std::fs::read_to_string(bak[0].path()).unwrap(), "{oops");
    }

    #[test]
    fn dangling_default_falls_back() {
        let (_t, p) = home();
        let (mut s, _) = Store::load(p.clone());
        s.config.default_id = "ghost".into();
        s.save().unwrap();
        let (s2, _) = Store::load(p);
        assert_eq!(s2.config.default_id, "primary");
    }

    #[test]
    fn add_account_slugs_and_shares() {
        let (_t, p) = home();
        std::fs::create_dir_all(p.primary_dir.join("skills")).unwrap();
        std::fs::write(p.primary_dir.join("CLAUDE.md"), "hi").unwrap();
        let (mut s, _) = Store::load(p.clone());
        assert_eq!(s.add_account("  My Work!! ", "b").unwrap(), "my-work");
        assert_eq!(s.add_account("my work", "c").unwrap(), "my-work-2");
        assert_eq!(s.add_account("Primary", "c").unwrap(), "primary-2");
        assert_eq!(s.add_account("日本", "c").unwrap(), "account");
        let d = p.accounts().join("my-work");
        assert!(s.config.account("my-work").unwrap().pending);
        #[cfg(unix)]
        { assert!(d.join("skills").symlink_metadata().unwrap().file_type().is_symlink()); }
        assert_eq!(std::fs::read_to_string(d.join("CLAUDE.md")).unwrap(), "hi");
        assert!(!d.join("hooks").exists());
        #[cfg(unix)]
        { use std::os::unix::fs::PermissionsExt; assert_eq!(p.config().metadata().unwrap().permissions().mode() & 0o777, 0o600); }
    }

    #[test]
    fn remove_account_guards_and_reassigns() {
        let (_t, mut s) = two();
        s.config.rules.push(Rule { path: "/w".into(), account_id: "work".into(), allow_overflow: false });
        s.config.default_id = "work".into();
        assert!(s.remove_account("primary", "work").is_err());
        assert!(s.remove_account("work", "work").is_err());
        assert!(s.remove_account("work", "ghost").is_err());
        // hand-edited dir outside accounts/ is never trashed
        let outside = s.paths.home.join("precious");
        std::fs::create_dir_all(&outside).unwrap();
        s.config.accounts[1].dir = outside.to_string_lossy().into_owned();
        assert!(s.remove_account("work", "primary").is_err() && outside.exists());
        s.config.accounts[1].dir = format!("{}/../precious", s.paths.accounts().display());
        assert!(s.remove_account("work", "primary").is_err() && outside.exists());
        s.config.accounts[1].dir = s.paths.accounts().join("work").to_string_lossy().into_owned();
        // trash may be unavailable in CI; the account is removed either way
        let _ = s.remove_account("work", "primary");
        assert!(s.config.account("work").is_none());
        assert_eq!((s.config.default_id.as_str(), s.config.rules[0].account_id.as_str()), ("primary", "primary"));
        assert_eq!(s.config.removed_names["work"], "Work");
    }

    #[test]
    fn rename_flag_default_move() {
        let (_t, mut s) = two();
        s.add_account("Third", "c").unwrap();
        s.rename("work", "Job").unwrap();
        s.set_flag("work", "z").unwrap();
        assert!(s.set_flag("work", "ZZ").is_err() && s.set_flag("ghost", "a").is_err());
        s.set_default("work").unwrap();
        assert!(s.set_default("ghost").is_err());
        let ids = |s: &Store| s.config.accounts.iter().map(|a| a.id.clone()).collect::<Vec<_>>();
        s.move_account(0, 3).unwrap();
        assert_eq!(ids(&s), ["work", "third", "primary"]);
        s.move_account(2, 0).unwrap();
        assert_eq!(ids(&s), ["primary", "work", "third"]);
        s.move_account(0, 1).unwrap();
        assert_eq!(ids(&s), ["primary", "work", "third"]);
        assert!(s.move_account(3, 0).is_err());
        let (s2, _) = Store::load(s.paths.clone());
        assert_eq!((s2.config.accounts[1].name.as_str(), s2.config.accounts[1].flag.as_str(), s2.config.default_id.as_str()), ("Job", "z", "work"));
    }

    #[test]
    fn rules_validate_and_replace() {
        let (_t, mut s) = two();
        // normalize_rule_path belongs to routes.rs; here only the account check and replace/remove/overflow flow.
        assert!(s.add_rule("/proj", "ghost").is_err());
        s.add_rule("/proj", "work").unwrap();
        s.add_rule("/proj", "primary").unwrap();
        assert_eq!(s.config.rules.len(), 1);
        assert_eq!(s.config.rules[0].account_id, "primary");
        s.set_rule_overflow("/proj", true).unwrap();
        assert!(s.config.rules[0].allow_overflow && s.set_rule_overflow("/nope", true).is_err());
        s.remove_rule("/proj").unwrap();
        assert!(s.config.rules.is_empty());
        assert!(s.add_rule("relative/path", "work").is_err());
    }

    #[test]
    fn sign_in_twin_and_success() {
        let (t, mut s) = two();
        s.config.accounts[0].email = Some("a@x.y".into());
        s.config.accounts[0].pending = false;
        let wd = s.paths.accounts().join("work");
        assert!(s.finish_sign_in("work", false).unwrap_err().starts_with("Sign-in for Work didn't finish"));
        assert!(s.finish_sign_in("work", true).is_err(), "no email recorded yet");
        std::fs::write(wd.join(".claude.json"), r#"{"oauthAccount":{"emailAddress":"a@x.y"}}"#).unwrap();
        assert_eq!(s.finish_sign_in("work", true).unwrap_err(),
            "Work signed in as a@x.y, which is already Personal. Switch accounts on claude.ai, then sign in again.");
        assert!(s.config.account("work").unwrap().pending);
        std::fs::write(wd.join(".claude.json"), r#"{"oauthAccount":{"emailAddress":"w@x.y"}}"#).unwrap();
        std::fs::write(wd.join(".credentials.json"), r#"{"claudeAiOauth":{"subscriptionType":"max"}}"#).unwrap();
        assert!(s.finish_sign_in("work", true).is_ok());
        let w = s.config.account("work").unwrap();
        assert_eq!((w.email.as_deref(), w.plan.as_deref(), w.pending), (Some("w@x.y"), Some("max"), false));
        drop(t);
    }

    #[test]
    fn reconcile_primary_tracks_cli() {
        let (t, mut s) = two();
        assert!(s.config.accounts[0].pending && !s.reconcile_primary());
        std::fs::write(t.path().join(".claude.json"), r#"{"oauthAccount":{"emailAddress":"me@x.y"}}"#).unwrap();
        assert!(s.reconcile_primary());
        assert_eq!(s.config.accounts[0].email.as_deref(), Some("me@x.y"));
        std::fs::remove_file(t.path().join(".claude.json")).unwrap();
        assert!(s.reconcile_primary() && s.config.accounts[0].pending);
    }

    #[test]
    fn uuid_format() {
        assert!(is_uuid("123e4567-e89b-12d3-a456-426614174000"));
        assert!(!is_uuid("123e4567-e89b-12d3-a456-42661417400") && !is_uuid("../../etc/passwd-aaaaaaaaaaaaaaaaaaaaaa") && !is_uuid("zzze4567-e89b-12d3-a456-426614174000"));
    }

    #[test]
    fn finds_claude_in_known_places() {
        let (_t, p) = home();
        assert!(claude_fast_path(&p).is_none() || cfg!(not(windows)), "may exist on a dev machine outside the temp home");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let bin = p.home.join(".local/bin");
            std::fs::create_dir_all(&bin).unwrap();
            std::fs::write(bin.join("claude"), "#!/bin/sh\n").unwrap();
            assert!(claude_fast_path(&p).is_none_or(|f| f != bin.join("claude")), "not executable yet");
            std::fs::set_permissions(bin.join("claude"), std::fs::Permissions::from_mode(0o755)).unwrap();
            assert_eq!(claude_fast_path(&p), Some(bin.join("claude")));
        }
    }
}
