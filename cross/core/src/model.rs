//! Shared types. JSON shape matches the Swift app's config.json (Sources/Anchor/Models.swift),
//! so a config can be read by either app. Every field but `accounts` is optional on read.

use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Account {
    pub id: String, // slug, stable; "primary" for the account that never sets CLAUDE_CONFIG_DIR
    pub name: String,
    pub flag: String, // signal flag letter "a".."z"
    pub dir: String,  // absolute config dir; == Paths::primary_dir for the primary account
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub email: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub plan: Option<String>,
    #[serde(default)]
    pub pending: bool, // created, sign-in not finished
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Rule {
    pub path: String, // absolute folder prefix, no trailing separator
    #[serde(rename = "accountID")]
    pub account_id: String,
    #[serde(default, rename = "allowOverflow")]
    pub allow_overflow: bool,
}

fn d_primary() -> String { "primary".into() }
fn d_90() -> f64 { 90.0 }
fn d_true() -> bool { true }
fn d_300() -> i64 { 300 }

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Config {
    pub accounts: Vec<Account>,
    #[serde(default)]
    pub rules: Vec<Rule>,
    #[serde(default = "d_primary", rename = "defaultID")]
    pub default_id: String,
    #[serde(default = "d_90", rename = "overflowThreshold")]
    pub overflow_threshold: f64, // percent
    #[serde(default = "d_true", rename = "autoOverflow")]
    pub auto_overflow: bool,
    #[serde(default)]
    pub bell: bool,
    #[serde(default, rename = "editorIntegration", skip_serializing_if = "Option::is_none")]
    pub editor_integration: Option<bool>,
    #[serde(default, rename = "removedNames")]
    pub removed_names: std::collections::BTreeMap<String, String>,
    #[serde(default = "d_300", rename = "refreshSeconds")]
    pub refresh_seconds: i64, // 0 = manual only
    #[serde(default = "d_true", rename = "notifyFresh")]
    pub notify_fresh: bool,
    #[serde(default = "d_true", rename = "floatingButton")]
    pub floating_button: bool,
    #[serde(default = "d_true", rename = "floatingSnap")]
    pub floating_snap: bool,
    #[serde(default, rename = "floatingFade")]
    pub floating_fade: bool,
    #[serde(default = "d_true", rename = "floatingAllSpaces")]
    pub floating_all_spaces: bool,
    #[serde(default, rename = "showAPIPrices", skip_serializing_if = "Option::is_none")]
    pub show_api_prices: Option<bool>, // None = on unless every account is on a flat-fee plan
    #[serde(default, rename = "floatingX", skip_serializing_if = "Option::is_none")]
    pub floating_x: Option<f64>,
    #[serde(default, rename = "floatingY", skip_serializing_if = "Option::is_none")]
    pub floating_y: Option<f64>,
}

impl Default for Config {
    fn default() -> Self {
        serde_json::from_str(r#"{"accounts":[]}"#).expect("defaults")
    }
}

impl Config {
    pub fn account(&self, id: &str) -> Option<&Account> { self.accounts.iter().find(|a| a.id == id) }
    /// The default account, or the first one when the default points nowhere.
    pub fn active(&self) -> Option<&Account> { self.account(&self.default_id).or(self.accounts.first()) }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct LimitWindow {
    pub percent: f64, // 0..=100
    #[serde(default, rename = "resetsAt", skip_serializing_if = "Option::is_none")]
    pub resets_at: Option<String>, // RFC 3339, as Anthropic sent it
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Limits {
    #[serde(default, rename = "fiveHour")]
    pub five_hour: Option<LimitWindow>,
    #[serde(default)]
    pub weekly: Option<LimitWindow>,
    #[serde(rename = "fetchedAt")]
    pub fetched_at: i64, // unix seconds
    #[serde(default)]
    pub stale: bool, // came from cachedUsageUtilization or a previous fetch, not live
    #[serde(default)]
    pub error: Option<String>, // user-facing, e.g. "Work's sign-in expired. Sign in again."
    #[serde(default, rename = "needsSignIn")]
    pub needs_sign_in: bool,
    #[serde(default)]
    pub note: Option<String>, // soft warning, e.g. offline
}

impl Limits {
    /// A full, unused 5h window: fetched live and OK, and nothing counted in it.
    pub fn is_fresh(&self) -> bool {
        if self.error.is_some() || self.stale { return false; }
        match &self.five_hour { Some(f) => f.percent < 1.0, None => self.weekly.is_some() }
    }
    pub fn peak(&self) -> f64 {
        self.five_hour.as_ref().map_or(0.0, |w| w.percent).max(self.weekly.as_ref().map_or(0.0, |w| w.percent))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_swift_config() {
        let c: Config = serde_json::from_str(r#"{"accounts":[{"id":"primary","name":"Personal","flag":"a","dir":"/h/.claude","pending":false}],
            "rules":[{"path":"/w","accountID":"work","allowOverflow":true}],"defaultID":"work","overflowThreshold":85}"#).unwrap();
        assert_eq!(c.default_id, "work");
        assert_eq!(c.rules[0].account_id, "work");
        assert!(c.rules[0].allow_overflow && c.auto_overflow && c.floating_button);
        assert_eq!(c.refresh_seconds, 300);
        assert!(serde_json::from_str::<Config>("{}").is_err(), "accounts is required");
        let back = serde_json::to_string(&c).unwrap();
        assert!(back.contains("\"defaultID\"") && back.contains("\"accountID\""));
    }
}
