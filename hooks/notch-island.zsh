# Notch Island — reports long-running commands to the notch.
# Sourced from ~/.zshrc (hooks/install.sh adds one line). Uses only zsh builtins, no subprocesses.
#
#   NOTCH_ISLAND_MIN_SECONDS  commands shorter than this are not reported (default 5)

[[ -o interactive ]] || return 0
zmodload zsh/datetime 2>/dev/null || return 0
zmodload -F zsh/files b:zf_mv b:zf_rm 2>/dev/null || return 0

typeset -g _ni_dir="$HOME/.notch-island"
typeset -g _ni_cmd="" _ni_pwd="" _ni_start=""
: ${NOTCH_ISLAND_MIN_SECONDS:=5}

# JSON-escape $1 into REPLY.
_ni_esc() {
  local s=$1
  s=${s//\\/\\\\}; s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}; s=${s//$'\t'/\\t}; s=${s//$'\r'/}
  REPLY=$s
}

# Atomic write: $1 subdir, $2 file name, $3 content.
_ni_write() {
  [[ -d $_ni_dir/$1 ]] || return 0
  local tmp="$_ni_dir/$1/.tmp.$$.$RANDOM"
  print -r -- "$3" >| "$tmp" 2>/dev/null && zf_mv -f "$tmp" "$_ni_dir/$1/$2" 2>/dev/null
}

_ni_preexec() {
  _ni_cmd=$1 _ni_pwd=$PWD _ni_start=$EPOCHREALTIME
  [[ -f $_ni_dir/app.pid ]] || return 0   # app not running: do nothing
  _ni_esc "$1"; local c=$REPLY
  _ni_esc "$PWD"; local d=$REPLY
  _ni_write shell "$$.json" "{\"pid\":$$,\"command\":\"$c\",\"cwd\":\"$d\",\"started\":$_ni_start}"
}

_ni_precmd() {
  local ec=$?                              # must be first
  [[ -n $_ni_start ]] || return 0
  local start=$_ni_start
  _ni_start=""
  [[ -f $_ni_dir/shell/$$.json ]] && zf_rm -f "$_ni_dir/shell/$$.json"
  local -F dur=$(( EPOCHREALTIME - start ))
  (( dur >= NOTCH_ISLAND_MIN_SECONDS )) || return 0
  [[ -f $_ni_dir/app.pid ]] || return 0
  _ni_esc "$_ni_cmd"; local c=$REPLY
  _ni_esc "$_ni_pwd"; local d=$REPLY
  local -i ms=$(( dur * 1000 ))
  local id="${EPOCHSECONDS}000-sh$$-$RANDOM"
  _ni_write events "$id.json" "{\"v\":1,\"id\":\"$id\",\"ts\":$EPOCHREALTIME,\"source\":\"shell\",\"kind\":\"command_end\",\"command\":\"$c\",\"cwd\":\"$d\",\"exit_code\":$ec,\"duration_ms\":$ms,\"shell_pid\":$$}"
}

autoload -Uz add-zsh-hook
add-zsh-hook preexec _ni_preexec
# Run before other precmd hooks so $? is still the command's exit code.
precmd_functions=(_ni_precmd ${precmd_functions:#_ni_precmd})
