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

# _anchor_slug path -> sets REPLY to Claude Code's folder name under projects/ for path: every UTF-16 unit that
# isn't [A-Za-z0-9] becomes "-"; past 200 characters it is cut to 200 plus "-" and base36 of a Java-style hash.
_anchor_slug() {
  emulate -L zsh
  local p=$1 c
  REPLY=${p//[^A-Za-z0-9]/-}
  [[ $p != *[^\ -~]* ]] && (( ${#p} <= 200 )) && return 0    # plain ASCII and short: done
  local -a units
  integer cp h=0 u
  REPLY=
  for c in ${(s::)p}; do
    (( cp = #c ))
    if (( cp > 0xFFFF )); then units+=($(( 0xD800 + ((cp - 0x10000) >> 10) )) $(( 0xDC00 + ((cp - 0x10000) & 0x3FF) )))
    else units+=($cp); fi
  done
  for u in $units; do
    if [[ $u -lt 128 && ${(#)u} == [A-Za-z0-9] ]]; then REPLY+=${(#)u}; else REPLY+=-; fi
    (( h = (h * 31 + u) & 0xFFFFFFFF ))
  done
  (( ${#REPLY} <= 200 )) && return 0
  (( h >= 0x80000000 )) && (( h = 0x100000000 - h ))   # Math.abs of the int32
  local b36= digits=0123456789abcdefghijklmnopqrstuvwxyz
  while :; do b36=${digits[h % 36 + 1]}$b36; (( h /= 36 )); (( h )) || break; done
  REPLY=${REPLY[1,200]}-$b36
}

# _anchor_sync -> share this folder's conversations across every account before claude starts,
# so --resume, -c and VS Code's history work after switching accounts.
# A copy is only created or extended (when it is an exact prefix of the newer one); diverged copies are left alone.
# Copies are logged to ~/.claude-anchor/copied so the app doesn't count their history as new usage.
_anchor_sync() {
  emulate -L zsh
  setopt null_glob
  [[ -n ${CLAUDE_ANCHOR_NO_SYNC:-} ]] && return 0
  zmodload -F zsh/stat b:zstat 2>/dev/null || return 0
  local home=${CLAUDE_ANCHOR_HOME:-$HOME/.claude-anchor}
  local -a dirs=($HOME/.claude $home/accounts/*(/N))
  (( ${#dirs} > 1 )) || return 0
  _anchor_slug $PWD
  local enc=$REPLY d f name src t ledger=$home/copied
  local -a st
  local -A best bestsize
  for d in $dirs; do
    for f in $d/projects/$enc/*.jsonl; do
      name=${f:t}
      zstat -A st +size -- $f 2>/dev/null || continue
      if (( st[1] > ${bestsize[$name]:--1} )); then best[$name]=$f; bestsize[$name]=$st[1]; fi
    done
  done
  for name src in ${(kv)best}; do
    for d in $dirs; do
      t=$d/projects/$enc/$name
      [[ $t == $src ]] && continue
      if [[ -e $t ]]; then
        zstat -A st +size -- $t 2>/dev/null || continue
        (( st[1] < bestsize[$name] )) || continue
        head -c $st[1] -- $src | cmp -s - $t || continue   # diverged: leave both alone
      fi
      mkdir -p -- $t:h || continue
      print -r -- "$t"$'\t'"${bestsize[$name]}" >> $ledger
      cp -p -- $src $t 2>/dev/null || continue
      if [[ -d ${src:r} ]]; then                      # subagent transcripts live beside the session
        rm -rf -- ${t:r} && cp -Rp -- ${src:r} ${t:r} 2>/dev/null
        for f in ${t:r}/**/*.jsonl; do
          zstat -A st +size -- $f 2>/dev/null && print -r -- "$f"$'\t'"$st[1]" >> $ledger
        done
      fi
    done
  done
  return 0
}

claude() {
  if [[ -n ${CLAUDE_ANCHOR_OFF:-} || -n ${CLAUDE_CONFIG_DIR:-} || ! -r ${CLAUDE_ANCHOR_ROUTES:-$HOME/.claude-anchor/routes} ]]; then
    command claude "$@"
    return
  fi
  _anchor_resolve "$PWD"
  _anchor_sync
  # CLAUDE_ANCHOR_ACCOUNT lets a session tell which account it runs on (~/.claude.json is always the primary's).
  if [[ $REPLY == - ]]; then
    CLAUDE_ANCHOR_ACCOUNT=primary command claude "$@"
  else
    CLAUDE_ANCHOR_ACCOUNT=${REPLY:t} CLAUDE_CONFIG_DIR=$REPLY command claude "$@"
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
  _anchor_slug_check() { _anchor_slug "$1"; [[ $REPLY == "$2" ]] || { print -u2 -- "FAIL: slug $1 -> '$REPLY' (want '$2')"; _anchor_fail=1; } }
  _anchor_slug_check /Users/me/proj -Users-me-proj
  _anchor_slug_check /tmp/café -tmp-caf-
  _anchor_slug_check /x😀 -x--
  _anchor_slug_check /${(l:300::a:)} -${(l:199::a:)}-vtkmfl   # same expected value as the Rust test
  if (( _anchor_fail )); then exit 1; fi
  print -r -- "anchor.zsh selftest OK"
  exit 0
fi
