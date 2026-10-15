//! Where things live. Built from a home folder so tests can point it at a temp dir.

use std::path::{Path, PathBuf};

#[derive(Clone, Debug)]
pub struct Paths {
    pub home: PathBuf,
    pub primary_dir: PathBuf, // ~/.claude, the account that never sets CLAUDE_CONFIG_DIR
    pub anchor: PathBuf,      // ~/.claude-anchor (or $CLAUDE_ANCHOR_HOME)
}

impl Paths {
    pub fn from_home(home: impl Into<PathBuf>) -> Self {
        let home = home.into();
        Paths { primary_dir: home.join(".claude"), anchor: home.join(".claude-anchor"), home }
    }

    /// Real locations. $CLAUDE_ANCHOR_HOME overrides the anchor folder, like the shell hook.
    pub fn get() -> Self {
        let mut p = Self::from_home(dirs::home_dir().expect("no home folder"));
        if let Some(h) = std::env::var_os("CLAUDE_ANCHOR_HOME").filter(|h| !h.is_empty()) { p.anchor = h.into(); }
        p
    }

    pub fn accounts(&self) -> PathBuf { self.anchor.join("accounts") }
    pub fn config(&self) -> PathBuf { self.anchor.join("config.json") }
    pub fn routes(&self) -> PathBuf {
        std::env::var_os("CLAUDE_ANCHOR_ROUTES").filter(|r| !r.is_empty()).map(PathBuf::from)
            .unwrap_or_else(|| self.anchor.join("routes"))
    }
    pub fn usage(&self) -> PathBuf { self.anchor.join("usage.json") }
    /// Ledger of transcripts copied between accounts: `<path>\t<copied size>` per line.
    pub fn copied(&self) -> PathBuf { self.anchor.join("copied") }
    pub fn bin(&self) -> PathBuf { self.anchor.join("bin") }

    /// Is `dir` the primary account's config dir?
    pub fn is_primary(&self, dir: &str) -> bool { same_path(Path::new(dir), &self.primary_dir) }
}

/// Path equality; case-insensitive on Windows.
pub fn same_path(a: &Path, b: &Path) -> bool {
    if cfg!(windows) {
        a.to_string_lossy().replace('/', "\\").trim_end_matches('\\').to_lowercase()
            == b.to_string_lossy().replace('/', "\\").trim_end_matches('\\').to_lowercase()
    } else {
        a == b
    }
}

/// `~/x` for display.
pub fn abbreviate(p: &Path, home: &Path) -> String {
    match p.strip_prefix(home) {
        Ok(rest) if rest.as_os_str().is_empty() => "~".into(),
        Ok(rest) => format!("~{}{}", std::path::MAIN_SEPARATOR, rest.display()),
        Err(_) => p.display().to_string(),
    }
}
