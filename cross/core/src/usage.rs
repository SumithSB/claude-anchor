//! Incremental token/cost index over every account's transcripts. Port of Usage.swift `UsageIndex`.

use crate::model::Account;
use serde::Serialize;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GroupBy { Account, Project, Model }

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct UsageRow {
    pub id: String,                 // group key (account id / cwd / model)
    pub label: String,              // account name, "~/code/website", "Opus 5.5"
    #[serde(rename = "accountID")]
    pub account_id: Option<String>, // set when grouping by account
    pub tokens: u64,                // input + output + cache read + cache write
    #[serde(rename = "outputTokens")]
    pub output_tokens: u64,
    pub cost: f64,                  // estimated USD
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct LastSession {
    pub cwd: String,
    #[serde(rename = "accountID")]
    pub account_id: String,
    pub file: Option<String>,
}

pub struct UsageIndex { /* private: store path, Mutex<State> */ }

impl UsageIndex {
    /// Loads state from `store` (usage.json); `ledger` is the `copied` file written by sync.
    pub fn open(store: PathBuf, ledger: PathBuf) -> Self { todo!() }
    /// Reads new lines of every `<dir>/projects/**/*.jsonl`, persists. Err = user-facing persist error.
    pub fn scan(&self, accounts: &[Account]) -> Result<(), String> { todo!() }
    pub fn rows(&self, by: GroupBy, days: u32, accounts: &[Account], removed: &BTreeMap<String, String>, home: &Path) -> Vec<UsageRow> { todo!() }
    pub fn last_session(&self) -> Option<LastSession> { todo!() }
    /// Marks a copied transcript as already read, so its history never counts again.
    pub fn mark_copied(&self, path: &Path) { todo!() }
    pub fn price(model: &str) -> (f64, f64) { todo!() }
    pub fn pretty_model(id: &str) -> String { todo!() }
}
