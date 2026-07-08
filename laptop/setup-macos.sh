#!/usr/bin/env bash
# One-time laptop setup (macOS): Tailscale + adb. Run once, then adb-server.sh.
set -euo pipefail

if ! command -v brew >/dev/null; then
  echo "Homebrew required: https://brew.sh" >&2; exit 1
fi

echo "Installing Tailscale + Android platform-tools (adb)…"
brew install --cask tailscale 2>/dev/null || brew upgrade --cask tailscale || true
brew install android-platform-tools 2>/dev/null || brew upgrade android-platform-tools || true

cat <<'EOF'

Next steps:
  1. Open the Tailscale app and sign in (same account as the VM's tailnet).
  2. Note this laptop's Tailscale name/IP:   tailscale ip -4    (or MagicDNS name)
     -> pass it to the VM as LAPTOP_TS_HOST when you create/restore it.
  3. Plug in your Android phone over USB, enable USB debugging, accept the prompt.
  4. Start the tailnet-exposed adb server:   ./laptop/adb-server.sh
EOF
