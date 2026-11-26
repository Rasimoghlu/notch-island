#!/bin/bash
# Sets up Notch Island hooks. Shows every change as a diff and asks before writing.
#
# Changes (each one optional, you confirm them separately):
#   ~/.claude/settings.json  + hooks: Notification, Stop, StopFailure, PermissionRequest
#                            + statusLine (your existing one keeps running, chained)
#   ~/.zshrc                 + one line that sources ~/.notch-island/notch-island.zsh
# Backups: <file>.notch-island-backup-<timestamp>
#
#   hooks/install.sh             interactive
#   hooks/install.sh --dry-run   only show the diffs
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DRY=0; [[ "${1:-}" == "--dry-run" ]] && DRY=1

ROOT="$HOME/.notch-island"
HOOK="$ROOT/bin/notch-hook"
SETTINGS="$HOME/.claude/settings.json"
ZSHRC="${ZDOTDIR:-$HOME}/.zshrc"
STAMP="$(date +%Y%m%d-%H%M%S)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

confirm() {
  [[ $DRY == 1 ]] && { echo "(dry run: nothing written)"; return 1; }
  read -r -p "$1 [y/N] " a; [[ "$a" == y || "$a" == Y ]]
}

[[ $DRY == 1 ]] || mkdir -p "$ROOT"/{bin,events,responses,usage,shell}
if [[ ! -x "$HOOK" ]]; then
  echo "! $HOOK not found yet. Launch Notch Island once (it creates this link), then re-run."
  echo "  Continuing: the settings will point at that path."
fi

# --- Claude Code settings.json ---------------------------------------------------
echo "== $SETTINGS"
[[ -f "$SETTINGS" ]] || echo "{}" > "$TMP/empty.json"
SRC="$SETTINGS"; [[ -f "$SETTINGS" ]] || SRC="$TMP/empty.json"
/usr/bin/python3 "$HERE/merge_settings.py" add "$SRC" "$TMP/settings.json" "$HOOK" "$TMP/chain"
if diff -q "$SRC" "$TMP/settings.json" >/dev/null; then
  echo "Already set up."
else
  diff -u --label "settings.json (current)" --label "settings.json (new)" "$SRC" "$TMP/settings.json" || true
  [[ -f "$TMP/chain" ]] && echo "Your current statusLine will be kept and run by notch-hook: $(cat "$TMP/chain")"
  if confirm "Apply these changes to $SETTINGS?"; then
    [[ -f "$SETTINGS" ]] && cp "$SETTINGS" "$SETTINGS.notch-island-backup-$STAMP"
    mkdir -p "$(dirname "$SETTINGS")"
    cp "$TMP/settings.json" "$SETTINGS"
    [[ -f "$TMP/chain" ]] && cp "$TMP/chain" "$ROOT/statusline-chain"
    echo "Written. Backup: $SETTINGS.notch-island-backup-$STAMP"
  fi
fi

# --- zsh -------------------------------------------------------------------------
echo
echo "== $ZSHRC"
[[ $DRY == 1 ]] || cp "$HERE/notch-island.zsh" "$ROOT/notch-island.zsh"
LINE='[[ -r "$HOME/.notch-island/notch-island.zsh" ]] && source "$HOME/.notch-island/notch-island.zsh"  # notch-island'
if [[ -f "$ZSHRC" ]] && grep -q "notch-island.zsh" "$ZSHRC"; then
  echo "Already set up (updated $ROOT/notch-island.zsh)."
else
  touch "$TMP/zshrc"; [[ -f "$ZSHRC" ]] && cp "$ZSHRC" "$TMP/zshrc"
  cp "$TMP/zshrc" "$TMP/zshrc.new"; printf '\n%s\n' "$LINE" >> "$TMP/zshrc.new"
  diff -u --label ".zshrc (current)" --label ".zshrc (new)" "$TMP/zshrc" "$TMP/zshrc.new" || true
  if confirm "Append this line to $ZSHRC?"; then
    [[ -f "$ZSHRC" ]] && cp "$ZSHRC" "$ZSHRC.notch-island-backup-$STAMP"
    printf '\n%s\n' "$LINE" >> "$ZSHRC"
    echo "Written. Open a new terminal tab to load it."
  fi
fi

echo
echo "Done. Restart running Claude Code sessions so they pick up the hooks."
