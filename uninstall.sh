#!/usr/bin/env bash
# Claude Anchor uninstaller.
#   curl -fsSL https://raw.githubusercontent.com/SumithSB/claude-anchor/main/uninstall.sh | bash
#   (add `-s -- --yes` after `bash` to skip the prompt)
# Env: CLAUDE_ANCHOR_PREFIX, CLAUDE_ANCHOR_ZSHRC, CLAUDE_ANCHOR_HOME, CLAUDE_ANCHOR_EDITOR_SETTINGS_DIR
set -euo pipefail

# Wrapped in main so a truncated `curl | bash` download never runs a partial script.
main() {

APP_NAME="Claude Anchor"
MARK="# claude-anchor"
RC="${CLAUDE_ANCHOR_ZSHRC:-$HOME/.zshrc}"
AHOME="${CLAUDE_ANCHOR_HOME:-$HOME/.claude-anchor}"
EDIR="${CLAUDE_ANCHOR_EDITOR_SETTINGS_DIR:-$HOME/Library/Application Support}"
YES=0
[ "${1:-}" = --yes ] && YES=1

step() { echo "==> $*"; }

step "Quitting $APP_NAME"
osascript -e "quit app \"$APP_NAME\"" >/dev/null 2>&1 || true

step "Removing the app"
if [ -n "${CLAUDE_ANCHOR_PREFIX:-}" ]; then
  rm -rf "${CLAUDE_ANCHOR_PREFIX:?}/$APP_NAME.app"
else
  rm -rf "/Applications/$APP_NAME.app" "$HOME/Applications/$APP_NAME.app" 2>/dev/null || true
fi

if [ -f "$RC" ] && grep -qF "$MARK" "$RC"; then
  step "Removing shell hook from $RC (backup: $RC.anchor-bak)"
  cp "$RC" "$RC.anchor-bak"
  grep -vF "$MARK" "$RC.anchor-bak" > "$RC" || true
fi

for d in Code Cursor "Code - Insiders"; do
  f="$EDIR/$d/User/settings.json"
  if [ -f "$f" ] && grep -F claudeProcessWrapper "$f" | grep -qF .claude-anchor; then
    step "Removing wrapper setting from $f (backup: $f.anchor-uninstall-bak)"
    cp "$f" "$f.anchor-uninstall-bak"
    grep -v 'claudeProcessWrapper.*\.claude-anchor' "$f.anchor-uninstall-bak" > "$f" || true
  fi
done

if [ -d "$AHOME" ]; then
  ans=n
  if [ $YES -eq 1 ]; then
    ans=y
  else
    cat <<EOF

$AHOME holds your settings, routes, usage history, and the config dirs
(including conversation history) of extra accounts in $AHOME/accounts.
Their Keychain logins are kept either way; remove them in the app first, or run:
  security delete-generic-password -s "Claude Code-credentials-<hash>"
EOF
    printf 'Delete %s? [y/N] ' "$AHOME"
    read -r ans < /dev/tty 2>/dev/null || ans=n
  fi
  case "$ans" in
    y|Y|yes) rm -rf "$AHOME"; step "Deleted $AHOME" ;;
    *) step "Kept $AHOME" ;;
  esac
fi
echo "Done. ~/.claude was not touched."
}

main "$@"
