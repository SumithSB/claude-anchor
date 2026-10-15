//! Claude Anchor tray app (Windows, Linux; also runs on macOS for development). Thin layer over anchor-core:
//! one shared state, commands that return the new `State` JSON, and an event after every change.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod shell;

use anchor_core::{accounts, editor, hook, limits, model::Limits, paths::Paths, usage::{GroupBy, UsageIndex}};
use anchor_core::accounts::Store;
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::process::Child;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering::SeqCst};
use std::sync::{mpsc, Arc, Mutex};
use std::thread::{sleep, spawn};
use std::time::{Duration, Instant};
use tauri::{AppHandle, Emitter, Manager};
use tauri_plugin_autostart::ManagerExt as _;
use tauri_plugin_dialog::DialogExt as _;
use tauri_plugin_notification::NotificationExt as _;

struct Login { child: Mutex<Child>, cancelled: AtomicBool }

struct Inner {
    store: Store,
    usage: Arc<UsageIndex>,
    group_by: GroupBy,
    range_days: u32,
    overflow_suggestion: Option<String>,
    banner: Option<String>,
    signing_in: HashMap<String, Arc<Login>>,
    is_refreshing: bool,
    last_refreshed: Option<i64>,
    fresh_notified: HashSet<String>,
    last_move: Option<Instant>, // last automatic default switch (10 minute throttle)
    pinned: bool,
    last_hide: Option<Instant>,
    watcher: Option<notify::RecommendedWatcher>,
    wtx: mpsc::Sender<()>,
}

static TIMER_GEN: AtomicU64 = AtomicU64::new(0);
static DIALOG_OPEN: AtomicBool = AtomicBool::new(false);

fn with<R>(app: &AppHandle, f: impl FnOnce(&mut Inner) -> R) -> R {
    let s = app.state::<Mutex<Inner>>();
    let mut g = s.lock().unwrap_or_else(|e| e.into_inner());
    f(&mut g)
}

/// Builds the contract's `State`, emits it to every window and refreshes the tray.
fn push(app: &AppHandle, g: &Inner) -> Value {
    let by = match g.group_by { GroupBy::Account => "account", GroupBy::Project => "project", GroupBy::Model => "model" };
    let c = &g.store.config;
    let mut signing: Vec<_> = g.signing_in.keys().collect();
    signing.sort();
    let s = json!({
        "config": c, "limits": g.store.limits,
        "usageRows": g.usage.rows(g.group_by, g.range_days, &c.accounts, &c.removed_names, &g.store.paths.home),
        "groupBy": by, "rangeDays": g.range_days, "lastSession": g.usage.last_session(),
        "overflowSuggestion": g.overflow_suggestion, "banner": g.banner, "signingIn": signing,
        "cliInstalled": accounts::claude_fast_path(&g.store.paths).is_some(),
        "isRefreshing": g.is_refreshing, "lastRefreshed": g.last_refreshed,
        "loginItem": app.autolaunch().is_enabled().unwrap_or(false),
        "wayland": shell::wayland(), "platform": std::env::consts::OS.replace("darwin", "macos"),
        "home": g.store.paths.home, "version": env!("CARGO_PKG_VERSION"), "pinned": g.pinned,
    });
    let _ = app.emit("state", &s);
    shell::update_tray(app, g, s["loginItem"].as_bool().unwrap_or(false));
    s
}

/// Runs a change under the lock; always pushes the state (it may have changed even on error).
fn run(app: &AppHandle, f: impl FnOnce(&mut Inner) -> Result<(), String>) -> Result<Value, String> {
    with(app, |g| { let r = f(g); let s = push(app, g); r.map(|_| s) })
}

fn notify(app: &AppHandle, body: &str) {
    let _ = app.notification().builder().title("Claude Anchor").body(body).show();
}

fn clamp_refresh(s: i64) -> i64 {
    if s == 0 { 0 } else if s < 0 { 300 } else { *[30, 60, 300, 900].iter().min_by_key(|c| (**c - s).abs()).unwrap_or(&300) }
}

// ---- background work ----

fn rescan(app: &AppHandle) {
    let (u, accts) = with(app, |g| (g.usage.clone(), g.store.config.accounts.clone()));
    let r = u.scan(&accts);
    with(app, |g| { if let Err(e) = r { g.banner = Some(format!("Couldn't save usage history: {e}.")); } push(app, g); });
}

