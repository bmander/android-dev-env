#!/usr/bin/env bash
# Run the adb server so the cloud container can reach your USB phone over Tailscale.
#
# SECURITY: `adb -a` binds the server to ALL interfaces (adb has no per-interface
# bind). Your protection is that only tailnet peers can route to it — so:
#   * keep this laptop's macOS firewall ON, and
#   * lock the tailnet with an ACL that allows only the android-dev node to reach
#     this host on tcp:5037 (see laptop/tailscale-acl-example.json).
# Do NOT run this on an untrusted LAN without those in place.
set -euo pipefail

command -v adb >/dev/null || { echo "adb not found — run laptop/setup-macos.sh" >&2; exit 1; }

echo "Devices (USB):"
adb devices                        # auto-starts a local server
adb kill-server 2>/dev/null || true

echo "Starting tailnet-exposed adb server on :5037 (Ctrl-C to stop)…"
exec adb -a -P 5037 nodaemon server
