#!/usr/bin/env python3
"""Adds or removes Notch Island entries in a Claude Code settings.json.

  merge_settings.py add    <settings.json> <out.json> <hook-binary> <chain-out>
  merge_settings.py remove <settings.json> <out.json> <chain-file>

Only touches hook entries whose command contains "notch-hook" and the statusLine.
Everything else (key order included) is preserved.
"""
import json, os, sys

MARK = "notch-hook"

def load(path):
    if not os.path.exists(path):
        return {}
    with open(path) as f:
        text = f.read().strip()
    return json.loads(text) if text else {}

def has_ours(groups):
    return any(MARK in h.get("command", "") for g in groups for h in g.get("hooks", []))

def add(data, hook, chain_out):
    hooks = data.setdefault("hooks", {})
    def entry(event, timeout, matcher=None):
        groups = hooks.setdefault(event, [])
        if has_ours(groups):
            return
        e = {}
        if matcher is not None:
            e["matcher"] = matcher
        e["hooks"] = [{"type": "command", "command": f'"{hook}" claude {event}', "timeout": timeout}]
        groups.append(e)
    entry("Notification", 5)
    entry("Stop", 10)
    entry("StopFailure", 5)
    # Blocks up to NOTCH_ISLAND_PERMISSION_TIMEOUT (20 s) waiting for Allow/Deny in the notch.
    entry("PermissionRequest", 30, "*")

    ours = {"type": "command", "command": f'"{hook}" statusline', "padding": 0}
    current = data.get("statusLine")
    if current is None:
        data["statusLine"] = ours
    elif MARK not in current.get("command", ""):
        # Keep the user's status line: ours saves the usage data, then runs theirs.
        with open(chain_out, "w") as f:
            f.write(current.get("command", ""))
        data["statusLine"] = ours

def remove(data, chain_file):
    hooks = data.get("hooks", {})
    for event in list(hooks):
        groups = []
        for g in hooks[event]:
            kept = [h for h in g.get("hooks", []) if MARK not in h.get("command", "")]
            if kept:
                g = dict(g); g["hooks"] = kept; groups.append(g)
            elif not g.get("hooks"):
                groups.append(g)
        if groups:
            hooks[event] = groups
        else:
            del hooks[event]
    if "hooks" in data and not data["hooks"]:
        del data["hooks"]
    sl = data.get("statusLine")
    if sl and MARK in sl.get("command", ""):
        chain = open(chain_file).read().strip() if os.path.exists(chain_file) else ""
        if chain:
            data["statusLine"] = {"type": "command", "command": chain}
        else:
            del data["statusLine"]

def main():
    mode, src, out = sys.argv[1], sys.argv[2], sys.argv[3]
    data = load(src)
    if mode == "add":
        add(data, sys.argv[4], sys.argv[5])
    else:
        remove(data, sys.argv[4])
    with open(out, "w") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")

main()
