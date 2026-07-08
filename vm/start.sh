#!/usr/bin/env bash
# Resume a paused node (default $INSTANCE). Startup re-runs; container comes back via --restart.
#   ./vm/start.sh [name]
source "$(dirname "$0")/config.sh"
NAME="${1:-$INSTANCE}"
gcloud compute instances start "$NAME" --zone="$ZONE" --project="$PROJECT"
echo "Started. Tailscale + CRD + the android-dev container come back automatically."
echo "Enter the container:  ./vm/ssh.sh  then  sudo docker exec -it -u dev android-dev bash"
