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

# --- Google Chrome on the host desktop ------------------------------------
# Real .deb (not the Ubuntu snap); also registers x-www-browser so the XFCE
# panel's browser button works, and gives you a browser for docs / OAuth flows.
if ! dpkg -s google-chrome-stable >/dev/null 2>&1; then
  curl -fsSL https://dl.google.com/linux/linux_signing_key.pub \
    | gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg
  echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main" \
    > /etc/apt/sources.list.d/google-chrome.list
  apt-get update && apt-get install -y google-chrome-stable
fi

# --- Node + Claude Code on the host workspace -----------------------------
# The container has its own claude; this puts it in the desktop terminal too,
# alongside Android Studio. Auth (ANTHROPIC_API_KEY) is wired per-node at boot.
if ! command -v claude >/dev/null; then
  if ! command -v node >/dev/null; then
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y --no-install-recommends nodejs
  fi
  npm install -g @anthropic-ai/claude-code && npm cache clean --force
fi

# --- Android Studio on the host desktop -----------------------------------
# Studio bundles its own JDK (JBR); its SDK is installed by the first-run wizard
# (persists on the node disk). NOTE: Studio's emulator needs KVM, which this
# machine type lacks — editing/building/on-device debugging work, emulators don't.
if [[ ! -d /opt/android-studio ]]; then
  apt-get install -y --no-install-recommends \
    libxrender1 libxtst6 libxi6 libxext6 libfreetype6 fontconfig
  wget -qO /tmp/studio.tar.gz \
    "https://edgedl.me.gvt1.com/android/studio/ide-zips/2026.1.1.10/android-studio-quail1-patch2-linux.tar.gz"
  tar -xzf /tmp/studio.tar.gz -C /opt/
  rm -f /tmp/studio.tar.gz
  cat > /usr/share/applications/android-studio.desktop <<'DESKTOP'
[Desktop Entry]
Name=Android Studio
Exec=/opt/android-studio/bin/studio.sh
Icon=/opt/android-studio/bin/studio.png
Type=Application
Categories=Development;IDE;
Terminal=false
DESKTOP
fi

echo "=== provisioning done $(date -u) ==="
