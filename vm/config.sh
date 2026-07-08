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
export DISK_GB="${DISK_GB:-60}"
export IMAGE_FAMILY="${IMAGE_FAMILY:-ubuntu-2204-lts}"
export IMAGE_PROJECT="${IMAGE_PROJECT:-ubuntu-os-cloud}"
export SNAPSHOT="${SNAPSHOT:-android-dev-snap}"

require_env() {
  if [[ -z "${TAILSCALE_AUTHKEY:-}" ]]; then
    echo "TAILSCALE_AUTHKEY is not set. Add it to .env (cp .env.example .env) or export it." >&2
    echo "Get a key: https://login.tailscale.com/admin/settings/keys" >&2
    return 1
  fi
}
