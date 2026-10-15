# Builds the `anchor` CLI and copies it where Tauri expects the sidecar: binaries\anchor-<target-triple>.exe
$ErrorActionPreference = "Stop"
Set-Location "$PSScriptRoot\..\.."
$t = (rustc -vV | Select-String '^host: (.*)').Matches[0].Groups[1].Value
cargo build -p anchor-core --release --bin anchor
New-Item -ItemType Directory -Force tray\binaries | Out-Null
Copy-Item target\release\anchor.exe "tray\binaries\anchor-$t.exe"
Write-Output "tray\binaries\anchor-$t.exe"
