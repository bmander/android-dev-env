#!/usr/bin/env bash
# Create the android-dev VM. Requires TAILSCALE_AUTHKEY in the environment.
# Optional: LAPTOP_TS_HOST=<laptop tailscale ip/name> to wire up the adb loop now.
source "$(dirname "$0")/config.sh"
require_env

echo "Creating $INSTANCE ($MACHINE, ${DISK_GB}GB) in $ZONE / $PROJECT …"
gcloud compute instances create "$INSTANCE" \
  --project="$PROJECT" --zone="$ZONE" \
  --machine-type="$MACHINE" \
  --image-family="$IMAGE_FAMILY" --image-project="$IMAGE_PROJECT" \
  --boot-disk-size="${DISK_GB}GB" --boot-disk-type=pd-balanced \
  --labels=environment=development,purpose=android-dev \
  --metadata=tailscale-authkey="$TAILSCALE_AUTHKEY",laptop-ts-host="${LAPTOP_TS_HOST:-}" \
  --metadata-from-file=startup-script="$REPO_ROOT/vm/startup-script.sh"

echo "Instance created. Syncing repo + building the container (waits for Docker)…"
"$(dirname "$0")/push-repo.sh"

# --- one-time: register Chrome Remote Desktop ------------------------------
# The auth code needs an interactive "Authorize" in your browser (single-use OAuth);
# the PIN comes from .env. Skippable — you can run ./vm/crd-setup.sh '<code>' later.
CRD_URL="https://remotedesktop.google.com/headless"
if [[ -z "${CRD_PIN:-}" ]]; then
  echo
  echo "CRD_PIN not set in .env — skipping Chrome Remote Desktop setup."
  echo "Set CRD_PIN, then register with: ./vm/crd-setup.sh '<code>'"
else
  echo
  echo "Waiting for Chrome Remote Desktop to finish installing on the VM…"
  until gcloud compute ssh "$INSTANCE" --zone="$ZONE" --project="$PROJECT" \
        --command 'test -x /opt/google/chrome-remote-desktop/start-host' >/dev/null 2>&1; do
    printf '.'; sleep 10
  done
  echo " ready."
  echo
  echo "Set up Chrome Remote Desktop now (one-time). To get an auth code:"
  echo "  1. Opening $CRD_URL in your browser…"
  echo "  2. Click Begin -> Next -> Authorize."
  echo "  3. Copy the command it shows (or just the --code=\"...\" value)."
  command -v open >/dev/null && open "$CRD_URL" 2>/dev/null || echo "     (open $CRD_URL manually)"
  echo
  printf 'Paste the auth code (or the full start-host command), or press Enter to skip: '
  read -r CRD_INPUT
  if [[ -n "$CRD_INPUT" ]]; then
    # Accept either a bare code or a pasted `... --code="4/..." ...` command.
    if [[ "$CRD_INPUT" == *--code=* ]]; then
      CODE="$(printf '%s' "$CRD_INPUT" | sed -n 's/.*--code=["'\'']\{0,1\}\([^"'\'' ]*\).*/\1/p')"
    else
      CODE="$CRD_INPUT"
    fi
    "$(dirname "$0")/crd-setup.sh" "$CODE"
  else
    echo "Skipped. Register later with: ./vm/crd-setup.sh '<code>'"
  fi
fi

echo
echo "Done. Connect to the desktop at https://remotedesktop.google.com/access"
echo "SSH to the VM with: ./vm/ssh.sh"
