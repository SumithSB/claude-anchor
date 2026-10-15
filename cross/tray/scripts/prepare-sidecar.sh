#!/bin/sh
# Builds the `anchor` CLI and copies it where Tauri expects the sidecar: binaries/anchor-<target-triple>.
set -e
cd "$(dirname "$0")/../.."
T=$(rustc -vV | sed -n 's/^host: //p')
cargo build -p anchor-core --release --bin anchor
mkdir -p tray/binaries
cp target/release/anchor "tray/binaries/anchor-$T"
echo "tray/binaries/anchor-$T"
