#!/usr/bin/env bash
# SSH to a node. Pass a command to run it non-interactively, else open a shell.
#   ./vm/ssh.sh                       # pick a node (see below), open a shell
#   ./vm/ssh.sh 'adb devices'         # ...and run a command instead
#   NODE=android-dev-w-1 ./vm/ssh.sh  # target a specific node, skip discovery
#
# With NODE unset, discover the instances in $ZONE: one -> use it; several -> list them
# and ask which; none -> bail. (NODE is still the escape hatch for scripts / exact targeting.)
source "$(dirname "$0")/config.sh"

if [[ -z "${NODE:-}" ]]; then
  NODES=()
  while IFS= read -r n; do [[ -n "$n" ]] && NODES+=("$n"); done < <(gcloud compute instances list \
    --project="$PROJECT" --filter="zone:($ZONE)" --format="value(name)")
  case "${#NODES[@]}" in
    0) echo "No instances in $ZONE / $PROJECT. Spin one up with ./vm/create.sh." >&2; exit 1 ;;
    1) NODE="${NODES[0]}" ;;
    *) echo "Multiple instances in $ZONE — pick one:" >&2
       PS3="node #? "
       select NODE in "${NODES[@]}"; do [[ -n "$NODE" ]] && break; done
       [[ -n "$NODE" ]] || { echo "No node selected." >&2; exit 1; } ;;
  esac
fi

if [[ $# -gt 0 ]]; then
  ssh_vm "$NODE" "$*"
else
  gcloud compute ssh "$NODE" --zone="$ZONE" --project="$PROJECT"
fi
