#!/usr/bin/env bash
# Teardown to LITERAL $0: snapshot the boot disk (preserves all your state), then
# delete the VM and its disk. Snapshot storage is pennies/month. restore.sh rebuilds.
source "$(dirname "$0")/config.sh"

echo "Snapshotting boot disk -> $SNAPSHOT (this preserves your work)…"
gcloud compute snapshots delete "$SNAPSHOT" --project="$PROJECT" -q 2>/dev/null || true
gcloud compute disks snapshot "$INSTANCE" --zone="$ZONE" --project="$PROJECT" \
  --snapshot-names="$SNAPSHOT"

echo "Deleting instance + boot disk…"
gcloud compute instances delete "$INSTANCE" --zone="$ZONE" --project="$PROJECT" -q

echo "Torn down to \$0 (only the '$SNAPSHOT' snapshot remains). Rebuild: ./vm/restore.sh"
