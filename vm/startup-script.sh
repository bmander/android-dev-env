#!/usr/bin/env bash
# BUILDER PROVISIONER (one-time). Used only by vm/install.sh on the throwaway builder to
# install the host software that gets baked into the golden image: Docker, Tailscale, and
# Chrome Remote Desktop + XFCE. It does NOT run the container or wire per-instance identity
# — that is startup-golden.sh's job on real nodes. Idempotent.
set -euo pipefail
exec > >(tee -a /var/log/android-dev-startup.log) 2>&1
echo "=== provisioning $(date -u) ==="

export DEBIAN_FRONTEND=noninteractive

# --- Docker ---------------------------------------------------------------
if ! command -v docker >/dev/null; then
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker
fi

# --- Tailscale (install only; nodes join via startup-golden.sh) -----------
if ! command -v tailscale >/dev/null; then
  curl -fsSL https://tailscale.com/install.sh | sh
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

echo "=== provisioning done $(date -u) ==="
