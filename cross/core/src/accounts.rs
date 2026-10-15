//! App state shared by the CLI and the tray app: config, accounts, rules, sign-in, continue-on.
//! Port of Store.swift (load/seed/save, accounts, rules, continueSession, claudePath, signIn).

use crate::model::{Config, Limits};
use crate::paths::Paths;
use std::collections::HashMap;
use std::path::PathBuf;
use std::process::Child;

pub struct Store {
    pub paths: Paths,
    pub config: Config,
    pub limits: HashMap<String, Limits>,
    pub save_blocked: bool, // config.json unreadable and couldn't be backed up: never overwrite it
}

impl Store {
    /// Loads config.json (seeding the primary account on first run, backing up an unreadable file).
    /// The String is a banner for the user, if any.
    pub fn load(paths: Paths) -> (Store, Option<String>) { todo!() }
    /// Writes config.json (pretty, 0600) and the routes file.
    pub fn save(&mut self) -> Result<(), String> { todo!() }
    /// Rewrites routes only (after limits change).
    pub fn set_limits(&mut self, limits: HashMap<String, Limits>) -> Result<(), String> { todo!() }
    /// Keeps the primary's pending flag in step with the CLI. Returns true when config changed.
    pub fn reconcile_primary(&mut self) -> bool { todo!() }
    /// Creates `<anchor>/accounts/<slug>` sharing settings/skills/etc. with ~/.claude. Returns the new id.
    pub fn add_account(&mut self, name: &str, flag: &str) -> Result<String, String> { todo!() }
    pub fn remove_account(&mut self, id: &str, reassign_to: &str) -> Result<(), String> { todo!() }
    pub fn rename(&mut self, id: &str, name: &str) -> Result<(), String> { todo!() }
    pub fn set_flag(&mut self, id: &str, flag: &str) -> Result<(), String> { todo!() }
    pub fn set_default(&mut self, id: &str) -> Result<(), String> { todo!() }
    pub fn move_account(&mut self, from: usize, to: usize) -> Result<(), String> { todo!() }
    pub fn add_rule(&mut self, path: &str, account_id: &str) -> Result<(), String> { todo!() }
    pub fn remove_rule(&mut self, path: &str) -> Result<(), String> { todo!() }
    pub fn set_rule_overflow(&mut self, path: &str, on: bool) -> Result<(), String> { todo!() }
    pub fn set_editor_integration(&mut self, on: bool) -> Result<(), String> { todo!() }
    /// After `claude auth login` exits for `id`. Ok(message) or Err(message), both user-facing.
    pub fn finish_sign_in(&mut self, id: &str, ok: bool) -> Result<String, String> { todo!() }
    /// Copies the last conversation to `target_id` and opens a terminal to resume it. Ok(banner) / Err(banner).
    pub fn continue_session(&mut self, last: &crate::usage::LastSession, target_id: &str, usage: &crate::usage::UsageIndex) -> Result<String, String> { todo!() }
}

/// Claude Code CLI path: known install locations, then the login shell / `where`.
pub fn claude_path(paths: &Paths) -> Option<PathBuf> { todo!() }
/// Fast check (stats only) used to show "Claude Code isn't installed".
pub fn claude_fast_path(paths: &Paths) -> Option<PathBuf> { todo!() }
/// Starts `claude auth login` for the account (browser flow, stdin kept open, output discarded).
pub fn spawn_login(store: &Store, id: &str) -> Result<Child, String> { todo!() }
/// Starts `claude auth logout` for the primary account.
pub fn spawn_logout_primary(paths: &Paths) -> Result<Child, String> { todo!() }
