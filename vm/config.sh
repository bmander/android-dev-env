#!/usr/bin/env bash
# Shared config for the vm/ lifecycle scripts. A gitignored .env at the repo root is
# the source of truth: it's loaded here and overrides the shell environment; the
# defaults below fill in anything .env (and the environment) leave unset.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REPO_ROOT="$(cd "$HERE/.." && pwd)"

# Load .env (repo root) if present. `set -a` exports everything it defines.
if [[ -f "$REPO_ROOT/.env" ]]; then
  set -a; . "$REPO_ROOT/.env"; set +a
fi

# PROJECT is required and must come from .env — never fall back to the ambient
# `gcloud config` project (too easy to target the wrong one).
if [[ -z "${PROJECT:-}" ]]; then
  echo "PROJECT is not set. Add it to .env (see .env.example)." >&2
  echo "We intentionally do NOT use the global 'gcloud config' project." >&2
  return 1 2>/dev/null || exit 1
fi
export PROJECT
export ZONE="${ZONE:-us-west1-b}"
export INSTANCE="${INSTANCE:-android-dev}"
export MACHINE="${MACHINE:-e2-standard-4}"     # 4 vCPU / 16GB
export DISK_GB="${DISK_GB:-150}"   # roomy for Studio + several emulator system images
export IMAGE_FAMILY="${IMAGE_FAMILY:-ubuntu-2204-lts}"
export IMAGE_PROJECT="${IMAGE_PROJECT:-ubuntu-os-cloud}"
export GOLDEN_IMAGE="${GOLDEN_IMAGE:-android-dev-golden}"
export NESTED_VIRT="${NESTED_VIRT:-}"   # set to 1 (+ an N2/C-series MACHINE) to run emulators (KVM)
# The bake builder is throwaway and short-lived, so make it beefy (~pennies): a
# full-speed n2 + SSD disk speeds the dpkg/unzip/CPU parts of the build. (Downloads
# and image-create don't scale with vCPUs, so this only trims part of the ~13 min.)
export BUILDER_MACHINE="${BUILDER_MACHINE:-n2-standard-8}"
export BUILDER_DISK_TYPE="${BUILDER_DISK_TYPE:-pd-ssd}"

require_env() {
  if [[ -z "${TAILSCALE_AUTHKEY:-}" ]]; then
    echo "TAILSCALE_AUTHKEY is not set. Add it to .env (cp .env.example .env) or export it." >&2
    echo "Get a key: https://login.tailscale.com/admin/settings/keys" >&2
    return 1
  fi
}

# Run a command on a VM over SSH. Shared by every vm/ script so the
# --zone/--project (and any future IAP/flags) convention lives in one place.
ssh_vm() { local host="$1"; shift; gcloud compute ssh "$host" --zone="$ZONE" --project="$PROJECT" --command "$*"; }

# Block until a remote test-command succeeds on <host>. Retries the SSH connection
# until the VM is reachable, then loops server-side inside a single session — so a
# whole boot-wait costs ~one SSH handshake instead of one per poll.
#   wait_remote "$host" 'command -v docker >/dev/null'
wait_remote() {
  local host="$1"; shift
  until ssh_vm "$host" "until $*; do sleep 5; done" >/dev/null 2>&1; do printf '.'; sleep 5; done
}

# Delete one or more instances (and their disks) — the teardown convention in one place.
delete_instances() { gcloud compute instances delete "$@" --zone="$ZONE" --project="$PROJECT" --delete-disks=all -q; }
