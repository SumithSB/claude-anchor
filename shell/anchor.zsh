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
  local REPLY    # callers still hold _anchor_resolve's answer in REPLY; _anchor_slug must not overwrite it
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
  local cfg=$REPLY
  _anchor_sync
  # CLAUDE_ANCHOR_ACCOUNT lets a session tell which account it runs on (~/.claude.json is always the primary's).
  if [[ $cfg == - ]]; then
    CLAUDE_ANCHOR_ACCOUNT=primary command claude "$@"
  else
    CLAUDE_ANCHOR_ACCOUNT=${cfg:t} CLAUDE_CONFIG_DIR=$cfg command claude "$@"
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
  _anchor_want() { [[ $1 == "$2" ]] || { print -u2 -- "FAIL: $3 -> '$1' (want '$2')"; _anchor_fail=1; } }

  # End to end: claude() with the sync on, in a scratch home with the primary and one more account.
  # 0.6.0 let _anchor_sync overwrite REPLY, so claude ran with CLAUDE_CONFIG_DIR set to the folder's slug.
  _anchor_tmp=$(mktemp -d); _anchor_tmp=${_anchor_tmp:A}
  (
    T=$_anchor_tmp
    export HOME=$T/home PATH=$T/bin:$PATH CLAUDE_ANCHOR_ROUTES=$T/home/.claude-anchor/routes
    unset CLAUDE_CONFIG_DIR CLAUDE_ANCHOR_ACCOUNT CLAUDE_ANCHOR_OFF CLAUDE_ANCHOR_NO_SYNC CLAUDE_ANCHOR_HOME
    P=$HOME/.claude W=$HOME/.claude-anchor/accounts/work
    long=$T/w/${(l:220::a:)}
    mkdir -p $T/bin $P $W $T/w/plain $T/w/café $long $T/p/sub
    print -r -- '#!/bin/sh
printf "%s|%s|%s\n" "${CLAUDE_CONFIG_DIR--}" "${CLAUDE_ANCHOR_ACCOUNT-}" "$*"' > $T/bin/claude
    chmod +x $T/bin/claude
    printf '%s\t%s\n' $T/p - default $W > $CLAUDE_ANCHOR_ROUTES
    run() { (cd -- $1 && claude --x) }

    _anchor_want "$(run $T/w/plain)" "$W|work|--x" "default route"
    _anchor_want "$(run $T/w/café)"  "$W|work|--x" "default route, accented folder"
    _anchor_want "$(run $long)"      "$W|work|--x" "default route, folder past 200 characters"
    _anchor_want "$(run $T/p/sub)"   "-|primary|--x" "rule to the primary account"
    _anchor_want "$(export CLAUDE_CONFIG_DIR=/elsewhere; run $T/w/plain)" "/elsewhere||--x" "CLAUDE_CONFIG_DIR already set"
    _anchor_want "$(export CLAUDE_ANCHOR_OFF=1; run $T/w/plain)" "-||--x" "CLAUDE_ANCHOR_OFF"
    REPLY=/x/acct-a; _anchor_sync
    _anchor_want "$REPLY" /x/acct-a "_anchor_sync leaves REPLY alone"

    # The sync shares conversations and never touches sign-in or settings files.
    for d in $P $W; do print -r -- "$d" > $d/.claude.json; print -r -- "$d" > $d/.credentials.json; done
    for dir in $T/w/plain $T/w/café $long; do
      _anchor_slug $dir; enc=$REPLY
      mkdir -p $P/projects/$enc/new/subagents $W/projects/$enc
      print -r -- one > $P/projects/$enc/new.jsonl
      print -r -- sub > $P/projects/$enc/new/subagents/a.jsonl
      printf 'a\nb\n' > $W/projects/$enc/grown.jsonl; printf 'a\n' > $P/projects/$enc/grown.jsonl
      printf 'x\n' > $P/projects/$enc/split.jsonl; printf 'y\nz\n' > $W/projects/$enc/split.jsonl
      run $dir > /dev/null
      _anchor_want "$(<$W/projects/$enc/new.jsonl)" one "new conversation copied ($dir:t)"
      _anchor_want "$(<$W/projects/$enc/new/subagents/a.jsonl)" sub "subagent transcript copied ($dir:t)"
      _anchor_want "$(<$P/projects/$enc/grown.jsonl)" $'a\nb' "shorter copy extended ($dir:t)"
      _anchor_want "$(<$P/projects/$enc/split.jsonl)" x "diverged copy left alone ($dir:t)"
      _anchor_want "$(<$W/projects/$enc/split.jsonl)" $'y\nz' "diverged copy left alone ($dir:t)"
      [[ -n $(grep -F -- $W/projects/$enc/new.jsonl $HOME/.claude-anchor/copied) ]] || _anchor_want missing logged "copy logged ($dir:t)"
    done
    for d in $P $W; do
      _anchor_want "$(<$d/.claude.json)" $d ".claude.json untouched"
      _anchor_want "$(<$d/.credentials.json)" $d ".credentials.json untouched"
    done
    _anchor_want "$(print -rl -- $T/w/*/-*(N/) $T/w/-*(N/))" "" "no config folder created in the project"
    exit $_anchor_fail
  ) || _anchor_fail=1
  rm -rf "$_anchor_tmp"
  if (( _anchor_fail )); then exit 1; fi
  print -r -- "anchor.zsh selftest OK"
  exit 0
fi
