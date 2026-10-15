//! Windowing: tray icon (ring drawn in Rust), the `main` popover, the floating `button`, global shortcut.

use crate::{push, run, with, Inner, DIALOG_OPEN};
use std::sync::atomic::{AtomicU64, Ordering::SeqCst};
use std::sync::OnceLock;
use std::time::{Duration, Instant};
use tauri::image::Image;
use tauri::menu::{CheckMenuItem, Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Manager, PhysicalPosition, Window, WindowEvent, Wry};
use tauri::{WebviewUrl, WebviewWindow, WebviewWindowBuilder};
use tauri_plugin_autostart::ManagerExt as _;
use tauri_plugin_global_shortcut::{GlobalShortcutExt as _, ShortcutState};

const BTN: f64 = 56.0;
static BTN_GEN: AtomicU64 = AtomicU64::new(0);
static CHECKS: OnceLock<(CheckMenuItem<Wry>, CheckMenuItem<Wry>)> = OnceLock::new();

pub fn wayland() -> bool {
    cfg!(target_os = "linux") && (std::env::var("XDG_SESSION_TYPE").is_ok_and(|s| s == "wayland") || std::env::var_os("WAYLAND_DISPLAY").is_some())
}

// ---- tray icon ----

/// 64x64 RGBA: track ring, arc for `pct` (clockwise from the top), clay dot in the middle. Antialiased by distance.
fn ring(pct: Option<f64>) -> Vec<u8> {
    let rgb = match pct { Some(p) if p >= 90.0 => (0xB5, 0x35, 0x2E), Some(p) if p >= 75.0 => (0x8C, 0x5F, 0x0B), _ => (0x2A, 0x72, 0x62) };
    let clay = (0xD9 as f32, 0x77 as f32, 0x57 as f32);
    let mut px = Vec::with_capacity(64 * 64 * 4);
    for y in 0..64 {
        for x in 0..64 {
            let (dx, dy) = (x as f32 - 31.5, y as f32 - 31.5);
            let d = (dx * dx + dy * dy).sqrt();
            let band = (29.5 - d).clamp(0.0, 1.0) * (d - 21.5).clamp(0.0, 1.0);
            let turn = dx.atan2(-dy).rem_euclid(std::f32::consts::TAU) / std::f32::consts::TAU * 100.0;
            let (c, a) = if pct.is_some_and(|p| turn as f64 <= p) { ((rgb.0 as f32, rgb.1 as f32, rgb.2 as f32), band) } else { ((138.0, 138.0, 138.0), band * 0.45) };
            let dot = (5.5 - d).clamp(0.0, 1.0);
            let out = dot + a * (1.0 - dot);
            let mix = |k: f32, r: f32| if out > 0.0 { (k * dot + r * a * (1.0 - dot)) / out } else { 0.0 };
            px.extend([mix(clay.0, c.0) as u8, mix(clay.1, c.1) as u8, mix(clay.2, c.2) as u8, (out * 255.0) as u8]);
        }
    }
    px
}

pub fn update_tray(app: &AppHandle, g: &Inner, login_item: bool) {
    let c = &g.store.config;
    let a = c.active();
    let pct = a.and_then(|a| g.store.limits.get(&a.id)).and_then(|l| l.five_hour.as_ref()).map(|w| w.percent);
    if let Some(t) = app.tray_by_id("tray") {
        let _ = t.set_icon(Some(Image::new_owned(ring(pct), 64, 64)));
        let tip = match (a, pct) {
            (Some(a), Some(p)) => format!("Claude Anchor — {} 5h {}%", a.name, p.round() as i64),
            (Some(a), None) => format!("Claude Anchor — {}", a.name),
            _ => "Claude Anchor".into(),
        };
        let _ = t.set_tooltip(Some(tip));
    }
    if let Some((b, l)) = CHECKS.get() {
        let _ = b.set_checked(c.floating_button);
        let _ = l.set_checked(login_item);
    }
}

fn toggle_button(app: &AppHandle) {
    if run(app, |g| { g.store.config.floating_button = !g.store.config.floating_button; g.store.save() }).is_ok() { sync_button(app); }
}

