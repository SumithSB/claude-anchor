//! Sharing conversations between accounts. Port of anchor.zsh `_anchor_sync` and Store.swift `copyTranscript`.

use std::path::{Path, PathBuf};

/// Before claude starts in `cwd`: for each transcript of this project in any of `dirs`, copy the largest
/// copy over smaller ones that are an exact prefix of it (diverged copies left alone). Logs to `ledger`.
pub fn sync_project(cwd: &Path, dirs: &[PathBuf], ledger: &Path) { todo!() }

/// Account config dirs: primary + every folder in `<anchor>/accounts`.
pub fn account_dirs(paths: &crate::paths::Paths) -> Vec<PathBuf> { todo!() }

/// Copies a transcript and its sibling session folder into `target_dir/projects/<same slug>/`.
/// Returns every copied .jsonl path.
pub fn copy_transcript(file: &Path, target_dir: &Path) -> std::io::Result<Vec<PathBuf>> { todo!() }
