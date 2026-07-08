#!/usr/bin/env bash
# SSH to the VM. Pass a command to run non-interactively, else opens a shell.
source "$(dirname "$0")/config.sh"
if [[ $# -gt 0 ]]; then
  gcloud compute ssh "$INSTANCE" --zone="$ZONE" --project="$PROJECT" --command "$*"
else
  gcloud compute ssh "$INSTANCE" --zone="$ZONE" --project="$PROJECT"
fi
