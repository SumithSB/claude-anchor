use std::path::Path;
use std::process::{Command, Output};

fn anchor(home: &Path, cwd: &Path, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_anchor"))
        .args(args)
        .current_dir(cwd)
        .env("HOME", home)
        .env("USERPROFILE", home)
        .env("CLAUDE_ANCHOR_HOME", home.join(".claude-anchor"))
        .env("CLAUDE_ANCHOR_ROUTES", home.join(".claude-anchor").join("routes"))
        .env_remove("CLAUDE_CONFIG_DIR")
        .env_remove("CLAUDE_ANCHOR_OFF")
        .output()
        .unwrap()
}

fn out(o: &Output) -> String { String::from_utf8_lossy(&o.stdout).trim().to_string() }

#[test]
fn rule_which_and_exec_route_end_to_end() {
    let t = tempfile::tempdir().unwrap();
    let home = t.path().canonicalize().unwrap();
    let work = home.join("work");
    std::fs::create_dir_all(work.join("sub")).unwrap();
    let anchor_home = home.join(".claude-anchor");
    let wdir = anchor_home.join("accounts").join("work");
    std::fs::create_dir_all(&wdir).unwrap();
    let acct = |id: &str, name: &str, flag: &str, dir: &Path| serde_json::json!(
        {"id": id, "name": name, "flag": flag, "dir": dir, "pending": false});
    let cfg = serde_json::json!({"accounts": [acct("primary", "Personal", "a", &home.join(".claude")), acct("work", "Work", "b", &wdir)]});
    std::fs::write(anchor_home.join("config.json"), cfg.to_string()).unwrap();

    let o = anchor(&home, &home, &["rule", "add", work.to_str().unwrap(), "work"]);
    assert!(o.status.success(), "{}", String::from_utf8_lossy(&o.stderr));

    let o = anchor(&home, &home, &["which", work.join("sub").to_str().unwrap()]);
    assert_eq!(out(&o), wdir.to_str().unwrap());
    // Windows takes the home folder from the known-folder API, not USERPROFILE, so primary isn't the temp home there.
    if cfg!(unix) {
        let o = anchor(&home, &home, &["which", home.to_str().unwrap()]);
        assert_eq!(out(&o), home.join(".claude").to_str().unwrap());
    }

    let o = if cfg!(windows) {
        anchor(&home, &work, &["exec", "--", "cmd", "/C", "echo %CLAUDE_CONFIG_DIR%"])
    } else {
        anchor(&home, &work, &["exec", "--", "sh", "-c", "echo $CLAUDE_CONFIG_DIR $CLAUDE_ANCHOR_ACCOUNT"])
    };
    assert!(out(&o).starts_with(wdir.to_str().unwrap()), "{o:?}");
    if cfg!(unix) { assert!(out(&o).ends_with(" work")); }

    let o = anchor(&home, &work, &["exec", "--", "no-such-program-xyz"]);
    assert_eq!(o.status.code(), Some(127));
}
