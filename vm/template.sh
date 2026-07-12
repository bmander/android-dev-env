#!/usr/bin/env bash
# Build (or rebuild) the GCP instance template that mirrors what ./vm/create.sh bakes into a
# node — golden image, machine, disk, scopes, labels, the startup-golden.sh boot wiring, and
# all the non-issue metadata (Tailscale key, phone host, Claude/GitHub tokens, repo settings).
# Once it exists you can spin nodes up GCP-natively, no laptop or CI needed:
#   - Console: Compute Engine → Instance templates → android-dev-tmpl → Create VM
#   - CLI:     gcloud compute instances create NAME --source-instance-template=android-dev-tmpl
#   - Fleet:   ./vm/mig.sh up N     (a Managed Instance Group backed by this template)
# Per-issue workers still go through ./vm/create.sh --issue N (dynamic metadata + the SSH kick
# that starts the worker without a human login).
#
# SECRETS: the template stores the reusable Tailscale key and any tokens in its metadata. That
# lives in your (private) GCP project, not the public repo — but rotate the template (re-run
# this) when those keys change, since they're baked in.
#
# Templates are IMMUTABLE: re-run with --force to replace after changing .env / startup-golden.sh.
# If a MIG references the template, roll it forward afterward with ./vm/mig.sh set-template.
#   Usage: ./vm/template.sh [-f|--force]
source "$(dirname "$0")/config.sh"
require_env

FORCE=0
[[ "${1:-}" == "-f" || "${1:-}" == "--force" ]] && FORCE=1

# Same GitHub-token resolution as create.sh (for cloning GIT_REPO): .env, else local gh login.
GITHUB_TOKEN="${GITHUB_TOKEN:-$(gh auth token 2>/dev/null || true)}"
if [[ -n "${GIT_REPO:-}" && -z "$GITHUB_TOKEN" ]]; then
  echo "note: GIT_REPO set but no GitHub token — private clones will fail on nodes from this template." >&2
fi

# Nested virtualization (KVM) — Intel-only, same guard as create.sh.
NV_FLAG=""
if [[ -n "${NESTED_VIRT:-}" ]]; then
  case "$MACHINE" in
    e2-*|t2a-*|t2d-*|n2d-*|c2d-*|c3d-*)
      echo "NESTED_VIRT needs an INTEL machine — GCP nested virt is VT-x only." >&2
      echo "Set MACHINE=n2-standard-4 (or n2-standard-8) in .env." >&2
      exit 1 ;;
  esac
  NV_FLAG="--enable-nested-virtualization"
fi

# The golden image must exist first (./vm/bake.sh).
if ! gcloud compute images describe "$GOLDEN_IMAGE" --project="$PROJECT" >/dev/null 2>&1; then
  echo "Golden image '$GOLDEN_IMAGE' not found. Build it once with:  ./vm/bake.sh" >&2
  exit 1
fi

# Templates can't be edited — recreate to update. Refuse to clobber unless --force.
if gcloud compute instance-templates describe "$TEMPLATE" --project="$PROJECT" >/dev/null 2>&1; then
  if [[ "$FORCE" != 1 ]]; then
    echo "Instance template '$TEMPLATE' already exists. Re-run with --force to replace it." >&2
    echo "(If a MIG uses it, run ./vm/mig.sh set-template afterward to roll nodes onto the new one.)" >&2
    exit 1
  fi
  echo "Replacing existing template '$TEMPLATE' …"
  gcloud compute instance-templates delete "$TEMPLATE" --project="$PROJECT" -q
fi

echo "Creating instance template '$TEMPLATE' ($MACHINE${NV_FLAG:+, KVM}) from $GOLDEN_IMAGE …"
gcloud compute instance-templates create "$TEMPLATE" \
  --project="$PROJECT" --machine-type="$MACHINE" $NV_FLAG \
  --image="$GOLDEN_IMAGE" --image-project="$PROJECT" \
  --boot-disk-type=pd-balanced --boot-disk-size="${DISK_GB}GB" \
  --labels=environment=development,purpose=android-dev \
  --scopes=https://www.googleapis.com/auth/compute \
  --metadata=tailscale-authkey="$TAILSCALE_AUTHKEY",phone-ts-host="${PHONE_TS_HOST:-}",anthropic-api-key="${ANTHROPIC_API_KEY:-}",claude-oauth-token="${CLAUDE_CODE_OAUTH_TOKEN:-}",github-token="${GITHUB_TOKEN}",git-repo="${GIT_REPO:-}",git-branch="${GIT_BRANCH:-}",gradle-warm-task="${GRADLE_WARM_TASK:-}" \
  --metadata-from-file=startup-script="$REPO_ROOT/vm/startup-golden.sh"

echo
echo "Done. Nodes from '$TEMPLATE' are headless (no CRD) and self-provision on boot."
echo "  Console:  Compute Engine → Instance templates → $TEMPLATE → Create VM"
echo "  CLI:      gcloud compute instances create NAME --source-instance-template=$TEMPLATE --zone=$ZONE --project=$PROJECT"
echo "  Fleet:    ./vm/mig.sh up N"
