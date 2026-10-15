fn main() {
    // tauri-build insists the externalBin file exists. An empty placeholder keeps `cargo check`/clippy working;
    // scripts/prepare-sidecar.* put the real `anchor` there (the app refuses an empty one).
    let t = std::env::var("TARGET").unwrap_or_default();
    let ext = if t.contains("windows") { ".exe" } else { "" };
    let p = std::path::Path::new("binaries").join(format!("anchor-{t}{ext}"));
    if !p.exists() {
        let _ = std::fs::create_dir_all("binaries");
        let _ = std::fs::write(&p, b"");
    }
    tauri_build::build()
}
