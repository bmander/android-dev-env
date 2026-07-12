#!/usr/bin/env bash
# GCP-native fleet: a Managed Instance Group (MIG) of headless workers backed by the
# android-dev-tmpl instance template. Scale by target size — this is what the Console's
# "Number of instances" slider drives, so up/down works from the browser or mobile app too.
#
#   ./vm/mig.sh up N          # ensure the MIG exists, set target size to N
#   ./vm/mig.sh down          # target size 0 (keeps the MIG; all workers deleted)
#   ./vm/mig.sh list          # list the managed worker instances
#   ./vm/mig.sh status        # show target size + which template it's on
#   ./vm/mig.sh set-template  # point the MIG at the current $TEMPLATE (after ./vm/template.sh --force)
#   ./vm/mig.sh delete        # delete the MIG entirely
#
# Console: Compute Engine → Instance groups → android-dev-mig → Edit → Number of instances.
#
# NOTE: a MIG self-heals — deleting a member (or running `selfdestruct` on one) makes the group
# respawn it. To shrink the fleet, resize DOWN; don't nuke individual members. Workers are
# headless (SSH/Claude only) and interchangeable — for a per-issue node use ./vm/create.sh --issue.
source "$(dirname "$0")/config.sh"

mig_exists() { gcloud compute instance-groups managed describe "$MIG" --zone="$ZONE" --project="$PROJECT" >/dev/null 2>&1; }

ensure_mig() {
  mig_exists && return 0
  if ! gcloud compute instance-templates describe "$TEMPLATE" --project="$PROJECT" >/dev/null 2>&1; then
    echo "Instance template '$TEMPLATE' not found. Build it once with:  ./vm/template.sh" >&2
    exit 1
  fi
  echo "Creating MIG '$MIG' from '$TEMPLATE' (size 0) …"
  # Distinct base name (android-dev-mig-*) so these don't collide with fleet.sh's standalone
  # android-dev-w-* workers — `fleet.sh down` matches ^android-dev-w- and would fight self-heal.
  gcloud compute instance-groups managed create "$MIG" \
    --project="$PROJECT" --zone="$ZONE" --template="$TEMPLATE" --size=0 \
    --base-instance-name=android-dev-mig
}

resize() { gcloud compute instance-groups managed resize "$MIG" --size="$1" --zone="$ZONE" --project="$PROJECT"; }

CMD="${1:-}"
case "$CMD" in
  up)
    require_env
    N="${2:-}"; [[ "$N" =~ ^[0-9]+$ ]] || { echo "usage: mig.sh up N" >&2; exit 1; }
    ensure_mig
    echo "Resizing '$MIG' → $N …"; resize "$N"
    ;;
  down)
    mig_exists || { echo "no MIG '$MIG' — nothing to do"; exit 0; }
    echo "Resizing '$MIG' → 0 …"; resize 0
    ;;
  list)
    mig_exists || { echo "no MIG '$MIG'"; exit 0; }
    gcloud compute instance-groups managed list-instances "$MIG" --zone="$ZONE" --project="$PROJECT" \
      --format="table(instance.basename(), instanceStatus, currentAction)"
    ;;
  status)
    mig_exists || { echo "no MIG '$MIG'"; exit 0; }
    gcloud compute instance-groups managed describe "$MIG" --zone="$ZONE" --project="$PROJECT" \
      --format="table(name, targetSize, instanceTemplate.basename())"
    ;;
  set-template)
    ensure_mig
    gcloud compute instance-groups managed set-instance-template "$MIG" --template="$TEMPLATE" \
      --zone="$ZONE" --project="$PROJECT"
    echo "MIG now points at '$TEMPLATE'. Existing workers keep the old config until recreated"
    echo "(resize down/up, or: gcloud compute instance-groups managed rolling-action replace $MIG --zone=$ZONE)."
    ;;
  delete)
    mig_exists || { echo "no MIG '$MIG'"; exit 0; }
    gcloud compute instance-groups managed delete "$MIG" --zone="$ZONE" --project="$PROJECT" -q
    ;;
  *)
    echo "usage: mig.sh {up N | down | list | status | set-template | delete}" >&2
    exit 1 ;;
esac
