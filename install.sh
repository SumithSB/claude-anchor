#!/usr/bin/env bash
# Claude Anchor installer.
#   curl -fsSL https://raw.githubusercontent.com/SumithSB/claude-anchor/main/install.sh | bash
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
  zip_url="$(printf '%s\n' "$urls" | grep '\.zip$' | head -n1 || true)"
  sha_url="$(printf '%s\n' "$urls" | grep '\.zip\.sha256$' | head -n1 || true)"
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
