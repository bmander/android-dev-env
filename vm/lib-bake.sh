#!/usr/bin/env bash
# Shared bake helpers for install.sh (fresh builder) and reimage.sh (configured seed).
# Assumes vm/config.sh is already sourced (provides ssh_vm, ZONE, PROJECT, GOLDEN_IMAGE).

# Strip per-machine identity from <host> so the resulting image can be cloned safely.
# KEEPS everything else — the android-dev image and any configured home-dir state, e.g.
# a fully set-up Android Studio (~/Android/Sdk, accepted licenses, ~/.config prefs).
generalize_instance() {
  ssh_vm "$1" '
    set -e
    sudo systemctl stop tailscaled 2>/dev/null || true
    sudo rm -f /var/lib/tailscale/tailscaled.state* 2>/dev/null || true
    for u in $(ls /home 2>/dev/null); do                       # drop the seed CRD registration
      sudo systemctl disable --now "chrome-remote-desktop@$u" 2>/dev/null || true
    done
    sudo rm -rf /home/*/.config/chrome-remote-desktop 2>/dev/null || true   # re-registers per node
    sudo truncate -s 0 /etc/machine-id                         # regenerated per instance
    sudo rm -f /etc/ssh/ssh_host_*                             # GCE regenerates on boot
    sudo cloud-init clean --logs 2>/dev/null || true
    sudo rm -f /var/log/android-dev-startup.log
    sudo apt-get clean 2>/dev/null || true
    echo generalized.
  '
}

# Stop <host> and (re)create the golden image from its boot disk.
bake_golden() {
  local host="$1"
  gcloud compute instances stop "$host" --zone="$ZONE" --project="$PROJECT"
  gcloud compute images delete "$GOLDEN_IMAGE" --project="$PROJECT" -q 2>/dev/null || true
  gcloud compute images create "$GOLDEN_IMAGE" \
    --project="$PROJECT" --source-disk="$host" --source-disk-zone="$ZONE" \
    --family=android-dev --labels=purpose=android-dev-golden
}
