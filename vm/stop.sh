#!/usr/bin/env bash
# Pause a node (default $INSTANCE): stop compute billing on a dime. Only the boot disk
# keeps costing (~$0.10/GB/mo, so ~$15/mo at the 150GB default). Resume with start.sh;
# for $0 use nuke.sh instead.
#   ./vm/stop.sh [name]
source "$(dirname "$0")/config.sh"
NAME="${1:-$INSTANCE}"
gcloud compute instances stop "$NAME" --zone="$ZONE" --project="$PROJECT"
echo "Stopped. Resume with ./vm/start.sh — for literal \$0 use ./vm/nuke.sh instead."
