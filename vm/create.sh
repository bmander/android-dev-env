#!/usr/bin/env bash
# Create the android-dev VM. Requires TAILSCALE_AUTHKEY in the environment.
# Optional: LAPTOP_TS_HOST=<laptop tailscale ip/name> to wire up the adb loop now.
source "$(dirname "$0")/config.sh"
require_env

echo "Creating $INSTANCE ($MACHINE, ${DISK_GB}GB) in $ZONE / $PROJECT …"
gcloud compute instances create "$INSTANCE" \
  --project="$PROJECT" --zone="$ZONE" \
  --machine-type="$MACHINE" \
  --image-family="$IMAGE_FAMILY" --image-project="$IMAGE_PROJECT" \
  --boot-disk-size="${DISK_GB}GB" --boot-disk-type=pd-balanced \
  --labels=environment=development,purpose=android-dev \
  --metadata=tailscale-authkey="$TAILSCALE_AUTHKEY",laptop-ts-host="${LAPTOP_TS_HOST:-}" \
  --metadata-from-file=startup-script="$REPO_ROOT/vm/startup-script.sh"

echo "Instance created. Syncing repo + building the container (waits for Docker)…"
"$(dirname "$0")/push-repo.sh"
echo
echo "Next: SSH in and finish the one-time setup (see README 'First boot')."
echo "  ./vm/ssh.sh"
