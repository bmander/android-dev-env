#!/usr/bin/env bash
# Container entrypoint: make host Tailscale reachable to adb, then hand off to CMD.
set -euo pipefail

# If the laptop's tailnet name/IP is provided, point adb at its remote server so
# `adb install` streams cloud-built APKs down to the phone on your desk.
if [[ -n "${LAPTOP_TS_HOST:-}" ]]; then
  export ADB_SERVER_SOCKET="tcp:${LAPTOP_TS_HOST}:5037"
  echo "[entrypoint] adb -> laptop over tailscale: ${ADB_SERVER_SOCKET}"
fi

exec "$@"
