#!/usr/bin/env bash
# Create an android-dev node from the golden image (fast boot). Usage:
#   ./vm/create.sh [name]        # default name: $INSTANCE (android-dev)
# Requires a reusable TAILSCALE_AUTHKEY in .env. CRD is offered interactively unless
# SKIP_CRD=1 (fleet workers set that; see vm/fleet.sh).
source "$(dirname "$0")/config.sh"
require_env

NAME="${1:-$INSTANCE}"

# The golden image must exist first (run ./vm/bake-image.sh once).
if ! gcloud compute images describe "$GOLDEN_IMAGE" --project="$PROJECT" >/dev/null 2>&1; then
  echo "Golden image '$GOLDEN_IMAGE' not found. Build it once with:  ./vm/bake-image.sh" >&2
  exit 1
fi

echo "Creating $NAME ($MACHINE) from $GOLDEN_IMAGE in $ZONE / $PROJECT …"
gcloud compute instances create "$NAME" \
  --project="$PROJECT" --zone="$ZONE" --machine-type="$MACHINE" \
  --image="$GOLDEN_IMAGE" --boot-disk-type=pd-balanced \
  --labels=environment=development,purpose=android-dev \
  --metadata=tailscale-authkey="$TAILSCALE_AUTHKEY",laptop-ts-host="${LAPTOP_TS_HOST:-}",anthropic-api-key="${ANTHROPIC_API_KEY:-}" \
  --metadata-from-file=startup-script="$REPO_ROOT/vm/startup-golden.sh"

echo "Waiting for the android-dev container to come up (baked image, no build)…"
until gcloud compute ssh "$NAME" --zone="$ZONE" --project="$PROJECT" \
      --command 'sudo docker ps --format "{{.Names}}" | grep -qx android-dev' >/dev/null 2>&1; do
  printf '.'; sleep 5
done
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
    if [[ "$CRD_INPUT" == *--code=* ]]; then
      CODE="$(printf '%s' "$CRD_INPUT" | sed -n 's/.*--code=["'\'']\{0,1\}\([^"'\'' ]*\).*/\1/p')"
    else
      CODE="$CRD_INPUT"
    fi
    INSTANCE="$NAME" "$(dirname "$0")/crd-setup.sh" "$CODE"
  else
    echo "Skipped. Register later with: ./vm/crd-setup.sh '<code>'  (INSTANCE=$NAME)"
  fi
fi

echo
echo "Done. '$NAME' is up. Desktop (if registered): https://remotedesktop.google.com/access"
echo "SSH:  gcloud compute ssh $NAME --zone=$ZONE --project=$PROJECT"
