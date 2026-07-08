#!/usr/bin/env bash
# GCE startup script (runs as root on every boot). Idempotent: safe across stop/start.
# Installs Docker, Tailscale, Chrome Remote Desktop + XFCE on the HOST, then builds
# and (re)launches the android-dev container with host networking.
#
# Reads instance metadata:
#   tailscale-authkey   (required)  a reusable/ephemeral Tailscale auth key
#   laptop-ts-host      (optional)  laptop's tailscale IP / MagicDNS name for adb
set -euo pipefail
exec > >(tee -a /var/log/android-dev-startup.log) 2>&1
echo "=== startup $(date -u) ==="

meta() { curl -s -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$1" || true; }

export DEBIAN_FRONTEND=noninteractive

# --- Docker ---------------------------------------------------------------
if ! command -v docker >/dev/null; then
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker
fi

# --- Tailscale ------------------------------------------------------------
if ! command -v tailscale >/dev/null; then
  curl -fsSL https://tailscale.com/install.sh | sh
fi
AUTHKEY="$(meta tailscale-authkey)"
if [[ -n "$AUTHKEY" ]]; then
  tailscale up --authkey="$AUTHKEY" --hostname=android-dev --ssh --accept-routes || true
else
  echo "!! no tailscale-authkey metadata; run 'tailscale up' manually over SSH"
fi

# --- Desktop + Chrome Remote Desktop --------------------------------------
# CRD host is installed here; the one-time headless auth is done by YOU over SSH
# (see README runbook) because it needs a code from remotedesktop.google.com/headless.
if ! dpkg -s chrome-remote-desktop >/dev/null 2>&1; then
  apt-get update
  apt-get install -y --no-install-recommends xfce4 xfce4-terminal desktop-base dbus-x11
  curl -fsSL https://dl.google.com/linux/linux_signing_key.pub \
    | gpg --dearmor -o /usr/share/keyrings/chrome-remote-desktop.gpg
  echo "deb [arch=amd64 signed-by=/usr/share/keyrings/chrome-remote-desktop.gpg] https://dl.google.com/linux/chrome-remote-desktop/deb stable main" \
    > /etc/apt/sources.list.d/chrome-remote-desktop.list
  apt-get update && apt-get install -y --no-install-recommends chrome-remote-desktop
  # Tell CRD to launch XFCE.
  echo "exec /usr/bin/xfce4-session" > /etc/chrome-remote-desktop-session
fi

# --- android-dev container ------------------------------------------------
# The container is built+launched by vm/push-repo.sh (called from create.sh), and it
# runs with `--restart unless-stopped`, so Docker brings it back automatically on every
# stop/start or reboot. The startup script deliberately does NOT build/run it here — two
# launchers racing on first boot caused a name conflict. To rebuild after image changes,
# run ./vm/push-repo.sh from your laptop.
if docker ps --format '{{.Names}}' | grep -qx android-dev; then
  echo "android-dev container already running (restart policy)."
else
  echo "android-dev container not running yet — run ./vm/push-repo.sh to build/launch it."
fi
echo "=== startup done $(date -u) ==="
