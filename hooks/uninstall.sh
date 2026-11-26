#!/bin/bash
# Removes everything install.sh added. Shows diffs and asks first.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HOME/.notch-island"
SETTINGS="$HOME/.claude/settings.json"
ZSHRC="${ZDOTDIR:-$HOME}/.zshrc"
STAMP="$(date +%Y%m%d-%H%M%S)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
confirm() { read -r -p "$1 [y/N] " a; [[ "$a" == y || "$a" == Y ]]; }

if [[ -f "$SETTINGS" ]]; then
  /usr/bin/python3 "$HERE/merge_settings.py" remove "$SETTINGS" "$TMP/settings.json" "$ROOT/statusline-chain"
  if ! diff -q "$SETTINGS" "$TMP/settings.json" >/dev/null; then
    diff -u --label "settings.json (current)" --label "settings.json (new)" "$SETTINGS" "$TMP/settings.json" || true
    if confirm "Apply to $SETTINGS?"; then
      cp "$SETTINGS" "$SETTINGS.notch-island-backup-$STAMP"
      cp "$TMP/settings.json" "$SETTINGS"
      rm -f "$ROOT/statusline-chain"
    fi
  fi
fi

if [[ -f "$ZSHRC" ]] && grep -q "notch-island.zsh" "$ZSHRC"; then
  grep -v "notch-island.zsh" "$ZSHRC" > "$TMP/zshrc" || true
  diff -u --label ".zshrc (current)" --label ".zshrc (new)" "$ZSHRC" "$TMP/zshrc" || true
  if confirm "Apply to $ZSHRC?"; then
    cp "$ZSHRC" "$ZSHRC.notch-island-backup-$STAMP"
    cp "$TMP/zshrc" "$ZSHRC"
  fi
fi
echo "Done. ~/.notch-island was left in place; delete it yourself if you like."
