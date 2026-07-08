#!/usr/bin/env bash
# Build the app in the cloud and install it on the phone attached to your laptop,
# over Tailscale. Run this from inside the android-dev container, in a Gradle project.
#
#   push-build [path/to.apk]      # defaults to the standard debug APK path
#
# Requires: LAPTOP_TS_HOST set to your laptop's Tailscale IP or MagicDNS name, and
# the laptop running `adb -a nodaemon server` (see laptop/adb-server.sh).
set -euo pipefail

LAPTOP_HOST="${LAPTOP_TS_HOST:?set LAPTOP_TS_HOST to the laptop tailscale IP or MagicDNS name}"
APK="${1:-app/build/outputs/apk/debug/app-debug.apk}"
export ADB_SERVER_SOCKET="tcp:${LAPTOP_HOST}:5037"

echo "==> Building (assembleDebug)…"
if [[ -x ./gradlew ]]; then ./gradlew assembleDebug; else gradle assembleDebug; fi

echo "==> Devices visible on the laptop's adb server:"
adb devices

if [[ ! -f "$APK" ]]; then
  echo "!! APK not found at $APK — pass the correct path as the first argument." >&2
  exit 1
fi

echo "==> Installing $APK on the laptop-attached device…"
adb install -r "$APK"
echo "==> Done. Check the phone on your desk."
