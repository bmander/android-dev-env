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

# Self-configure from instance metadata when there's no .env PROJECT — i.e. we're the
# toolkit running ON a GCE node (cloned from GitHub at boot, no .env shipped) so a node
# can spawn/manage nodes. Everything create.sh needs was baked into this node's own
# metadata at create/template time; read it back rather than requiring a hand-copied
# .env with secrets on disk. Only fires when PROJECT is unset, so laptop runs (which
# have a .env) never touch the metadata server, and env/.env still win where set.
if [[ -z "${PROJECT:-}" ]] && curl -s -m 1 -H 'Metadata-Flavor: Google' \
     http://metadata.google.internal/computeMetadata/v1/ >/dev/null 2>&1; then
  _md() { curl -s -m 2 -H 'Metadata-Flavor: Google' \
    "http://metadata.google.internal/computeMetadata/v1/$1" 2>/dev/null; }
  PROJECT="$(_md project/project-id)"
  ZONE="${ZONE:-$(basename "$(_md instance/zone)")}"   # node's own zone wins over the default
  # Fill any per-node secret/setting the environment left unset (`:=` skips ones already set).
  : "${TAILSCALE_AUTHKEY:=$(_md instance/attributes/tailscale-authkey)}"
  : "${PHONE_TS_HOST:=$(_md instance/attributes/phone-ts-host)}"
  : "${ANTHROPIC_API_KEY:=$(_md instance/attributes/anthropic-api-key)}"
  : "${CLAUDE_CODE_OAUTH_TOKEN:=$(_md instance/attributes/claude-oauth-token)}"
  : "${GITHUB_TOKEN:=$(_md instance/attributes/github-token)}"
  : "${GIT_REPO:=$(_md instance/attributes/git-repo)}"
  : "${GIT_BRANCH:=$(_md instance/attributes/git-branch)}"
  : "${GRADLE_WARM_TASK:=$(_md instance/attributes/gradle-warm-task)}"
  export TAILSCALE_AUTHKEY PHONE_TS_HOST ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN \
    GITHUB_TOKEN GIT_REPO GIT_BRANCH GRADLE_WARM_TASK
fi

# PROJECT is required. On a laptop it must come from .env — never fall back to the ambient
# `gcloud config` project (too easy to target the wrong one). On a GCE node it's filled from
# the metadata server above (the node's own project).
if [[ -z "${PROJECT:-}" ]]; then
  echo "PROJECT is not set. Add it to .env (see .env.example)." >&2
  echo "We intentionally do NOT use the global 'gcloud config' project." >&2
  return 1 2>/dev/null || exit 1
fi
export PROJECT
export ZONE="${ZONE:-us-west1-b}"
export INSTANCE="${INSTANCE:-android-dev}"
export MACHINE="${MACHINE:-e2-standard-4}"     # 4 vCPU / 16GB
export DISK_GB="${DISK_GB:-60}"    # headless SDK + repo + Gradle cache fit comfortably
export IMAGE_FAMILY="${IMAGE_FAMILY:-ubuntu-2204-lts}"
export IMAGE_PROJECT="${IMAGE_PROJECT:-ubuntu-os-cloud}"
export GOLDEN_IMAGE="${GOLDEN_IMAGE:-android-dev-golden}"
export TEMPLATE="${TEMPLATE:-android-dev-tmpl}"   # instance template (GCP-native create/fleet)
export MIG="${MIG:-android-dev-mig}"              # managed instance group for the worker fleet
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
#   wait_remote "$host" 'test -f /var/lib/android-dev-provisioned'
wait_remote() {
  local host="$1"; shift
  until ssh_vm "$host" "until $*; do sleep 5; done" >/dev/null 2>&1; do printf '.'; sleep 5; done
}

# Delete one or more instances (and their disks) — the teardown convention in one place.
delete_instances() { gcloud compute instances delete "$@" --zone="$ZONE" --project="$PROJECT" --delete-disks=all -q; }

# Copy files to <host>:/tmp/ (same --zone/--project convention as ssh_vm).
scp_vm() { local host="$1"; shift; gcloud compute scp "$@" "$host":/tmp/ --zone="$ZONE" --project="$PROJECT"; }

# Copy the helper scripts + Ghostty terminfo to <host> and install them into place.
# Used by bake.sh and push-repo.sh (live update) so they can't drift.
install_helpers() {
  scp_vm "$1" "$REPO_ROOT/scripts/push-build.sh" "$REPO_ROOT/scripts/warm-repo.sh" "$REPO_ROOT/scripts/selfdestruct.sh" "$REPO_ROOT/scripts/work-issue.sh" "$REPO_ROOT/scripts/tmux-stats.sh" "$REPO_ROOT/scripts/claude-apply-settings.py" "$REPO_ROOT/vm/CLAUDE.md" "$REPO_ROOT/vm/xterm-ghostty.terminfo"
  ssh_vm "$1" '
    set -e
    sudo install -m 0755 /tmp/push-build.sh /usr/local/bin/push-build
    sudo install -m 0755 /tmp/warm-repo.sh /usr/local/bin/warm-repo
    sudo install -m 0755 /tmp/selfdestruct.sh /usr/local/bin/selfdestruct
    sudo install -m 0755 /tmp/work-issue.sh /usr/local/bin/work-issue
    sudo install -m 0755 /tmp/tmux-stats.sh /usr/local/bin/tmux-stats
    sudo install -m 0755 /tmp/claude-apply-settings.py /usr/local/bin/claude-apply-settings
    sudo install -D -m 0644 /tmp/CLAUDE.md /etc/claude-code/CLAUDE.md   # system-scope Claude memory
    sudo tic -x -o /usr/share/terminfo /tmp/xterm-ghostty.terminfo
    rm -f /tmp/push-build.sh /tmp/warm-repo.sh /tmp/selfdestruct.sh /tmp/work-issue.sh /tmp/tmux-stats.sh /tmp/claude-apply-settings.py /tmp/CLAUDE.md /tmp/xterm-ghostty.terminfo'
}
