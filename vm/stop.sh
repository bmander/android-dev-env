#!/usr/bin/env bash
# Pause a node (default $INSTANCE): stop compute billing on a dime. Only the boot disk
# keeps costing (~$2-3/mo for 60GB). Everything resumes with start.sh.
#   ./vm/stop.sh [name]
source "$(dirname "$0")/config.sh"
NAME="${1:-$INSTANCE}"
gcloud compute instances stop "$NAME" --zone="$ZONE" --project="$PROJECT"
echo "Stopped. Resume with ./vm/start.sh — for literal \$0 use ./vm/nuke.sh instead."
