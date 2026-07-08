#!/usr/bin/env bash
# Pause: stop compute billing on a dime. Only the boot disk keeps costing (~$2-3/mo
# for 60GB). Everything (container, work volume, tailscale, CRD) resumes with start.sh.
source "$(dirname "$0")/config.sh"
gcloud compute instances stop "$INSTANCE" --zone="$ZONE" --project="$PROJECT"
echo "Stopped. Resume with ./vm/start.sh — for literal \$0 use ./vm/nuke.sh instead."
