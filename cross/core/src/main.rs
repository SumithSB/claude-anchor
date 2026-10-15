use anchor_core::accounts::{self, Store};
use anchor_core::model::Limits;
use anchor_core::paths::{abbreviate, Paths};
use anchor_core::usage::{GroupBy, UsageIndex};
use anchor_core::{editor, exec, hook, limits, routes};
use std::ffi::OsString;
use std::path::Path;

const USAGE: &str = "Claude Anchor: routes Claude Code to the right account per folder.

  anchor exec -- <program> [args...]    run a program routed for the current folder
  anchor which [dir]                    config dir used for a folder
  anchor status                         accounts, rules and limits
  anchor limits [--json]                5-hour and weekly limits
  anchor usage [--by account|project|model] [--days N]
  anchor account list | add <name> | login <id> | remove <id> [--to <id>] | rename <id> <name>
  anchor default <id>
  anchor rule list | add <folder> <account> [--overflow] | remove <folder>
  anchor editor on|off                  VS Code / Cursor integration
  anchor continue <account>             continue the last conversation on another account
  anchor install | uninstall            shell hook, binaries, editor integration";

type R = Result<(), String>;

fn main() {
    let args: Vec<OsString> = std::env::args_os().collect();
    let stem = args.first().and_then(|a| Path::new(a).file_stem()).map(|s| s.to_string_lossy().to_lowercase());
    if stem.as_deref() == Some("claude-wrapper") { std::process::exit(exec::run(args[1..].to_vec())); }
    if args.get(1).is_some_and(|a| a == "exec") {
        let skip = if args.get(2).is_some_and(|a| a == "--") { 3 } else { 2 };
        std::process::exit(exec::run(args.get(skip..).unwrap_or_default().to_vec()));
    }
    let args: Vec<String> = args[1..].iter().map(|a| a.to_string_lossy().into_owned()).collect();
    if let Err(e) = run(&args) {
        eprintln!("anchor: {e}");
        std::process::exit(1);
    }
}

fn load() -> Store {
    let (s, banner) = Store::load(Paths::get());
    if let Some(b) = banner { eprintln!("{b}"); }
    s
}

fn run(args: &[String]) -> R {
    let a: Vec<&str> = args.iter().map(String::as_str).collect();
    match a.as_slice() {
        [] | ["help" | "--help" | "-h"] => println!("{USAGE}"),
        ["--version" | "-V" | "version"] => println!("anchor {}", env!("CARGO_PKG_VERSION")),
        ["which"] => which(None),
        ["which", dir] => which(Some(dir)),
        ["status"] => status()?,
        ["limits"] => limits_cmd(false),
        ["limits", "--json"] => limits_cmd(true),
        ["usage", rest @ ..] => usage(rest)?,
        ["account", "list"] => account_list(),
        ["account", "add", name] => account_add(name)?,
        ["account", "login", id] => sign_in(&mut load(), id)?,
        ["account", "remove", id] => remove_account(id, None)?,
        ["account", "remove", id, "--to", to] => remove_account(id, Some(to))?,
        ["account", "rename", id, name] => load().rename(id, name)?,
        ["default", id] => load().set_default(id)?,
        ["rule", "list"] => rule_list(),
        ["rule", "add", folder, acct] => load().add_rule(folder, acct)?,
        ["rule", "add", folder, acct, "--overflow"] => {
            let mut s = load();
            s.add_rule(folder, acct)?;
            s.set_rule_overflow(&routes::normalize_rule_path(folder)?, true)?;
        }
        ["rule", "remove", folder] => {
            let mut s = load();
            let p = routes::normalize_rule_path(folder).unwrap_or_else(|_| folder.to_string());
            s.remove_rule(&p)?;
        }
        ["editor", on @ ("on" | "off")] => load().set_editor_integration(*on == "on")?,
        ["continue", target] => continue_on(target)?,
        ["install"] => install()?,
        ["uninstall"] => uninstall()?,
        _ => return Err(format!("unknown command `{}`. Try `anchor help`.", a.join(" "))),
    }
    Ok(())
}

fn which(dir: Option<&str>) {
    let paths = Paths::get();
    let cwd = match dir {
        Some(d) => std::path::absolute(d).unwrap_or_else(|_| d.into()),
        None => std::env::current_dir().unwrap_or_default(),
    };
    let text = std::fs::read_to_string(paths.routes()).unwrap_or_default();
    let found = routes::resolve(&text, &cwd.to_string_lossy());
    println!("{}", found.unwrap_or_else(|| paths.primary_dir.display().to_string()));
}

fn window(w: &Option<anchor_core::model::LimitWindow>) -> String {
    w.as_ref().map_or("-".into(), |w| format!("{:.0}%", w.percent))
}

fn limit_text(l: Option<&Limits>) -> String {
    match l {
        None => "-".into(),
        Some(l) if l.needs_sign_in => "needs sign-in".into(),
        Some(l) if l.error.is_some() => l.error.clone().unwrap_or_default(),
        Some(l) => format!("5h {} · weekly {}{}", window(&l.five_hour), window(&l.weekly), if l.stale { " (stale)" } else { "" }),
    }
}

