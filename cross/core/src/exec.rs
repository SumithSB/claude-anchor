//! `anchor exec -- claude …` and the editor wrapper: pick the account for the cwd, share the folder's
//! conversations, then run the program. Port of anchor.zsh `claude()` and the zsh editor wrapper.

use std::ffi::OsString;

/// Runs `args[0]` with `args[1..]` routed for the current folder. Returns the exit code
/// (on Unix it replaces the process and only returns on failure).
pub fn run(args: Vec<OsString>) -> i32 { todo!() }