fn refresh_limits(app: &AppHandle) {
    let (cfg, paths, prev) = with(app, |g| (g.store.config.clone(), g.store.paths.clone(), g.store.limits.clone()));
    let res = limits::fetch_all(&cfg, &paths, &prev);
    with(app, |g| {
        let before = g.store.limits.clone();
        let mut after = before.clone();
        after.extend(res.clone());
        after.retain(|id, _| g.store.config.account(id).is_some());
        if let Err(e) = g.store.set_limits(after) { g.banner = Some(e); }
        if res.values().any(|l| l.error.is_none()) { g.last_refreshed = Some(chrono::Utc::now().timestamp()); }
        evaluate_fresh(app, g, &before);
        evaluate_overflow(app, g);
        push(app, g);
    });
}

fn evaluate_fresh(app: &AppHandle, g: &mut Inner, before: &HashMap<String, Limits>) {
    if g.store.config.notify_fresh {
        for id in limits::newly_fresh(before, &g.store.limits).iter().filter(|id| !g.fresh_notified.contains(*id)) {
            if let Some(a) = g.store.config.account(id) { notify(app, &format!("{} has a full 5-hour window", a.name)); }
        }
    }
    for a in g.store.config.accounts.iter().filter(|a| !a.pending) {
        let Some(l) = g.store.limits.get(&a.id) else { continue };
        if l.is_fresh() { g.fresh_notified.insert(a.id.clone()); }
        else if l.error.is_none() && !l.stale { g.fresh_notified.remove(&a.id); } // a failed fetch must not re-arm the notice
    }
    let ids: HashSet<_> = g.store.config.accounts.iter().map(|a| a.id.clone()).collect();
    g.fresh_notified.retain(|id| ids.contains(id));
}

fn evaluate_overflow(app: &AppHandle, g: &mut Inner) {
    if g.last_move.is_some_and(|t| t.elapsed() < Duration::from_secs(600)) { return; }
    let last = g.usage.last_session();
    let Some(new_id) = limits::overflow_suggestion(&g.store.config, &g.store.limits, last.as_ref().map(|l| l.account_id.as_str())) else { return };
    let (Some(cur), Some(new)) = (g.store.config.active().cloned(), g.store.config.account(&new_id).cloned()) else { return };
    let l = &g.store.limits[&cur.id];
    let (five, weekly) = (l.five_hour.as_ref().map_or(0.0, |w| w.percent), l.weekly.as_ref().map_or(0.0, |w| w.percent));
    let text = format!("Switched to {}. {} hit {}% of its {} limit.", new.name, cur.name, five.max(weekly) as i64, if five >= weekly { "5h" } else { "weekly" });
    g.last_move = Some(Instant::now());
    if let Err(e) = g.store.set_default(&new.id) { g.banner = Some(e); return; }
    if last.is_some_and(|l| l.account_id == cur.id) { g.overflow_suggestion = Some(new.id); }
    notify(app, &text);
    g.banner = Some(text);
}

fn refresh_now(app: &AppHandle) {
    if !with(app, |g| !std::mem::replace(&mut g.is_refreshing, true)) { return; }
    with(app, |g| { push(app, g); });
    let a = app.clone();
    spawn(move || {
        rescan(&a);
        refresh_limits(&a);
        with(&a, |g| { g.is_refreshing = false; push(&a, g); });
    });
}

/// Watches each account's projects/ (or the account dir until it exists). Events go to the debounce thread.
fn restart_watch(g: &mut Inner) {
    use notify::{EventKind, RecursiveMode::{NonRecursive, Recursive}, Watcher};
    let tx = g.wtx.clone();
    g.watcher = None;
    let Ok(mut w) = notify::recommended_watcher(move |e: notify::Result<notify::Event>| {
        if e.is_ok_and(|e| matches!(e.kind, EventKind::Create(_) | EventKind::Modify(_) | EventKind::Remove(_))) { let _ = tx.send(()); }
    }) else { return };
    for a in &g.store.config.accounts {
        let (d, p) = (Path::new(&a.dir), Path::new(&a.dir).join("projects"));
        if p.is_dir() { let _ = w.watch(&p, Recursive); } else if d.is_dir() { let _ = w.watch(d, NonRecursive); }
    }
    g.watcher = Some(w);
}