fn status() -> R {
    let s = load();
    let lims = limits::fetch_all(&s.config, &s.paths, &s.limits);
    for a in &s.config.accounts {
        println!("{}  {:<14} {:<28} {:<8} {}", a.flag, a.name, a.email.as_deref().unwrap_or("-"),
            if a.id == s.config.default_id { "default" } else { "" },
            if a.pending { "pending sign-in".to_string() } else { limit_text(lims.get(&a.id)) });
    }
    println!("\n{} rule(s), routes file: {}", s.config.rules.len(), s.paths.routes().display());
    Ok(())
}

fn limits_cmd(json: bool) {
    let s = load();
    let lims = limits::fetch_all(&s.config, &s.paths, &s.limits);
    if json {
        let sorted: std::collections::BTreeMap<_, _> = lims.iter().collect();
        println!("{}", serde_json::to_string_pretty(&sorted).unwrap_or_default());
    } else {
        for a in s.config.accounts.iter().filter(|a| !a.pending) {
            println!("{:<14} {}", a.name, limit_text(lims.get(&a.id)));
        }
    }
}

fn usage(rest: &[&str]) -> R {
    let (mut by, mut days) = (GroupBy::Account, 7u32);
    let mut it = rest.iter();
    while let Some(f) = it.next() {
        let v = it.next().ok_or(format!("{f} needs a value."))?;
        match *f {
            "--by" => by = match *v { "account" => GroupBy::Account, "project" => GroupBy::Project, "model" => GroupBy::Model,
                _ => return Err("--by takes account, project or model.".into()) },
            "--days" => days = v.parse().map_err(|_| "--days takes a number.".to_string())?,
            _ => return Err(format!("unknown option `{f}`.")),
        }
    }
    let s = load();
    let idx = UsageIndex::open(s.paths.usage(), s.paths.copied());
    idx.scan(&s.config.accounts)?;
    for r in idx.rows(by, days, &s.config.accounts, &s.config.removed_names, &s.paths.home) {
        println!("{:<40} {:>12} tokens {:>9}", r.label, r.tokens, format!("${:.2}", r.cost));
    }
    Ok(())
}

fn account_list() {
    let s = load();
    for a in &s.config.accounts {
        println!("{:<14} {}  {:<14} {:<28} {}{}", a.id, a.flag, a.name, a.email.as_deref().unwrap_or("-"),
            if a.id == s.config.default_id { "default " } else { "" }, if a.pending { "pending" } else { "" });
    }
}

fn sign_in(s: &mut Store, id: &str) -> R {
    let mut child = accounts::spawn_login(s, id)?;
    let ok = child.wait().is_ok_and(|st| st.success());
    println!("{}", s.finish_sign_in(id, ok)?);
    Ok(())
}

fn account_add(name: &str) -> R {
    let mut s = load();
    let flag = ('a'..='z').find(|c| !s.config.accounts.iter().any(|a| a.flag == c.to_string())).unwrap_or('a');
    let id = s.add_account(name, &flag.to_string())?;
    sign_in(&mut s, &id)
}

fn remove_account(id: &str, to: Option<&str>) -> R {
    let mut s = load();
    let to = to.map(String::from).unwrap_or_else(|| if s.config.default_id != id { s.config.default_id.clone() } else { "primary".into() });
    s.remove_account(id, &to)
}

fn rule_list() {
    let s = load();
    for r in &s.config.rules {
        let name = s.config.account(&r.account_id).map_or(r.account_id.as_str(), |a| a.name.as_str());
        println!("{:<50} {}{}", abbreviate(Path::new(&r.path), &s.paths.home), name, if r.allow_overflow { " (overflow)" } else { "" });
    }
}

fn continue_on(target: &str) -> R {
    let mut s = load();
    let idx = UsageIndex::open(s.paths.usage(), s.paths.copied());
    idx.scan(&s.config.accounts)?;
    let last = idx.last_session().ok_or("No recent conversation to continue.")?;
    println!("{}", s.continue_session(&last, target, &idx)?);
    Ok(())
}

fn install() -> R {
    let mut s = load();
    let me = std::env::current_exe().map_err(|e| format!("Couldn't find this program: {e}."))?;
    hook::install_binaries(&s.paths, &me)?;
    println!("Installed {}", s.paths.bin().display());
    let changed = hook::install_hook(&s.paths)?;
    if changed.is_empty() { println!("Shell hook already in place."); }
    for f in changed { println!("Added the hook to {}", f.display()); }
    if editor::settings_files(&s.paths).iter().any(|f| f.exists()) {
        s.set_editor_integration(true)?;
        println!("Editor integration on.");
    }
    println!("Open a new terminal for `claude` to be routed.");
    Ok(())
}

fn uninstall() -> R {
    let mut s = load();
    for f in hook::uninstall_hook(&s.paths)? { println!("Removed the hook from {}", f.display()); }
    if s.set_editor_integration(false).is_ok() { println!("Editor integration off."); }
    println!("Left {} in place; delete it to remove your accounts and settings.", s.paths.anchor.display());
    Ok(())
}
