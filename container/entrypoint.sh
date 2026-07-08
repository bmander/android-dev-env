#!/usr/bin/env bash
# Container entrypoint: make host Tailscale reachable to adb, then hand off to CMD.
set -euo pipefail

# If the laptop's tailnet name/IP is provided, point adb at its remote server so
# `adb install` streams cloud-built APKs down to the phone on your desk.
if [[ -n "${LAPTOP_TS_HOST:-}" ]]; then
  export ADB_SERVER_SOCKET="tcp:${LAPTOP_TS_HOST}:5037"
  echo "[entrypoint] adb -> laptop over tailscale: ${ADB_SERVER_SOCKET}"
fi

# GitHub auth: with GH_TOKEN in the env, configure git to use it for HTTPS github.com,
# so clones/pushes of private repos just work (in this shell and in `docker exec` shells).
if [[ -n "${GH_TOKEN:-}" ]]; then
  gh auth setup-git 2>/dev/null && echo "[entrypoint] git configured for github via token" || true
fi

# Clone the configured repo and warm Gradle in the background (keeps startup fast).
if [[ -n "${GIT_REPO:-}" ]]; then
  echo "[entrypoint] warming ${GIT_REPO} in background (log: ~/work/.warm.log)"
  nohup warm-repo >/home/dev/work/.warm.log 2>&1 &
fi

exec "$@"