/// (Re)arms the limits timer; 0 = manual only. A new generation retires the old thread.
fn arm_timer(app: &AppHandle, secs: i64) {
    let gen = TIMER_GEN.fetch_add(1, SeqCst) + 1;
    if secs <= 0 { return; }
    let a = app.clone();
    spawn(move || loop {
        for _ in 0..secs {
            sleep(Duration::from_secs(1));
            if TIMER_GEN.load(SeqCst) != gen { return; }
        }
        with(&a, restart_watch);
        refresh_limits(&a);
    });
}

fn start_login(app: &AppHandle, g: &mut Inner, id: &str) -> Result<(), String> {
    if g.signing_in.contains_key(id) { return Ok(()); }
    let child = accounts::spawn_login(&g.store, id)?;
    let name = g.store.config.account(id).map(|a| a.name.clone()).unwrap_or_default();
    let login = Arc::new(Login { child: Mutex::new(child), cancelled: AtomicBool::new(false) });
    g.signing_in.insert(id.into(), login.clone());
    g.banner = None;
    let (a, id) = (app.clone(), id.to_string());
    spawn(move || {
        let t0 = Instant::now();
        let mut timed_out = false;
        let ok = loop {
            match login.child.lock().unwrap_or_else(|e| e.into_inner()).try_wait() {
                Ok(None) => {}
                Ok(Some(s)) => break s.success(),
                Err(_) => break false,
            }
            if !timed_out && t0.elapsed() > Duration::from_secs(600) { // ponytail: fixed 10 min like Swift
                timed_out = true;
                let _ = login.child.lock().unwrap_or_else(|e| e.into_inner()).kill();
            }
            sleep(Duration::from_millis(500));
        };
        let finished = with(&a, |g| {
            g.signing_in.remove(&id);
            let cancelled = login.cancelled.load(SeqCst);
            if timed_out { g.banner = Some(format!("Sign-in for {name} timed out. Try again.")); }
            else if !cancelled { g.banner = Some(match g.store.finish_sign_in(&id, ok) { Ok(m) | Err(m) => m }); }
            push(&a, g);
            ok && !timed_out && !cancelled
        });
        if finished { rescan(&a); refresh_limits(&a); }
    });
    Ok(())
}

// ---- commands ----

#[tauri::command]
fn get_state(app: AppHandle) -> Value { with(&app, |g| push(&app, g)) }

#[tauri::command]
fn refresh(app: AppHandle) -> Value { refresh_now(&app); get_state(app) }

#[tauri::command]
fn set_default(app: AppHandle, id: String) -> Result<Value, String> {
    run(&app, |g| { g.overflow_suggestion = None; g.store.set_default(&id) })
}

#[tauri::command]
fn add_account(app: AppHandle, name: String, flag: String) -> Result<Value, String> {
    let a = app.clone();
    run(&app, |g| {
        let id = g.store.add_account(name.trim(), &flag)?;
        restart_watch(g);
        start_login(&a, g, &id)
    })
}

#[tauri::command]
fn sign_in(app: AppHandle, id: String) -> Result<Value, String> {
    let a = app.clone();
    run(&app, |g| start_login(&a, g, &id))
}

#[tauri::command]
fn cancel_sign_in(app: AppHandle, id: String) -> Result<Value, String> {
    run(&app, |g| {
        if let Some(l) = g.signing_in.get(&id) {
            l.cancelled.store(true, SeqCst);
            let _ = l.child.lock().unwrap_or_else(|e| e.into_inner()).kill();
        }
        Ok(())
    })
}

#[tauri::command]
fn sign_out_primary(app: AppHandle) -> Result<Value, String> {
    let a = app.clone();
    run(&app, |g| {
        let mut child = accounts::spawn_logout_primary(&g.store.paths)?;
        spawn(move || {
            let ok = child.wait().is_ok_and(|s| s.success());
            with(&a, |g| {
                if ok { g.store.limits.remove("primary"); g.store.reconcile_primary(); } else { g.banner = Some("Sign-out didn't finish. Try again.".into()); }
                push(&a, g);
            });
            rescan(&a);
        });
        Ok(())
    })
}

#[tauri::command]
fn remove_account(app: AppHandle, id: String, to: String) -> Result<Value, String> {
    run(&app, |g| {
        let r = g.store.remove_account(&id, &to);
        g.store.limits.remove(&id);
        restart_watch(g);
        r
    })
}

#[tauri::command]
fn rename_account(app: AppHandle, id: String, name: String) -> Result<Value, String> { run(&app, |g| g.store.rename(&id, name.trim())) }

