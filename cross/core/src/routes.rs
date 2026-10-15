//! Routes file (`~/.claude-anchor/routes`) and folder → account resolution. Port of Store.swift
//! `routesText` and shell/anchor.zsh `_anchor_resolve`. Also Claude Code's project folder naming.

use crate::model::{Config, Limits};
use crate::paths::Paths;
use std::collections::HashMap;

/// Routes text: rules longest path first, then `default\t<dir or ->`. A rule with allowOverflow whose
/// account is at/over the threshold routes to the default account instead.
pub fn routes_text(cfg: &Config, limits: &HashMap<String, Limits>, paths: &Paths) -> String { todo!() }

/// Writes routes_text to paths.routes() (private dir, 0600, atomic).
pub fn write_routes(cfg: &Config, limits: &HashMap<String, Limits>, paths: &Paths) -> std::io::Result<()> { todo!() }

/// Config dir for `dir` from routes text: None = primary ("-"), Some(config dir) otherwise.
pub fn resolve(routes: &str, dir: &str) -> Option<String> { todo!() }

/// Claude Code's folder name under `<config>/projects/` for a cwd.
pub fn project_slug(cwd: &str) -> String { todo!() }

/// Normalises a folder for a rule; Err is a user-facing message.
pub fn normalize_rule_path(path: &str) -> Result<String, String> { todo!() }
