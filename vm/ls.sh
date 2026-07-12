#!/usr/bin/env bash
# List every billable Compute resource in $PROJECT: instances (any zone), disks, custom
# images, and snapshots — the same set ./vm/cleanup.sh would delete, but read-only (touches
# nothing). Handy to see what's still costing money before/after a work session.
#   ./vm/ls.sh
source "$(dirname "$0")/config.sh"

# Print a titled section: the gcloud listing indented, or "(none)" when there's nothing.
# `|| true` so a transient gcloud/auth error on one section doesn't abort the whole report.
section() {
  local title="$1"; shift
  local out; out="$(gcloud compute "$@" --project="$PROJECT" 2>/dev/null)" || true
  printf '\n%s:\n' "$title"
  if [[ -n "$out" ]]; then printf '%s\n' "$out" | sed 's/^/  /'; else echo "  (none)"; fi
}

# Rough daily-cost estimate (us-west1 on-demand). CPU/RAM only for RUNNING instances; disks,
# images and snapshots bill in every state. Machine $/hr mirrors web/admin.py's PRICE map —
# keep the two in sync. This is an approximation, not a bill.
cost_estimate() {
  local inst disks imgs snaps
  inst="$(gcloud compute instances list --project="$PROJECT" --format='value(status,machineType.basename())' 2>/dev/null)"  || true
  disks="$(gcloud compute disks list      --project="$PROJECT" --format='value(sizeGb,type.basename())' 2>/dev/null)"       || true
  imgs="$(gcloud compute images list      --project="$PROJECT" --no-standard-images --format='value(diskSizeGb)' 2>/dev/null)" || true
  snaps="$(gcloud compute snapshots list  --project="$PROJECT" --format='value(diskSizeGb)' 2>/dev/null)"                  || true
  # Tag each line by resource type and stream through awk (gcloud value() fields are
  # tab-separated; awk's default whitespace split handles both the tag space and the tabs).
  { [[ -n "$inst" ]]  && printf '%s\n' "$inst"  | sed 's/^/I /'
    [[ -n "$disks" ]] && printf '%s\n' "$disks" | sed 's/^/D /'
    [[ -n "$imgs" ]]  && printf '%s\n' "$imgs"  | sed 's/^/M /'
    [[ -n "$snaps" ]] && printf '%s\n' "$snaps" | sed 's/^/S /'
    true; } | awk '
    BEGIN {
      hr["e2-standard-2"]=0.067; hr["e2-standard-4"]=0.134; hr["e2-standard-8"]=0.268;
      hr["e2-standard-16"]=0.536; hr["n2-standard-4"]=0.194; hr["n2-standard-8"]=0.388;
      hr["n2-standard-16"]=0.776; hr["c3-standard-8"]=0.42;            # $/hr on-demand
      gb["pd-standard"]=0.04; gb["pd-balanced"]=0.10; gb["pd-ssd"]=0.17; # $/GB-month
      IMG_GB=0.05; SNAP_GB=0.026; MO=30.4; day=0; unknown="";
    }
    $1=="I" && $2=="RUNNING" { if($3 in hr) day+=hr[$3]*24; else unknown=unknown" "$3 }
    $1=="D" { day += $2*(($3 in gb)?gb[$3]:0.10)/MO }
    $1=="M" { day += $2*IMG_GB/MO }
    $1=="S" { day += $2*SNAP_GB/MO }
    END {
      printf "\nEstimated cost: $%.2f/day  (~$%.0f/mo)\n", day, day*MO;
      if(unknown!="") printf "  note: unpriced machine type(s), not counted:%s\n", unknown;
      print  "  rough us-west1 on-demand estimate — CPU/RAM for RUNNING instances only; disks/images/snapshots always bill.";
    }'
}

echo "== billable resources in $PROJECT =="
# Note: a STOPPED instance bills $0 for CPU/RAM but still bills for its disk (listed under
# Disks). Instances/disks are per-zone; images/snapshots are project-global.
section "Instances" \
  instances list --format="table(name, zone.basename():label=ZONE, status, machineType.basename():label=MACHINE)"
section "Disks" \
  disks list --format="table(name, zone.basename():label=ZONE, sizeGb:label=GB, type.basename():label=TYPE)"
section "Custom images" \
  images list --no-standard-images --format="table(name, diskSizeGb:label=GB, family)"
section "Snapshots" \
  snapshots list --format="table(name, diskSizeGb:label=GB, storageBytes.size():label=STORED)"

cost_estimate