#[tauri::command]
fn set_flag(app: AppHandle, id: String, flag: String) -> Result<Value, String> { run(&app, |g| g.store.set_flag(&id, &flag)) }

#[tauri::command]
fn move_account(app: AppHandle, from: usize, to: usize) -> Result<Value, String> { run(&app, |g| g.store.move_account(from, to)) }

#[tauri::command]
fn add_rule(app: AppHandle, path: String, account_id: String) -> Result<Value, String> { run(&app, |g| g.store.add_rule(&path, &account_id)) }

#[tauri::command]
fn remove_rule(app: AppHandle, path: String) -> Result<Value, String> { run(&app, |g| g.store.remove_rule(&path)) }

#[tauri::command]
fn set_rule_overflow(app: AppHandle, path: String, on: bool) -> Result<Value, String> { run(&app, |g| g.store.set_rule_overflow(&path, on)) }

#[tauri::command]
async fn pick_folder(app: AppHandle) -> Result<Option<String>, String> {
    DIALOG_OPEN.store(true, SeqCst); // the dialog steals focus; don't hide the window meanwhile
    let p = app.dialog().file().blocking_pick_folder();
    DIALOG_OPEN.store(false, SeqCst);
    Ok(p.map(|p| p.to_string()))
}

#[tauri::command]
fn set_setting(app: AppHandle, key: String, value: Value) -> Result<Value, String> {
    let r = run(&app, |g| {
        let c = &mut g.store.config;
        let b = || value.as_bool().ok_or("Expected on or off.");
        match key.as_str() {
            "refreshSeconds" => c.refresh_seconds = clamp_refresh(value.as_i64().ok_or("Expected a number.")?),
            "overflowThreshold" => c.overflow_threshold = value.as_f64().ok_or("Expected a number.")?.clamp(50.0, 100.0),
            "notifyFresh" => c.notify_fresh = b()?,
            "autoOverflow" => c.auto_overflow = b()?,
            "bell" => c.bell = b()?,
            "floatingButton" => c.floating_button = b()?,
            "floatingSnap" => c.floating_snap = b()?,
            "floatingFade" => c.floating_fade = b()?,
            _ => return Err(format!("Unknown setting {key}.")),
        }
        g.store.save()
    });
    if r.is_ok() {
        match key.as_str() {
            "refreshSeconds" => arm_timer(&app, with(&app, |g| g.store.config.refresh_seconds)),
            "floatingButton" => shell::sync_button(&app),
            _ => {}
        }
    }
    r
}

#[tauri::command]
fn set_editor_integration(app: AppHandle, on: bool) -> Result<Value, String> { run(&app, |g| g.store.set_editor_integration(on)) }

#[tauri::command]
fn set_login_item(app: AppHandle, on: bool) -> Result<Value, String> {
    let m = app.autolaunch();
    if on { m.enable() } else { m.disable() }.map_err(|e| format!("Couldn't change start at login: {e}."))?;
    Ok(get_state(app))
}

#[tauri::command]
fn set_usage_view(app: AppHandle, group_by: String, range_days: u32) -> Result<Value, String> {
    let by = match group_by.as_str() { "account" => GroupBy::Account, "project" => GroupBy::Project, "model" => GroupBy::Model, _ => return Err("Unknown grouping.".into()) };
    run(&app, |g| { g.group_by = by; g.range_days = range_days.clamp(1, 90); Ok(()) })
}

#[tauri::command]
fn continue_session(app: AppHandle, target: String) -> Result<Value, String> {
    run(&app, |g| {
        let last = g.usage.last_session().ok_or("No recent conversation to continue.")?;
        let msg = g.store.continue_session(&last, &target, &g.usage)?;
        g.overflow_suggestion = None;
        g.banner = Some(msg);
        Ok(())
    })
}

#[tauri::command]
fn dismiss_banner(app: AppHandle) -> Result<Value, String> { run(&app, |g| { g.banner = None; g.overflow_suggestion = None; Ok(()) }) }

#[tauri::command]
fn open_url(app: AppHandle, url: String) -> Result<(), String> {
    if !(url.starts_with("https://") || url.starts_with("http://")) { return Err("Only web links can be opened.".into()); }
    tauri_plugin_opener::OpenerExt::opener(&app).open_url(url, None::<&str>).map_err(|e| e.to_string())
}

