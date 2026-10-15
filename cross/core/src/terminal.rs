//! Opens a terminal that resumes a conversation. Replaces the macOS osascript → Terminal step.

use std::path::Path;

/// POSIX single-quote escaping.
pub fn sh_quote(s: &str) -> String { format!("'{}'", s.replace('\'', "'\\''")) }

/// PowerShell single-quote escaping.
pub fn ps_quote(s: &str) -> String { format!("'{}'", s.replace('\'', "''")) }

/// Shell command for bash/zsh. Primary unsets CLAUDE_CONFIG_DIR instead of using `env -u` (works in any shell).
pub fn sh_command(cwd: &str, config_dir: Option<&str>, account_id: &str, session_id: &str) -> String {
    let env = match config_dir {
        Some(d) => format!("CLAUDE_CONFIG_DIR={} CLAUDE_ANCHOR_ACCOUNT={} ", sh_quote(d), sh_quote(account_id)),
        None => "unset CLAUDE_CONFIG_DIR && CLAUDE_ANCHOR_ACCOUNT=primary ".into(),
    };
    format!("cd {} && {env}claude --resume {}", sh_quote(cwd), sh_quote(session_id))
}

/// PowerShell command text.
pub fn ps_command(cwd: &str, config_dir: Option<&str>, account_id: &str, session_id: &str) -> String {
    let dir = match config_dir {
        Some(d) => format!("$env:CLAUDE_CONFIG_DIR={}", ps_quote(d)),
        None => "Remove-Item Env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue".into(),
    };
    let id = if config_dir.is_some() { account_id } else { "primary" };
    format!("Set-Location -LiteralPath {}; {dir}; $env:CLAUDE_ANCHOR_ACCOUNT={}; claude --resume {}", ps_quote(cwd), ps_quote(id), ps_quote(session_id))
}

/// Opens a new terminal window running `claude --resume <session_id>` in `cwd`, with CLAUDE_CONFIG_DIR set
/// to `config_dir` (None = primary, variable unset). `session_id` must already be validated as a UUID.
/// Err is a user-facing message.
pub fn open_resume(cwd: &Path, config_dir: Option<&str>, account_id: &str, session_id: &str) -> Result<(), String> {
    launch(&cwd.to_string_lossy(), config_dir, account_id, session_id)
}

#[cfg(windows)]
fn launch(cwd: &str, config_dir: Option<&str>, account_id: &str, sid: &str) -> Result<(), String> {
    use std::os::windows::process::CommandExt;
    use std::process::{Command, Stdio};
    let cmd = ps_command(cwd, config_dir, account_id, sid);
    let quiet = |c: &mut Command| { c.stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()); };
    let mut wt = Command::new("wt.exe");
    wt.args(["-d", cwd, "powershell", "-NoExit", "-Command", &cmd]);
    quiet(&mut wt);
    if wt.spawn().is_ok() { return Ok(()); }
    let mut ps = Command::new("powershell");
    ps.args(["-NoExit", "-Command", &cmd]).creation_flags(0x10); // CREATE_NEW_CONSOLE
    quiet(&mut ps);
    ps.spawn().map(|_| ()).map_err(|_| "Couldn't open a terminal. Check that PowerShell is installed, then try again.".into())
}

#[cfg(target_os = "macos")]
fn launch(cwd: &str, config_dir: Option<&str>, account_id: &str, sid: &str) -> Result<(), String> {
    let cmd = sh_command(cwd, config_dir, account_id, sid).replace('\\', "\\\\").replace('"', "\\\"");
    let ok = std::process::Command::new("/usr/bin/osascript")
        .args(["-e", &format!("tell application \"Terminal\" to do script \"{cmd}\""), "-e", "tell application \"Terminal\" to activate"])
        .stdout(std::process::Stdio::null()).stderr(std::process::Stdio::null()).status().is_ok_and(|s| s.success());
    if ok { Ok(()) } else {
        Err("Couldn't open Terminal. Allow Claude Anchor to control Terminal in System Settings > Privacy & Security > Automation, then try again.".into())
    }
}

#[cfg(all(unix, not(target_os = "macos")))]
fn launch(cwd: &str, config_dir: Option<&str>, account_id: &str, sid: &str) -> Result<(), String> {
    use std::process::{Command, Stdio};
    let script = format!("{}; exec bash", sh_command(cwd, config_dir, account_id, sid));
    let env_term = std::env::var("TERMINAL").ok().filter(|t| !t.is_empty());
    let mut list: Vec<(String, &[&str])> = env_term.into_iter().map(|t| (t, &["-e"][..])).collect();
    list.extend([("x-terminal-emulator", &["-e"][..]), ("gnome-terminal", &["--"]), ("konsole", &["-e"]), ("xfce4-terminal", &["-x"]),
        ("kitty", &[]), ("alacritty", &["-e"]), ("wezterm", &["start", "--"]), ("xterm", &["-e"])].map(|(p, a)| (p.to_string(), a)));
    for (prog, args) in list {
        let ok = Command::new(&prog).args(args).args(["bash", "-lc", &script]).current_dir(cwd)
            .stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).spawn().is_ok();
        if ok { return Ok(()); }
    }
    Err("Couldn't find a terminal to open. Set the TERMINAL environment variable to your terminal, then try again.".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn posix_quoting() {
        assert_eq!(sh_quote("a b"), "'a b'");
        assert_eq!(sh_quote("it's"), r"'it'\''s'");
        assert_eq!(
            sh_command("/p/my dir", Some("/a/b"), "work", "sid"),
            "cd '/p/my dir' && CLAUDE_CONFIG_DIR='/a/b' CLAUDE_ANCHOR_ACCOUNT='work' claude --resume 'sid'");
        assert_eq!(
            sh_command("/o'k", None, "primary", "sid"),
            r"cd '/o'\''k' && unset CLAUDE_CONFIG_DIR && CLAUDE_ANCHOR_ACCOUNT=primary claude --resume 'sid'");
    }

    #[test]
    fn powershell_quoting() {
        assert_eq!(ps_quote("O'Brien"), "'O''Brien'");
        assert_eq!(
            ps_command(r"C:\My Dir\it's", Some(r"C:\a b\acc"), "work", "sid"),
            r"Set-Location -LiteralPath 'C:\My Dir\it''s'; $env:CLAUDE_CONFIG_DIR='C:\a b\acc'; $env:CLAUDE_ANCHOR_ACCOUNT='work'; claude --resume 'sid'");
        assert_eq!(
            ps_command(r"C:\p", None, "x", "sid"),
            r"Set-Location -LiteralPath 'C:\p'; Remove-Item Env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue; $env:CLAUDE_ANCHOR_ACCOUNT='primary'; claude --resume 'sid'");
    }
}
