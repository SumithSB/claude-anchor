# Claude Anchor tray (Windows, Linux)

Tauri 2 app over `anchor-core`. UI is plain HTML in `ui/` (no bundler); the Rust side is `src/`.

## Build deps

Ubuntu/Debian:

```sh
sudo apt install build-essential pkg-config libwebkit2gtk-4.1-dev libgtk-3-dev libayatana-appindicator3-dev librsvg2-dev libssl-dev
```

The tray icon needs `libayatana-appindicator3` at runtime too. GNOME needs the AppIndicator extension.
On Linux the tray sends no click events: use the menu's "Open". Wayland has no floating button or hotkey.

## Run

```sh
cd cross
tray/scripts/prepare-sidecar.sh        # tray\scripts\prepare-sidecar.ps1 on Windows
cargo run -p anchor-tray
```

The sidecar script builds `anchor` and copies it to `tray/binaries/anchor-<target-triple>[.exe]`. Without it the build
uses an empty placeholder and the app reports a missing helper. At run time the app looks for `anchor[.exe]` next to
its own executable (for `cargo run`: `target/debug/anchor`, so run `cargo build -p anchor-core` once).

macOS runs (development only) skip installing the shell hook and editor integration. Use a throwaway
`HOME` and `CLAUDE_ANCHOR_HOME` when trying it.