#[tauri::command]
fn toggle_pin(app: AppHandle) -> Result<Value, String> { run(&app, |g| { g.pinned = !g.pinned; Ok(()) }) }

#[tauri::command]
fn open_main_near_button(app: AppHandle) { shell::show_main_near_button(&app); }

#[tauri::command]
fn quit(app: AppHandle) { app.exit(0); }

/// `anchor` next to this executable (Tauri puts the sidecar there; debug builds find target/debug/anchor).
#[cfg(not(target_os = "macos"))]
fn sidecar() -> Result<std::path::PathBuf, String> {
    let name = if cfg!(windows) { "anchor.exe" } else { "anchor" };
    let p = std::env::current_exe().map_err(|e| e.to_string())?.with_file_name(name);
    if p.metadata().is_ok_and(|m| m.len() > 0) { Ok(p) } else { Err(format!("The anchor helper is missing ({}). Reinstall Claude Anchor.", p.display())) }
}

fn main() {
    let (wtx, wrx) = mpsc::channel::<()>();
    tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, _, _| shell::show_main(app, None)))
        .plugin(tauri_plugin_autostart::init(tauri_plugin_autostart::MacosLauncher::LaunchAgent, None))
        .plugin(tauri_plugin_notification::init())
        .plugin(tauri_plugin_global_shortcut::Builder::new().build())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .invoke_handler(tauri::generate_handler![
            get_state, refresh, set_default, add_account, sign_in, cancel_sign_in, sign_out_primary, remove_account,
            rename_account, set_flag, move_account, add_rule, remove_rule, set_rule_overflow, pick_folder, set_setting,
            set_editor_integration, set_login_item, set_usage_view, continue_session, dismiss_banner, open_url,
            toggle_pin, open_main_near_button, quit
        ])
        .on_window_event(shell::on_window_event)
        .setup(move |app| {
            #[cfg(target_os = "macos")]
            app.set_activation_policy(tauri::ActivationPolicy::Accessory);
            let h = app.handle().clone();
            let (mut store, mut banner) = Store::load(Paths::get());
            let clamped = clamp_refresh(store.config.refresh_seconds);
            if clamped != store.config.refresh_seconds { store.config.refresh_seconds = clamped; let _ = store.save(); }
            store.reconcile_primary();
            // macOS dev runs never touch shell files or editor settings.
            #[cfg(not(target_os = "macos"))]
            {
                let r = sidecar().and_then(|s| hook::install_binaries(&store.paths, &s)).and_then(|_| hook::install_hook(&store.paths).map(|_| ()));
                if let Err(e) = r { banner = Some(e); }
                // Editors are on by default: the first launch that finds VS Code or Cursor routes them too.
                if store.config.editor_integration.is_none() && editor::settings_files(&store.paths).iter().any(|f| f.exists()) {
                    banner = Some(match store.set_editor_integration(true) {
                        Ok(()) => "VS Code and Cursor now use Claude Anchor for new conversations. You can turn this off in Settings.".into(),
                        Err(e) => e,
                    });
                }
            }
            #[cfg(target_os = "macos")]
            let _ = (&hook::MARK, &editor::WRAPPER_KEY, &mut banner);
            let usage = Arc::new(UsageIndex::open(store.paths.usage(), store.paths.copied()));
            let secs = store.config.refresh_seconds;
            let mut inner = Inner {
                store, usage, group_by: GroupBy::Account, range_days: 7, overflow_suggestion: None, banner,
                signing_in: HashMap::new(), is_refreshing: false, last_refreshed: None, fresh_notified: HashSet::new(),
                last_move: None, pinned: false, last_hide: None, watcher: None, wtx: wtx.clone(),
            };
            restart_watch(&mut inner);
            app.manage(Mutex::new(inner));
            let _ = h.notification().request_permission();
            shell::setup(&h)?;
            let a = h.clone();
            spawn(move || while wrx.recv().is_ok() {
                while wrx.recv_timeout(Duration::from_secs(2)).is_ok() {}
                rescan(&a);
            });
            arm_timer(&h, secs);
            spawn(move || { rescan(&h); refresh_limits(&h); });
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("failed to build Claude Anchor")
        .run(|_, e| {
            // Closing every window must not quit a tray app; `quit` exits with a code.
            if let tauri::RunEvent::ExitRequested { api, code: None, .. } = e { api.prevent_exit(); }
        });
}
