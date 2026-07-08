#!/usr/bin/env bash
# Lean startup for instances booted from the android-dev-golden image. Everything heavy
# (Docker, Tailscale, CRD, the android-dev container image) is already baked in, so this
# only does per-instance wiring: join Tailscale, run the container, resume CRD if present.
# Idempotent; runs on every boot.
set -euo pipefail
exec > >(tee -a /var/log/android-dev-startup.log) 2>&1
echo "=== golden startup $(date -u) ==="

meta() { curl -s -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$1" || true; }

# --- Tailscale (unique node per instance) ---------------------------------
AUTHKEY="$(meta tailscale-authkey)"
if [[ -n "$AUTHKEY" ]]; then
  tailscale up --authkey="$AUTHKEY" --hostname="$(hostname)" --ssh --accept-routes || true
fi

# --- Claude Code auth for host workspace shells ---------------------------
# The container gets these via run-container.sh; this makes them available to the
# desktop terminal too — an API key and/or the long-lived subscription OAuth token
# (from `claude setup-token`). If neither is set, `claude` falls back to login.
{
  API_KEY="$(meta anthropic-api-key)"
  [[ -n "$API_KEY" ]] && printf 'export ANTHROPIC_API_KEY=%q\n' "$API_KEY"
  OAUTH_TOKEN="$(meta claude-oauth-token)"
  [[ -n "$OAUTH_TOKEN" ]] && printf 'export CLAUDE_CODE_OAUTH_TOKEN=%q\n' "$OAUTH_TOKEN"
} > /etc/profile.d/claude-auth.sh
# /etc/profile.d is sourced only by LOGIN shells; the XFCE desktop terminal opens a
# non-login interactive shell, so also source it from /etc/bash.bashrc.
grep -q claude-auth.sh /etc/bash.bashrc 2>/dev/null || \
  echo '[ -f /etc/profile.d/claude-auth.sh ] && . /etc/profile.d/claude-auth.sh' >> /etc/bash.bashrc

# Load KVM if this machine has nested virtualization (no-op otherwise) so /dev/kvm
# appears — run-container.sh then passes it to the container for emulator acceleration.
modprobe kvm_intel 2>/dev/null || modprobe kvm_amd 2>/dev/null || true
# Open /dev/kvm to all local users (desktop + container) for the emulator. The baked
# udev rule handles this too; this covers the current boot / pre-rebake nodes.
[[ -e /dev/kvm ]] && chmod 0666 /dev/kvm 2>/dev/null || true

# --- android-dev container (image + launcher baked in) --------------------
if command -v run-android-dev >/dev/null; then
  run-android-dev            # single source of truth for the run args (vm/run-container.sh)
else
  echo "!! run-android-dev not found — golden image may be stale; rebuild via ./vm/install.sh"
fi

# --- Chrome Remote Desktop: resume only if this node was registered -------
# (primary node only; workers stay headless). Config persists on the boot disk.
for cfg in /home/*/.config/chrome-remote-desktop; do
  compgen -G "$cfg/host#*.json" >/dev/null || continue
  u="$(stat -c '%U' "$cfg")"
  echo "CRD host config found for '$u' — ensuring service is up."
  systemctl enable --now "chrome-remote-desktop@$u" || true
done
echo "=== golden startup done $(date -u) ==="
