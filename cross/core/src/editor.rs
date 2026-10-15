//! VS Code / Cursor integration: sets `claudeCode.claudeProcessWrapper` in user settings.json,
//! editing as text so comments survive. Port of Store.swift `setWrapper` / `setEditorIntegration`.

use crate::paths::Paths;
use std::path::PathBuf;

pub const WRAPPER_KEY: &str = "claudeCode.claudeProcessWrapper";

/// User settings.json candidates for Code, Cursor, Code - Insiders, VSCodium on this OS (existing or not).
pub fn settings_files(paths: &Paths) -> Vec<PathBuf> { todo!() }

/// `<anchor>/bin/claude-wrapper` (`.exe` on Windows).
pub fn wrapper_path(paths: &Paths) -> PathBuf { todo!() }

/// Sets (Some) or removes (None) our wrapper key in settings text. None when a foreign wrapper is set
/// and we were asked to set ours. `path` is the raw path; JSON escaping is done here.
pub fn set_wrapper(text: &str, path: Option<&str>) -> Option<String> { todo!() }

/// Applies set_wrapper to every existing settings file (backup `<file>.anchor-backup` once).
/// Err is a user-facing message; Ok(false) when no editor settings exist.
pub fn apply(on: bool, paths: &Paths) -> Result<bool, String> { todo!() }
