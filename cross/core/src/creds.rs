//! Claude Code's own records per account: `.claude.json` and OAuth credentials.
//! Windows/Linux: `<config dir>/.credentials.json`. macOS (dev only): Keychain via `security`.

use crate::model::Account;
use crate::paths::Paths;
use serde_json::Value;

/// The account's .claude.json (primary's lives in HOME, others in their config dir). Null when missing.
pub fn claude_json(a: &Account, paths: &Paths) -> Value { todo!() }

/// `claudeAiOauth` object from the account's credentials, if signed in.
pub fn oauth(a: &Account, paths: &Paths) -> Option<Value> { todo!() }

pub fn email(a: &Account, paths: &Paths) -> Option<String> { todo!() }
pub fn plan(a: &Account, paths: &Paths) -> Option<String> { todo!() }
/// Claude Code left an account record or a credential for this dir.
pub fn signed_in(a: &Account, paths: &Paths) -> bool { todo!() }
/// Removes stored credentials outside the account folder (macOS Keychain only; elsewhere a no-op).
pub fn forget(a: &Account, paths: &Paths) { todo!() }
