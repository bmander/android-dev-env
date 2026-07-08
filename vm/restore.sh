#!/usr/bin/env bash
# Rebuild the VM from the snapshot created by nuke.sh. Requires TAILSCALE_AUTHKEY
# (the old node key is gone). All your work volumes are restored from the snapshot.
source "$(dirname "$0")/config.sh"
require_env

echo "Recreating $INSTANCE from snapshot $SNAPSHOT…"
gcloud compute instances create "$INSTANCE" \
  --project="$PROJECT" --zone="$ZONE" --machine-type="$MACHINE" \
  --source-snapshot="$SNAPSHOT" --boot-disk-type=pd-balanced \
  --labels=environment=development,purpose=android-dev \
  --metadata=tailscale-authkey="$TAILSCALE_AUTHKEY",laptop-ts-host="${LAPTOP_TS_HOST:-}" \
  --metadata-from-file=startup-script="$REPO_ROOT/vm/startup-script.sh"
echo "Restored. SSH: ./vm/ssh.sh"
