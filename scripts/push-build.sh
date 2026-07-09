#!/usr/bin/env bash
# Build the app on the VM and install it straight onto your phone over Tailscale — the
# phone runs adb in TCP mode and is a tailnet node, so the VM connects directly (no laptop
# adb server involved). Run from a Gradle project on the VM.
#
#   push-build [path/to.apk]      # defaults to the standard debug APK path
#
# Requires: PHONE_TS_HOST set to the phone's Tailscale IP (wired from .env at boot), the
# phone on Tailscale, and adb TCP mode enabled once (`adb tcpip 5555`, see laptop/setup-macos.sh).
set -euo pipefail

PHONE="${PHONE_TS_HOST:?set PHONE_TS_HOST to the phone tailscale IP}:5555"
APK="${1:-app/build/outputs/apk/debug/app-debug.apk}"

echo "==> Connecting to phone at ${PHONE} over tailscale…"
adb connect "$PHONE" >/dev/null 2>&1 || true
adb devices

echo "==> Building (assembleDebug)…"
if [[ -x ./gradlew ]]; then ./gradlew assembleDebug; else gradle assembleDebug; fi

if [[ ! -f "$APK" ]]; then
  echo "!! APK not found at $APK — pass the correct path as the first argument." >&2
  exit 1
fi

echo "==> Installing $APK on the phone…"
adb -s "$PHONE" install -r "$APK"
echo "==> Done. Check your phone."
