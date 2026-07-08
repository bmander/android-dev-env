#!/usr/bin/env bash
# Resume a paused node (default $INSTANCE). Startup re-runs; container comes back via --restart.
#   ./vm/start.sh [name]
source "$(dirname "$0")/config.sh"
NAME="${1:-$INSTANCE}"
gcloud compute instances start "$NAME" --zone="$ZONE" --project="$PROJECT"
echo "Started. Tailscale + CRD come back automatically; the Android toolchain is bare-metal."
echo "SSH in with:  ./vm/ssh.sh   (project lives in ~/work)"