pub fn setup(app: &AppHandle) -> tauri::Result<()> {
    WebviewWindowBuilder::new(app, "main", WebviewUrl::App("index.html".into()))
        .title("Claude Anchor").inner_size(340.0, 640.0).decorations(false).resizable(false)
        .skip_taskbar(true).always_on_top(true).visible(false).build()?;

    let open = MenuItem::with_id(app, "open", "Open", true, None::<&str>)?;
    let button = CheckMenuItem::with_id(app, "button", "Floating button", !wayland(), false, None::<&str>)?;
    let login = CheckMenuItem::with_id(app, "login", "Start at login", true, false, None::<&str>)?;
    let quit = MenuItem::with_id(app, "quit", "Quit", true, None::<&str>)?;
    let menu = Menu::with_items(app, &[&open, &button, &login, &PredefinedMenuItem::separator(app)?, &quit])?;
    let _ = CHECKS.set((button, login));
    TrayIconBuilder::with_id("tray")
        .icon(Image::new_owned(ring(None), 64, 64))
        .tooltip("Claude Anchor")
        .menu(&menu)
        .show_menu_on_left_click(false)
        .on_menu_event(|app, e| match e.id.as_ref() {
            "open" => show_main(app, None),
            "button" => toggle_button(app),
            "login" => {
                let m = app.autolaunch();
                let _ = if m.is_enabled().unwrap_or(false) { m.disable() } else { m.enable() };
                with(app, |g| { push(app, g); });
            }
            "quit" => app.exit(0),
            _ => {}
        })
        // Linux appindicator sends no click events; there the "Open" menu item does the job.
        .on_tray_icon_event(|t, e| {
            if let TrayIconEvent::Click { button: MouseButton::Left, button_state: MouseButtonState::Up, rect, .. } = e {
                let app = t.app_handle();
                let s = app.get_webview_window("main").map_or(1.0, |w| w.scale_factor().unwrap_or(1.0));
                let (p, z) = (rect.position.to_physical::<f64>(s), rect.size.to_physical::<f64>(s));
                toggle_main(app, (p.x, p.y, z.width, z.height));
            }
        })
        .build(app)?;

    if !wayland() {
        let _ = app.global_shortcut().on_shortcut("ctrl+alt+a", |app, _, ev| {
            if ev.state == ShortcutState::Pressed { toggle_button(app); }
        });
    }
    sync_button(app);
    Ok(())
}

// ---- placement ----

/// Work area (x, y, w, h) of the monitor containing the point, else the primary one.
fn work_area(app: &AppHandle, x: f64, y: f64) -> Option<(f64, f64, f64, f64)> {
    let m = app.monitor_from_point(x, y).ok().flatten().or_else(|| app.primary_monitor().ok().flatten())?;
    let w = m.work_area();
    Some((w.position.x as f64, w.position.y as f64, w.size.width as f64, w.size.height as f64))
}

fn put(win: &WebviewWindow, wa: (f64, f64, f64, f64), x: f64, y: f64) {
    let Ok(s) = win.outer_size() else { return };
    let (w, h) = (s.width as f64, s.height as f64);
    let x = x.clamp(wa.0, (wa.0 + wa.2 - w).max(wa.0));
    let y = y.clamp(wa.1, (wa.1 + wa.3 - h).max(wa.1));
    let _ = win.set_position(PhysicalPosition::new(x as i32, y as i32));
}

fn reveal(win: &WebviewWindow) {
    let _ = win.show();
    let _ = win.set_focus();
}

/// Shows `main` next to the given rect (x, y, w, h of the tray icon); with none, in the primary screen's corner.
pub fn show_main(app: &AppHandle, near: Option<(f64, f64, f64, f64)>) {
    let Some(win) = app.get_webview_window("main") else { return };
    let size = win.outer_size().map_or((340.0, 640.0), |s| (s.width as f64, s.height as f64));
    match near {
        Some((x, y, w, h)) => if let Some(wa) = work_area(app, x, y) {
            let below = y + h / 2.0 < wa.1 + wa.3 / 2.0; // tray at the top: open below it; else above
            put(&win, wa, x + w / 2.0 - size.0 / 2.0, if below { y + h } else { y - size.1 });
        },
        None => if let Some(wa) = work_area(app, 0.0, 0.0) {
            let top = !cfg!(windows);
            put(&win, wa, wa.0 + wa.2 - size.0 - 8.0, if top { wa.1 + 8.0 } else { wa.1 + wa.3 - size.1 - 8.0 });
        },
    }
    reveal(&win);
}

fn toggle_main(app: &AppHandle, near: (f64, f64, f64, f64)) {
    let Some(win) = app.get_webview_window("main") else { return };
    // Clicking the tray icon blurs (hides) the window first; that same click must not reopen it.
    let just_hidden = with(app, |g| g.last_hide.is_some_and(|t| t.elapsed() < Duration::from_millis(300)));
    if win.is_visible().unwrap_or(false) { let _ = win.hide(); } else if !just_hidden { show_main(app, Some(near)); }
}

