#!/usr/bin/env bash
# Refresh the baked helper scripts (push-build, warm-repo) on a running node — a quick way
# to iterate on them without a full re-bake. For provisioner/image changes, re-run
# ./vm/install.sh instead. Usage:
#   ./vm/push-repo.sh [name]        # default: $INSTANCE
source "$(dirname "$0")/config.sh"

NAME="${1:-$INSTANCE}"

echo "Waiting for SSH on $NAME…"
wait_remote "$NAME" 'true'

gcloud compute scp --zone="$ZONE" --project="$PROJECT" \
  "$REPO_ROOT/scripts/push-build.sh" "$REPO_ROOT/scripts/warm-repo.sh" "$NAME":/tmp/
ssh_vm "$NAME" '
  set -e
  sudo install -m 0755 /tmp/push-build.sh /usr/local/bin/push-build
  sudo install -m 0755 /tmp/warm-repo.sh /usr/local/bin/warm-repo
  rm -f /tmp/push-build.sh /tmp/warm-repo.sh
  echo "helper scripts updated."
'
