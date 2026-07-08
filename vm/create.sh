#!/usr/bin/env bash
# Create an android-dev node from the golden image (fast boot). Usage:
#   ./vm/create.sh [name]        # default name: $INSTANCE (android-dev)
# Requires a reusable TAILSCALE_AUTHKEY in .env. CRD is offered interactively unless
# SKIP_CRD=1 (fleet workers set that; see vm/fleet.sh).
source "$(dirname "$0")/config.sh"
require_env

NAME="${1:-$INSTANCE}"

# The golden image must exist first (run ./vm/install.sh once).
if ! gcloud compute images describe "$GOLDEN_IMAGE" --project="$PROJECT" >/dev/null 2>&1; then
  echo "Golden image '$GOLDEN_IMAGE' not found. Build it once with:  ./vm/install.sh" >&2
  exit 1
fi

# --- Claude Code auth: long-lived subscription OAuth token -----------------
# Minted once on this machine with `claude setup-token`, cached in .env, then reused
# for every node (including headless fleet workers). Skipped if you already set
# ANTHROPIC_API_KEY, or if there's no TTY / no local claude (e.g. fleet.sh workers).
if [[ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" && -z "${ANTHROPIC_API_KEY:-}" && -t 0 ]] && command -v claude >/dev/null; then
  echo
  echo "No Claude auth in .env — minting a long-lived token with 'claude setup-token'"
  echo "(requires a Claude subscription). Complete the browser authorization it shows."
  tokout="$(mktemp)"
  claude setup-token 2>&1 | tee "$tokout" || true
  CLAUDE_CODE_OAUTH_TOKEN="$(grep -oE 'sk-ant-oat[0-9A-Za-z_-]+' "$tokout" | tail -1 || true)"
  rm -f "$tokout"
  if [[ -z "$CLAUDE_CODE_OAUTH_TOKEN" ]]; then
    printf 'Paste the long-lived token shown above (or press Enter to skip): '
    read -r CLAUDE_CODE_OAUTH_TOKEN
  fi
  if [[ -n "$CLAUDE_CODE_OAUTH_TOKEN" ]] && ! grep -q '^CLAUDE_CODE_OAUTH_TOKEN=' "$REPO_ROOT/.env" 2>/dev/null; then
    printf '\n# Long-lived Claude Code OAuth token (from `claude setup-token`)\nCLAUDE_CODE_OAUTH_TOKEN=%s\n' \
      "$CLAUDE_CODE_OAUTH_TOKEN" >> "$REPO_ROOT/.env"
    echo "Cached CLAUDE_CODE_OAUTH_TOKEN in .env — future nodes reuse it non-interactively."
  fi
fi

echo "Creating $NAME ($MACHINE) from $GOLDEN_IMAGE in $ZONE / $PROJECT …"
gcloud compute instances create "$NAME" \
  --project="$PROJECT" --zone="$ZONE" --machine-type="$MACHINE" \
  --image="$GOLDEN_IMAGE" --boot-disk-type=pd-balanced \
  --labels=environment=development,purpose=android-dev \
  --metadata=tailscale-authkey="$TAILSCALE_AUTHKEY",laptop-ts-host="${LAPTOP_TS_HOST:-}",anthropic-api-key="${ANTHROPIC_API_KEY:-}",claude-oauth-token="${CLAUDE_CODE_OAUTH_TOKEN:-}" \
  --metadata-from-file=startup-script="$REPO_ROOT/vm/startup-golden.sh"

echo "Waiting for the android-dev container to come up (baked image, no build)…"
wait_remote "$NAME" 'sudo docker ps --format "{{.Names}}" | grep -qx android-dev'
echo " container up."

# --- Chrome Remote Desktop (primary node only) ----------------------------
if [[ "${SKIP_CRD:-}" == "1" ]]; then
  echo "SKIP_CRD=1 — headless worker, no desktop."
elif [[ -z "${CRD_PIN:-}" ]]; then
  echo "CRD_PIN not set in .env — skipping desktop. Register later: ./vm/crd-setup.sh '<code>'"
else
  CRD_URL="https://remotedesktop.google.com/headless"
  echo
  echo "Set up the Chrome Remote Desktop for this node (one-time). To get an auth code:"
  echo "  1. Opening $CRD_URL …   2. Begin -> Next -> Authorize   3. copy the command/code."
  command -v open >/dev/null && open "$CRD_URL" 2>/dev/null || echo "     (open $CRD_URL manually)"
  echo
  printf 'Paste the auth code (or the full start-host command), or press Enter to skip: '
  read -r CRD_INPUT
  if [[ -n "$CRD_INPUT" ]]; then
    if [[ "$CRD_INPUT" == *--code=* ]]; then     # accept a full pasted start-host command
      CODE="${CRD_INPUT#*--code=}"; CODE="${CODE%% *}"; CODE="${CODE//[\"\']/}"
    else                                          # ...or a bare code
      CODE="$CRD_INPUT"
    fi
    "$(dirname "$0")/crd-setup.sh" "$CODE" "$NAME"
  else
    echo "Skipped. Register later with: ./vm/crd-setup.sh '<code>' $NAME"
  fi
fi

echo
echo "Done. '$NAME' is up. Desktop (if registered): https://remotedesktop.google.com/access"
echo "SSH:  gcloud compute ssh $NAME --zone=$ZONE --project=$PROJECT"
