#!/usr/bin/env python3
"""Merge the fleet-wide Claude Code defaults into a user's ~/.claude/settings.json.

Called by vm/startup-golden.sh at boot, once per real home dir. settings.json is user-scope
Claude config that Claude does NOT rewrite (unlike ~/.claude.json), so a value merged here
sticks. We MERGE rather than overwrite, so any other keys the user set survive — only the
fleet defaults below are (re)asserted. Idempotent; safe to run every boot.

Usage: claude-apply-settings <path-to-settings.json>
"""
import json
import os
import sys
import tempfile

# The fleet defaults: Opus 4.8 as the default model, vim as the edit mode. Pin the full model
# id (not the "opus" alias) so nodes stay on 4.8 when a newer Opus ships. These are DEFAULTS —
# /model and /config still override them for the running session.
DEFAULTS = {
    "model": "claude-opus-4-8",
    "editorMode": "vim",
}


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: claude-apply-settings <path-to-settings.json>")
    path = sys.argv[1]

    try:
        with open(path) as f:
            data = json.load(f)
        if not isinstance(data, dict):
            data = {}
    except (FileNotFoundError, ValueError):
        data = {}

    data.update(DEFAULTS)

    # Write atomically (temp + rename) so a crash mid-write can't corrupt an existing config.
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, indent=2)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


if __name__ == "__main__":
    main()
