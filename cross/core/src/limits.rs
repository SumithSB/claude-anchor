//! Live rate limits from api.anthropic.com/api/oauth/usage with the CLI's own token (never refreshed).
//! Port of Limits.swift `fetchLimits`, `parseLimits`, fresh/overflow evaluation.

use crate::model::{Account, Config, Limits};
use crate::paths::Paths;
use std::collections::HashMap;

pub const OFFLINE_NOTE: &str = "Couldn't reach Anthropic. Showing the last known usage.";

pub fn parse_limits(v: &serde_json::Value, fetched_at: i64, stale: bool) -> Limits { todo!() }

/// Blocking fetch for one account (20 s timeout). Falls back to `previous` or cachedUsageUtilization.
pub fn fetch(a: &Account, paths: &Paths, previous: Option<&Limits>) -> Limits { todo!() }

/// Fetches every non-pending account in parallel.
pub fn fetch_all(cfg: &Config, paths: &Paths, previous: &HashMap<String, Limits>) -> HashMap<String, Limits> { todo!() }

/// Accounts that just became fresh (not fresh in `before`, fresh in `after`), for notifications.
pub fn newly_fresh(before: &HashMap<String, Limits>, after: &HashMap<String, Limits>) -> Vec<String> { todo!() }
