#!/usr/bin/env bash
# Delete EVERY billable compute resource in $PROJECT — all instances (any zone/name),
# disks, the golden image (and any other custom image), and any snapshots — so the
# project bills $0. Lists everything and asks to confirm — default is YES (press Enter to
# proceed, 'n' to abort); pass -y to skip the prompt entirely.
#   ./vm/cleanup.sh [-y]
#
# Broader than nuke.sh (one instance): this is the "wipe it all" for a dedicated project.
# It also removes the golden image, so the next start needs a full ./vm/bake.sh.
source "$(dirname "$0")/config.sh"

YES=""
case "${1:-}" in -y|--yes) YES=1 ;; esac

# Gather (instances/disks are per-zone; images/snapshots are global).
INSTANCES="$(gcloud compute instances list --project="$PROJECT" --format='value(name,zone.basename())')"
DISKS="$(gcloud compute disks list --project="$PROJECT" --format='value(name,zone.basename())')"
IMAGES="$(gcloud compute images list --project="$PROJECT" --no-standard-images --format='value(name)')"
SNAPSHOTS="$(gcloud compute snapshots list --project="$PROJECT" --format='value(name)')"

show() { if [[ -n "$1" ]]; then echo "$1" | sed 's/^/  /'; else echo "  (none)"; fi; }
echo "=== billable resources in $PROJECT ==="
echo "Instances:"; show "$INSTANCES"
echo "Disks:";     show "$DISKS"
echo "Images:";    show "$IMAGES"
echo "Snapshots:"; show "$SNAPSHOTS"

if [[ -z "$INSTANCES$DISKS$IMAGES$SNAPSHOTS" ]]; then
  echo; echo "Already clean — $PROJECT is billing \$0."
  exit 0
fi

if [[ -z "$YES" ]]; then
  echo
  read -r -p "Delete ALL of the above from $PROJECT? [Y/n] " ans
  case "$ans" in [Nn]*) echo "Aborted — nothing deleted."; exit 0 ;; esac
fi

# 1) Instances (per zone; --delete-disks=all takes their attached disks with them).
while read -r name zone; do
  [[ -n "$name" ]] || continue
  echo "deleting instance $name ($zone)…"
  gcloud compute instances delete "$name" --zone="$zone" --project="$PROJECT" --delete-disks=all -q
done <<< "$INSTANCES"

# 2) Any disks now unattached (didn't ride along with an instance).
DISKS="$(gcloud compute disks list --project="$PROJECT" --format='value(name,zone.basename())')"
while read -r name zone; do
  [[ -n "$name" ]] || continue
  echo "deleting disk $name ($zone)…"
  gcloud compute disks delete "$name" --zone="$zone" --project="$PROJECT" -q
done <<< "$DISKS"

# 3) Custom images and 4) snapshots (global; names are safe to word-split).
[[ -n "$IMAGES" ]]    && gcloud compute images    delete $IMAGES    --project="$PROJECT" -q
[[ -n "$SNAPSHOTS" ]] && gcloud compute snapshots delete $SNAPSHOTS --project="$PROJECT" -q

echo
echo "Done. $PROJECT is billing \$0. Rebuild from scratch with ./vm/bake.sh."
