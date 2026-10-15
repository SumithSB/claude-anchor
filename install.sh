#!/usr/bin/env bash
# Claude Anchor installer.
#   curl -fsSL https://raw.githubusercontent.com/SumithSB/claude-anchor/main/install.sh | bash
# Linux: installs the AppImage tray app + anchor CLI (see cross/).
# Env: CLAUDE_ANCHOR_PREFIX, CLAUDE_ANCHOR_ZSHRC, CLAUDE_ANCHOR_FROM_SOURCE=<path>,
#      CLAUDE_ANCHOR_NO_SHELL=1, CLAUDE_ANCHOR_NO_LAUNCH=1
set -euo pipefail

# Wrapped in main so a truncated `curl | bash` download never runs a partial script.
main() {

REPO="SumithSB/claude-anchor"
APP_NAME="Claude Anchor"
MARK="# claude-anchor"
RC="${CLAUDE_ANCHOR_ZSHRC:-$HOME/.zshrc}"

step() { echo "==> $*"; }
warn() { echo "warning: $*" >&2; }
die()  { echo "error: $1" >&2; [ $# -gt 1 ] && echo "fix: $2" >&2; exit 1; }

# ---- Linux (the Tauri tray app + anchor CLI from cross/) ----
linux_install() {
  local bindir="$HOME/.local/bin" appdir="$HOME/.local/share/applications"
  local ahome="${CLAUDE_ANCHOR_HOME:-$HOME/.claude-anchor}" tmp app cli src json urls
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  mkdir -p "$bindir" "$appdir" || die "Cannot create $bindir." "Check permissions on your home folder."

  sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }
  # get <url pattern> <name>: download the asset and its .sha256, verify
  get() {
    local url sum want
    url="$(printf '%s\n' "$urls" | grep -E "$1\$" | grep -v '\.sha256$' | head -n1 || true)"
    sum="$(printf '%s\n' "$urls" | grep -E "$1\.sha256\$" | head -n1 || true)"
    [ -n "$url" ] && [ -n "$sum" ] || return 1
    step "Downloading ${url##*/}"
    curl --proto =https --tlsv1.2 -fsSL -o "$tmp/$2" "$url" && curl --proto =https --tlsv1.2 -fsSL -o "$tmp/$2.sha256" "$sum" || return 1
    want="$(awk '{print $1}' "$tmp/$2.sha256")"
    [ -n "$want" ] && [ "$want" = "$(sha "$tmp/$2")" ] || die "Checksum mismatch for ${url##*/}." "Retry later. If it keeps failing, build from source: git clone https://github.com/$REPO && cd claude-anchor && CLAUDE_ANCHOR_FROM_SOURCE=. ./install.sh"
  }

  build_linux_source() {
    src="${CLAUDE_ANCHOR_FROM_SOURCE:-}"
    command -v cargo >/dev/null 2>&1 || die "Rust (cargo) not found, needed to build from source." "Install it from https://rustup.rs, plus the Tauri build packages listed in cross/tray/README.md, then run this again."
    if [ -z "$src" ]; then
      command -v git >/dev/null 2>&1 || die "git not found." "Install git and try again."
      step "Cloning $REPO"
      git clone --depth 1 "https://github.com/$REPO.git" "$tmp/src" >/dev/null 2>&1 || die "Could not clone https://github.com/$REPO." "Check your network connection and try again."
      src="$tmp/src"
    fi
    step "Building from source (this takes a few minutes)"
    # custom-protocol embeds ui/ in the binary; a plain cargo build would look for a dev server.
    (cd "$src/cross" && tray/scripts/prepare-sidecar.sh && cargo build --release -p anchor-core \
      && cargo build --release -p anchor-tray --features tauri/custom-protocol) \
      || die "Build failed." "See the output above. Tauri needs the packages listed in cross/tray/README.md."
    app="$src/cross/target/release/claude-anchor"; cli="$src/cross/target/release/anchor"
    cp "$app" "$bindir/claude-anchor" && chmod +x "$bindir/claude-anchor"
    APPEXEC="$bindir/claude-anchor"
  }

  APPEXEC="$bindir/claude-anchor.AppImage"
  cli=""
  if [ -n "${CLAUDE_ANCHOR_FROM_SOURCE:-}" ]; then
    build_linux_source
  else
    local ok=0
    if [ "$(uname -m)" = x86_64 ]; then
      step "Looking for the latest release"
      json="$(curl --proto =https --tlsv1.2 -fsSL "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null)" || json=""
      urls="$(printf '%s\n' "$json" | grep -o '"browser_download_url": *"[^"]*"' | sed 's/.*: *"//; s/"$//')"
      if get '\.AppImage' app.AppImage && get 'linux-x86_64\.tar\.gz' cli.tar.gz; then
        ok=1
        mkdir -p "$tmp/cli" && tar -xzf "$tmp/cli.tar.gz" -C "$tmp/cli" && cli="$tmp/cli/anchor" || die "Could not unpack the CLI archive."
        step "Installing to $bindir"
        pkill -f claude-anchor.AppImage >/dev/null 2>&1 || true
        cp "$tmp/app.AppImage" "$APPEXEC.new" && chmod +x "$APPEXEC.new" && mv -f "$APPEXEC.new" "$APPEXEC" || die "Could not write $APPEXEC."
      fi
    else
      warn "No prebuilt release for $(uname -m); building from source."
    fi
    if [ $ok -eq 0 ]; then
      step "No usable release found; falling back to a source build"
      build_linux_source
    fi
  fi

  if [ "${CLAUDE_ANCHOR_NO_SHELL:-}" = 1 ]; then
    step "Skipping shell hook (CLAUDE_ANCHOR_NO_SHELL=1)"
    mkdir -p "$ahome/bin" && cp "$cli" "$ahome/bin/anchor" && cp "$cli" "$ahome/bin/claude-wrapper" \
      && chmod +x "$ahome/bin/anchor" "$ahome/bin/claude-wrapper" || die "Could not install the anchor CLI to $ahome/bin."
  else
    chmod +x "$cli"
    "$cli" install || die "anchor install failed." "Run it by hand: $cli install"
  fi

  cat > "$appdir/claude-anchor.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Claude Anchor
Comment=Route Claude Code to the right account
Exec=$APPEXEC
Terminal=false
Categories=Utility;Development;
EOF

  if command -v claude >/dev/null 2>&1 || [ -x "$HOME/.local/bin/claude" ]; then
    step "Claude Code CLI found"
  else
    warn "Claude Code CLI not found. Install it with: curl --proto =https --tlsv1.2 -fsSL https://claude.ai/install.sh | bash"
  fi

  if [ "${CLAUDE_ANCHOR_NO_LAUNCH:-}" = 1 ]; then
    step "Skipping launch (CLAUDE_ANCHOR_NO_LAUNCH=1)"
  elif [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
    step "Launching $APP_NAME"
    (setsid "$APPEXEC" >/dev/null 2>&1 &) || warn "Could not launch the app; run $APPEXEC."
  fi

  cat <<EOF

Installed: $APPEXEC
CLI:       $ahome/bin/anchor
Desktop:   $appdir/claude-anchor.desktop
Next steps:
  1. Click the anchor in the tray (GNOME needs the AppIndicator extension), then Accounts -> Add account.
  2. Open a new terminal so the shell hook loads.
  3. The AppImage needs FUSE 2 (libfuse2) to run.
EOF
}

if [ "$(uname -s)" = Linux ]; then
  linux_install
  return 0
fi

[ "$(uname -s)" = Darwin ] || die "Claude Anchor only runs on macOS." "Use a Mac running macOS 14 or later."
MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
[ "$MAJOR" -ge 14 ] || die "macOS 14 or later is required (found $(sw_vers -productVersion))." "Update macOS, then run this again."

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
APP_SRC=""

fetch_release() {
  step "Looking for the latest release"
  local json urls zip_url sha_url
  json="$(curl --proto =https --tlsv1.2 -fsSL "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null)" || return 1
  urls="$(printf '%s\n' "$json" | grep -o '"browser_download_url": *"[^"]*"' | sed 's/.*: *"//; s/"$//')"
  zip_url="$(printf '%s\n' "$urls" | grep 'ClaudeAnchor-.*\.zip$' | head -n1 || true)"
  sha_url="$(printf '%s\n' "$urls" | grep 'ClaudeAnchor-.*\.zip\.sha256$' | head -n1 || true)"
  [ -n "$zip_url" ] && [ -n "$sha_url" ] || return 1
  step "Downloading ${zip_url##*/}"
  curl --proto =https --tlsv1.2 -fsSL -o "$TMP/app.zip" "$zip_url" && curl --proto =https --tlsv1.2 -fsSL -o "$TMP/app.zip.sha256" "$sha_url" || return 1
  step "Verifying checksum"
  local want got
  want="$(awk '{print $1}' "$TMP/app.zip.sha256")"
  got="$(shasum -a 256 "$TMP/app.zip" | awk '{print $1}')"
  [ -n "$want" ] && [ "$want" = "$got" ] || die "Checksum mismatch for the downloaded release." "Retry later. If it keeps failing, build from source: git clone https://github.com/$REPO && cd claude-anchor && scripts/build.sh --install"
  mkdir -p "$TMP/unzip"
  ditto -x -k "$TMP/app.zip" "$TMP/unzip" || return 1
  [ -d "$TMP/unzip/$APP_NAME.app" ] || return 1
  APP_SRC="$TMP/unzip/$APP_NAME.app"
}

build_source() {
  local src="${CLAUDE_ANCHOR_FROM_SOURCE:-}"
  command -v swift >/dev/null 2>&1 || die "Swift toolchain not found, needed to build from source." "Run: xcode-select --install   (then run this installer again)"
  if [ -z "$src" ]; then
    command -v git >/dev/null 2>&1 || die "git not found." "Run: xcode-select --install"
    step "Cloning $REPO"
    git clone --depth 1 "https://github.com/$REPO.git" "$TMP/src" >/dev/null 2>&1 || die "Could not clone https://github.com/$REPO." "Check your network connection and try again."
    src="$TMP/src"
  fi
  step "Building from source (this takes a minute)"
  (cd "$src" && scripts/build.sh) || die "Build failed." "See the output above. Xcode or Command Line Tools 15+ is required."
  APP_SRC="$src/build.noindex/$APP_NAME.app"
}

if [ -n "${CLAUDE_ANCHOR_FROM_SOURCE:-}" ]; then
  build_source
elif ! fetch_release; then
  step "No usable release found; falling back to a source build"
  build_source
fi

# Install location
if [ -n "${CLAUDE_ANCHOR_PREFIX:-}" ]; then
  DEST="$CLAUDE_ANCHOR_PREFIX"
elif [ -w /Applications ]; then
  DEST=/Applications
else
  DEST="$HOME/Applications"
fi
mkdir -p "$DEST" || die "Cannot create $DEST." "Set CLAUDE_ANCHOR_PREFIX to a writable directory."
step "Installing to $DEST"
osascript -e "quit app \"$APP_NAME\"" >/dev/null 2>&1 || true
rm -rf "${DEST:?}/$APP_NAME.app"
cp -R "$APP_SRC" "$DEST/" || die "Could not copy the app to $DEST." "Check permissions on that folder."
xattr -dr com.apple.quarantine "$DEST/$APP_NAME.app" >/dev/null 2>&1 || true

if command -v claude >/dev/null 2>&1 || [ -x "$HOME/.local/bin/claude" ]; then
  step "Claude Code CLI found"
else
  warn "Claude Code CLI not found. Install it with: curl --proto =https --tlsv1.2 -fsSL https://claude.ai/install.sh | bash"
fi

if [ "${CLAUDE_ANCHOR_NO_SHELL:-}" = 1 ]; then
  step "Skipping shell hook (CLAUDE_ANCHOR_NO_SHELL=1)"
elif [ -f "$RC" ] && grep -qF "$MARK" "$RC"; then
  step "Shell hook already in $RC"
else
  printf '\n[ -f "$HOME/.claude-anchor/anchor.zsh" ] && source "$HOME/.claude-anchor/anchor.zsh"  %s\n' "$MARK" >> "$RC" \
    || die "Could not write to $RC." "Add the line by hand: source ~/.claude-anchor/anchor.zsh"
  step "Added shell hook to $RC"
fi
case "${SHELL:-}" in
  *bash) echo "note: terminal routing needs zsh. VS Code and Cursor routing still works." ;;
esac

if [ "${CLAUDE_ANCHOR_NO_LAUNCH:-}" = 1 ]; then
  step "Skipping launch (CLAUDE_ANCHOR_NO_LAUNCH=1)"
else
  step "Launching $APP_NAME"
  open "$DEST/$APP_NAME.app" || warn "Could not launch the app; open it from $DEST."
fi

cat <<EOF

Installed: $DEST/$APP_NAME.app
Next steps:
  1. Click the anchor in the menu bar, then Accounts -> Add account.
  2. Open the gear menu and turn on "Use in VS Code and Cursor".
  3. Open a new terminal tab so the shell hook loads.
EOF
}

main "$@"
