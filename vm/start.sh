#!/usr/bin/env bash
# Resume the paused VM. Startup script re-runs; container comes back via --restart.
source "$(dirname "$0")/config.sh"
gcloud compute instances start "$INSTANCE" --zone="$ZONE" --project="$PROJECT"
echo "Started. Tailscale + CRD + the android-dev container come back automatically."
echo "Enter the container:  ./vm/ssh.sh  then  sudo docker exec -it -u dev android-dev bash"
