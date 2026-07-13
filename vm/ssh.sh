#!/usr/bin/env bash
# SSH to a node. The FIRST argument (if any) is the instance name; anything after it is a
# command to run non-interactively (else you get a shell).
#   ./vm/ssh.sh                        # pick a node (see below), open a shell
#   ./vm/ssh.sh android-dev-w-1        # shell on that node
#   ./vm/ssh.sh android-dev-w-1 'adb devices'   # ...run a command on it instead
#   NODE=android-dev-w-1 ./vm/ssh.sh ['cmd']    # same, via env (for scripts); arg is the command
#
# Node selection: NODE= env wins; else the first positional arg; else discover the instances
# in $ZONE — one -> use it; several -> list and ask which; none -> bail.
source "$(dirname "$0")/config.sh"

# NODE env is the escape hatch (scripts / exact targeting). Otherwise the first positional arg
# names the instance; consume it so the rest is the optional command.
if [[ -z "${NODE:-}" ]]; then
  if [[ $# -gt 0 ]]; then
    NODE="$1"; shift
  else
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
fi

if [[ $# -gt 0 ]]; then
  ssh_vm "$NODE" "$*"
else
  gcloud compute ssh "$NODE" --zone="$ZONE" --project="$PROJECT"
fi