pub fn show_main_near_button(app: &AppHandle) {
    let (Some(main), Some(b)) = (app.get_webview_window("main"), app.get_webview_window("button")) else { return show_main(app, None) };
    let (Ok(p), Ok(bs), Ok(ms)) = (b.outer_position(), b.outer_size(), main.outer_size()) else { return show_main(app, None) };
    let Some(wa) = work_area(app, p.x as f64, p.y as f64) else { return };
    let (bx, by, bw, bh) = (p.x as f64, p.y as f64, bs.width as f64, bs.height as f64);
    let x = if bx + bw / 2.0 > wa.0 + wa.2 / 2.0 { bx - ms.width as f64 } else { bx + bw };
    put(&main, wa, x, by + bh / 2.0 - ms.height as f64 / 2.0);
    reveal(&main);
}

// ---- floating button ----

/// Creates or closes the button window to match the settings. Runs on the main thread (window creation requires it).
pub fn sync_button(app: &AppHandle) {
    let a = app.clone();
    let _ = app.run_on_main_thread(move || {
        let want = with(&a, |g| g.store.config.floating_button) && !wayland();
        let have = a.get_webview_window("button");
        match (want, have) {
            (false, Some(w)) => { let _ = w.close(); }
            (true, None) => {
                let Ok(w) = WebviewWindowBuilder::new(&a, "button", WebviewUrl::App("button.html".into()))
                    .title("Claude Anchor").inner_size(BTN, BTN).decorations(false).transparent(true).resizable(false)
                    .always_on_top(true).skip_taskbar(true).shadow(false).visible(false).focused(false).build() else { return };
                let (x, y) = with(&a, |g| (g.store.config.floating_x, g.store.config.floating_y));
                // Saved position only if it is still on a screen; else bottom-right of the primary work area.
                let saved = x.zip(y).filter(|(x, y)| a.monitor_from_point(*x, *y).ok().flatten().is_some());
                let s = w.scale_factor().unwrap_or(1.0);
                if let Some((x, y)) = saved { let _ = w.set_position(PhysicalPosition::new(x as i32, y as i32)); }
                else if let Some(wa) = work_area(&a, 0.0, 0.0) {
                    put(&w, wa, wa.0 + wa.2 - (BTN + 24.0) * s, wa.1 + wa.3 - (BTN + 24.0) * s);
                }
                let _ = w.show();
            }
            _ => {}
        }
    });
}

/// After the button stops moving for 400 ms: snap to the nearest screen edge, then remember where it is.
fn settle_button(app: &AppHandle) {
    let Some(w) = app.get_webview_window("button") else { return };
    let (Ok(p), Ok(s)) = (w.outer_position(), w.outer_size()) else { return };
    let Some(wa) = work_area(app, p.x as f64, p.y as f64) else { return };
    let (x, y, bw, bh) = (p.x as f64, p.y as f64, s.width as f64, s.height as f64);
    if with(app, |g| g.store.config.floating_snap) {
        let gap = 6.0;
        let d = [(x - wa.0, 0), (wa.0 + wa.2 - (x + bw), 1), (y - wa.1, 2), (wa.1 + wa.3 - (y + bh), 3)];
        let (x2, y2) = match d.iter().min_by(|a, b| a.0.total_cmp(&b.0)).map_or(0, |m| m.1) {
            0 => (wa.0 + gap, y),
            1 => (wa.0 + wa.2 - bw - gap, y),
            2 => (x, wa.1 + gap),
            _ => (x, wa.1 + wa.3 - bh - gap),
        };
        if (x2 - x).abs() > 0.5 || (y2 - y).abs() > 0.5 { // the move this causes comes back here and saves
            put(&w, wa, x2, y2);
            return;
        }
    }
    with(app, |g| {
        let c = &mut g.store.config;
        if c.floating_x != Some(x) || c.floating_y != Some(y) {
            (c.floating_x, c.floating_y) = (Some(x), Some(y)); // ponytail: physical px; a different DPI or monitor layout falls back to the default spot
            if let Err(e) = g.store.save() { g.banner = Some(e); }
            push(app, g);
        }
    });
}

pub fn on_window_event(win: &Window, ev: &WindowEvent) {
    let app = win.app_handle();
    match (win.label(), ev) {
        ("main", WindowEvent::Focused(false)) => {
            if DIALOG_OPEN.load(SeqCst) { return; }
            if with(app, |g| { let hide = !g.pinned; if hide { g.last_hide = Some(Instant::now()); } hide }) { let _ = win.hide(); }
        }
        ("main", WindowEvent::CloseRequested { api, .. }) => { api.prevent_close(); let _ = win.hide(); }
        ("button", WindowEvent::Moved(_)) => {
            let g = BTN_GEN.fetch_add(1, SeqCst) + 1;
            let a = app.clone();
            std::thread::spawn(move || {
                std::thread::sleep(Duration::from_millis(400));
                if BTN_GEN.load(SeqCst) == g { let b = a.clone(); let _ = a.run_on_main_thread(move || settle_button(&b)); }
            });
        }
        _ => {}
    }
}
