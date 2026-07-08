#!/usr/bin/env bash
# SSH to a node (default $INSTANCE; override with NODE=<name> for a worker/custom node).
# Pass a command to run non-interactively, else opens a shell.
#   ./vm/ssh.sh                       # shell into $INSTANCE
#   NODE=android-dev-w-1 ./vm/ssh.sh 'docker ps'
source "$(dirname "$0")/config.sh"
NODE="${NODE:-$INSTANCE}"
if [[ $# -gt 0 ]]; then
  ssh_vm "$NODE" "$*"
else
  gcloud compute ssh "$NODE" --zone="$ZONE" --project="$PROJECT"
fi
