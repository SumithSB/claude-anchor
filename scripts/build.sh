#!/usr/bin/env bash
# Build "Claude Anchor.app" (universal if possible, release). --install copies it to /Applications (or ~/Applications) and opens it.
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Claude Anchor"
# build.noindex: Spotlight and Launchpad skip it, so dev builds never show up as a second copy of the app.
APP="build.noindex/${APP_NAME}.app"
INSTALL=0

for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

ARCHS=(--arch arm64 --arch x86_64)
if ! swift build -c release "${ARCHS[@]}"; then
  echo "note: universal build failed (Command Line Tools only?); building for the native architecture" >&2
  ARCHS=()
  swift build -c release
fi
BIN_DIR="$(swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Anchor" "$APP/Contents/MacOS/Anchor"
cp shell/anchor.zsh "$APP/Contents/Resources/anchor.zsh"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
strip -x "$APP/Contents/MacOS/Anchor"
codesign --force --deep --sign - "$APP"

if [[ $INSTALL -eq 1 ]]; then
  DEST=/Applications
  [[ -w $DEST ]] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }
  osascript -e "quit app \"${APP_NAME}\"" >/dev/null 2>&1 || true
  rm -rf "${DEST:?}/${APP_NAME}.app"
  cp -R "$APP" "$DEST/"
  open "$DEST/${APP_NAME}.app"
  echo "installed to $DEST/${APP_NAME}.app"
fi

echo "built $APP ($(du -sh "$APP" | cut -f1))"
