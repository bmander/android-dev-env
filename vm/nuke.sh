#!/usr/bin/env bash
# Shut a node all the way down: delete the instance and its disks → $0. Nothing is
# kept — the durable state is the golden image plus your pushed git work. This is the
# end of the per-issue workflow (spin up, do the work, push, nuke).
# To pause instead (keep the disk, resume fast), use ./vm/stop.sh.
#   ./vm/nuke.sh [name]
source "$(dirname "$0")/config.sh"
NAME="${1:-$INSTANCE}"

delete_instances "$NAME"
echo "$NAME is gone (\$0). Spin up a fresh one with ./vm/create.sh."
