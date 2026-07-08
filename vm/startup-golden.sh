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

# --- android-dev container (image is baked; just run it) ------------------
LAPTOP_TS_HOST="$(meta laptop-ts-host)"
API_KEY="$(meta anthropic-api-key)"
if docker image inspect android-dev:latest >/dev/null 2>&1; then
  if ! docker ps -a --format '{{.Names}}' | grep -qx android-dev; then
    docker run -d --name android-dev --restart unless-stopped --network=host \
      -e LAPTOP_TS_HOST="${LAPTOP_TS_HOST}" \
      ${API_KEY:+-e ANTHROPIC_API_KEY="${API_KEY}"} \
      -v android-dev-work:/home/dev/work \
      -v android-dev-home:/home/dev/.claude \
      android-dev:latest
    echo "android-dev container started."
  else
    echo "android-dev container already present (restart policy handles reboots)."
  fi
else
  echo "!! android-dev:latest image missing — is this really the golden image?"
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
