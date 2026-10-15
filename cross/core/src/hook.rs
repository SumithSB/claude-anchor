//! Installs the `anchor` binary, the editor wrapper and the shell hook line (bash/zsh rc, PowerShell profile).

use crate::paths::Paths;
use std::path::PathBuf;

pub const MARK: &str = "# claude-anchor";

/// Copies the running executable to `<anchor>/bin/anchor[.exe]` and `<anchor>/bin/claude-wrapper[.exe]`.
pub fn install_binaries(paths: &Paths) -> Result<(), String> { todo!() }
/// Adds the hook line to every rc/profile file; returns the files changed.
pub fn install_hook(paths: &Paths) -> Result<Vec<PathBuf>, String> { todo!() }
/// Removes hook lines; returns the files changed.
pub fn uninstall_hook(paths: &Paths) -> Result<Vec<PathBuf>, String> { todo!() }
