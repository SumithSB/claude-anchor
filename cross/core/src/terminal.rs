//! Opens a terminal that resumes a conversation. Replaces the macOS osascript → Terminal step.

use std::path::Path;

/// Opens a new terminal window running `claude --resume <session_id>` in `cwd`, with CLAUDE_CONFIG_DIR set
/// to `config_dir` (None = primary, variable unset). `session_id` must already be validated as a UUID.
/// Err is a user-facing message.
pub fn open_resume(cwd: &Path, config_dir: Option<&str>, account_id: &str, session_id: &str) -> Result<(), String> { todo!() }
