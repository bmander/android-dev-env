#!/usr/bin/env bash
# One-time setup so the VM can install builds straight onto your phone over Tailscale.
# The phone is a tailnet node running adb in TCP mode; no laptop adb server is involved.
set -euo pipefail

if ! command -v brew >/dev/null; then
  echo "Homebrew required: https://brew.sh" >&2; exit 1
fi

echo "Installing Tailscale + Android platform-tools (adb, for the one-time TCP flip)…"
brew install --cask tailscale 2>/dev/null || brew upgrade --cask tailscale || true
brew install android-platform-tools 2>/dev/null || brew upgrade android-platform-tools || true

cat <<'EOF'

Next steps:
  1. Sign into Tailscale on BOTH this Mac and the phone (same account), and install the
     Tailscale app on the phone. Get the phone's tailnet IP:
        tailscale status | grep -i <your-phone>     ->  PHONE_TS_HOST in .env
  2. On the phone: Settings > Developer options > enable "USB debugging". Plug it in once,
     accept the RSA prompt, then flip adb into TCP mode:
        adb tcpip 5555
     (This resets on reboot — re-run it once when that happens. Or use Android's
      "Wireless debugging" for a reboot-proof setup.)
  3. Put the phone's tailnet IP in .env:   PHONE_TS_HOST=100.x.y.z
  4. Keep Tailscale ON on the phone whenever you want to receive builds.

The VM then does `adb connect $PHONE_TS_HOST:5555` and installs directly — see `push-build`.
First push from a new VM: tap "Allow" on the phone once (the golden image ships a shared
adb key, so choose "Always allow" and future nodes are trusted automatically).
EOF
