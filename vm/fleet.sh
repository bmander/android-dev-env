#!/usr/bin/env bash
# Bulk spin up / tear down headless android-dev worker nodes from the golden image.
#   ./vm/fleet.sh up N [basename]    # create N nodes basename-1..N in parallel (default base: android-dev-w)
#   ./vm/fleet.sh down [basename]    # delete all nodes matching basename-*
#   ./vm/fleet.sh list [basename]    # show nodes
# Workers are headless (SKIP_CRD=1) and share the reusable TAILSCALE_AUTHKEY.
source "$(dirname "$0")/config.sh"

CMD="${1:-}"
case "$CMD" in
  up)
    require_env
    N="${2:-}"; BASE="${3:-android-dev-w}"
    [[ "$N" =~ ^[0-9]+$ ]] || { echo "usage: fleet.sh up N [basename]" >&2; exit 1; }
    pids=()
    for i in $(seq 1 "$N"); do
      echo "--- launching ${BASE}-${i} ---"
      SKIP_CRD=1 "$(dirname "$0")/create.sh" "${BASE}-${i}" & pids+=($!)
    done
    wait "${pids[@]}"
    echo "fleet up: ${N} x ${BASE}-*"
    ;;
  down)
    BASE="${2:-android-dev-w}"
    NODES=()
    while IFS= read -r n; do [[ -n "$n" ]] && NODES+=("$n"); done < <(gcloud compute instances list \
      --project="$PROJECT" --filter="name~^${BASE}- AND zone:($ZONE)" --format="value(name)")
    [[ ${#NODES[@]} -gt 0 ]] || { echo "no nodes matching ${BASE}-*"; exit 0; }
    printf 'deleting: %s\n' "${NODES[@]}"
    delete_instances "${NODES[@]}"
    ;;
  list)
    BASE="${2:-android-dev}"
    gcloud compute instances list --project="$PROJECT" --filter="name~^${BASE}" \
      --format="table(name,status,machineType.basename(),lastStartTimestamp)"
    ;;
  *)
    echo "usage: fleet.sh {up N [basename] | down [basename] | list [basename]}" >&2
    exit 1
    ;;
esac
