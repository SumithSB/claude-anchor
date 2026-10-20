//! `anchor exec -- claude …` and the editor wrapper: pick the account for the cwd, share the folder's
//! conversations, then run the program. Port of anchor.zsh `claude()` and the zsh editor wrapper.

use crate::{paths::Paths, routes, sync};
use std::ffi::{OsStr, OsString};
use std::process::Command;

type Envs = Vec<(&'static str, Option<OsString>)>;

fn set(name: &str) -> bool { std::env::var_os(name).is_some_and(|v| !v.is_empty()) }

/// Env changes for the cwd's account; empty when routing is bypassed or nothing matches.
fn route(paths: &Paths) -> Envs {
    if set("CLAUDE_ANCHOR_OFF") || set("CLAUDE_CONFIG_DIR") { return vec![]; }
    let Ok(text) = std::fs::read_to_string(paths.routes()) else { return vec![] };
    let Ok(cwd) = std::env::current_dir() else { return vec![] };
    let Some(dir) = routes::resolve(&text, &cwd.to_string_lossy()) else { return vec![] };
    if !set("CLAUDE_ANCHOR_NO_SYNC") { sync::sync_project(&cwd, &sync::account_dirs(paths), &paths.copied()); }
    if paths.is_primary(&dir) {
        vec![("CLAUDE_CONFIG_DIR", None), ("CLAUDE_ANCHOR_ACCOUNT", Some("primary".into()))]
    } else {
        let id = std::path::Path::new(&dir).file_name().unwrap_or_default().to_os_string();
        vec![("CLAUDE_CONFIG_DIR", Some(dir.into())), ("CLAUDE_ANCHOR_ACCOUNT", Some(id))]
    }
}

/// `/D` keeps cmd from running AutoRun, where the cmd.exe hook lives.
fn command(prog: &OsStr, rest: &[OsString], envs: &Envs) -> Command {
    let ext = std::path::Path::new(prog).extension().and_then(|e| e.to_str()).unwrap_or("").to_lowercase();
    let mut c = if cfg!(windows) && (ext == "cmd" || ext == "bat") { let mut c = Command::new("cmd"); c.arg("/D").arg("/C").arg(prog); c } else { Command::new(prog) };
    c.args(rest);
    for (k, v) in envs { match v { Some(v) => { c.env(k, v); } None => { c.env_remove(k); } } }
    c
}

/// Runs `args[0]` with `args[1..]` routed for the current folder. Returns the exit code
/// (on Unix it replaces the process and only returns on failure).
pub fn run(args: Vec<OsString>) -> i32 {
    let Some((prog, rest)) = args.split_first() else {
        eprintln!("anchor: usage: anchor exec -- <program> [args…]");
        return 2;
    };
    let paths = Paths::get();
    let envs = route(&paths);
    launch(&paths, prog, rest, &envs)
}

#[cfg(unix)]
fn launch(_: &Paths, prog: &OsStr, rest: &[OsString], envs: &Envs) -> i32 {
    use std::os::unix::process::CommandExt;
    let e = command(prog, rest, envs).exec();
    eprintln!("anchor: couldn't run {}: {e}", prog.to_string_lossy());
    127
}

#[cfg(windows)]
fn launch(paths: &Paths, prog: &OsStr, rest: &[OsString], envs: &Envs) -> i32 {
    // The child owns Ctrl+C; we only wait for it.
    unsafe { windows_sys::Win32::System::Console::SetConsoleCtrlHandler(None, 1); }
    let mut res = command(prog, rest, envs).spawn();
    if matches!(&res, Err(e) if e.kind() == std::io::ErrorKind::NotFound)
        && std::path::Path::new(prog).file_stem().is_some_and(|s| s.eq_ignore_ascii_case("claude")) {
        if let Some(p) = crate::accounts::claude_path(paths) { res = command(p.as_os_str(), rest, envs).spawn(); }
    }
    match res.and_then(|mut c| c.wait()) {
        Ok(s) => s.code().unwrap_or(1),
        Err(e) => { eprintln!("anchor: couldn't run {}: {e}", prog.to_string_lossy()); 127 }
    }
}
