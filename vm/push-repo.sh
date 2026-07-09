#!/usr/bin/env bash
# Refresh the baked helper scripts (push-build, warm-repo) on a running node — a quick way
# to iterate on them without a full re-bake. For provisioner/image changes, re-run
# ./vm/install.sh instead. Usage:
#   ./vm/push-repo.sh [name]        # default: $INSTANCE
source "$(dirname "$0")/config.sh"

NAME="${1:-$INSTANCE}"

echo "Waiting for SSH on $NAME…"
wait_remote "$NAME" 'true'
install_helpers "$NAME"
echo "helper scripts + terminfo updated on $NAME."
