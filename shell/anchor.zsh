# anchor.zsh - send `claude` to the right Claude Code config dir for the current folder.
# Source from ~/.zshrc:  source ~/Projects/claude-anchor/shell/anchor.zsh
# Pure zsh, no subprocesses on the hot path.
#
# Routes file lines:  <abs-folder>\t<config-dir or ->   ("-" = primary account, CLAUDE_CONFIG_DIR unset)
#                     default\t<config-dir or ->
# Bypass: CLAUDE_ANCHOR_OFF=1, or an existing CLAUDE_CONFIG_DIR export in this shell.

# _anchor_resolve [dir] -> sets REPLY to the config dir for dir (default $PWD), or "-" for primary.
_anchor_resolve() {
  emulate -L zsh
  local dir=${1:-$PWD}
  local routes=${CLAUDE_ANCHOR_ROUTES:-$HOME/.claude-anchor/routes}
  local line p cfg def_cfg=- best_cfg=- best_len=-1
  local -a lines
  REPLY=-
  [[ -r $routes ]] || return 0
  lines=("${(@f)$(<$routes)}")
  for line in $lines; do
    [[ -z $line || $line == \#* || $line != *$'\t'* ]] && continue
    p=${line%%$'\t'*}
    cfg=${line#*$'\t'}
    if [[ $p == default ]]; then def_cfg=$cfg; continue; fi
    [[ -n $p ]] || continue
    [[ $p == / ]] || p=${p%/}
    # longest rule P where dir == P or dir starts with "P/"
    if [[ $p == / || $dir == "$p" || $dir == "$p"/* ]]; then
      if (( ${#p} > best_len )); then best_len=${#p}; best_cfg=$cfg; fi
    fi
  done
  if (( best_len >= 0 )); then REPLY=$best_cfg; else REPLY=$def_cfg; fi
}

claude() {
  if [[ -n ${CLAUDE_ANCHOR_OFF:-} || -n ${CLAUDE_CONFIG_DIR:-} || ! -r ${CLAUDE_ANCHOR_ROUTES:-$HOME/.claude-anchor/routes} ]]; then
    command claude "$@"
    return
  fi
  _anchor_resolve "$PWD"
  if [[ $REPLY == - ]]; then
    command claude "$@"
  else
    CLAUDE_CONFIG_DIR=$REPLY command claude "$@"
  fi
}

# anchor-which [dir] -> prints the config dir that `claude` would use, or "primary".
anchor-which() {
  _anchor_resolve "${1:-$PWD}"
  if [[ $REPLY == - ]]; then print -r -- primary; else print -r -- "$REPLY"; fi
}

# Selftest: only when executed directly with --selftest, never when sourced.
if [[ ${ZSH_EVAL_CONTEXT:-} == toplevel && ${1:-} == --selftest ]]; then
  _anchor_fail=0
  _anchor_tmp=$(mktemp)
  printf '%s\t%s\n' /tmp/a /x/acct-a /tmp/a/b - default /x/acct-d > "$_anchor_tmp"
  export CLAUDE_ANCHOR_ROUTES=$_anchor_tmp
  _anchor_check() {
    local got
    got=$(anchor-which "$1")
    if [[ $got != "$2" ]]; then
      print -u2 -- "FAIL: anchor-which $1 -> '$got' (want '$2')"
      _anchor_fail=1
    fi
  }
  _anchor_check /tmp/a      /x/acct-a
  _anchor_check /tmp/a/b/c  primary
  _anchor_check /tmp/ab     /x/acct-d
  _anchor_check /tmp        /x/acct-d
  rm -f "$_anchor_tmp"
  if (( _anchor_fail )); then exit 1; fi
  print -r -- "anchor.zsh selftest OK"
  exit 0
fi
