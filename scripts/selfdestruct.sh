#!/usr/bin/env bash
# Disconnect from Tailscale and delete THIS instance — the "I'm done, from the box itself"
# teardown, so you don't have to reach for the laptop's ./vm/nuke.sh. Immediate: no prompt.
#   selfdestruct
#
# How it works: talks to the Compute API directly with the metadata-server token (the
# Ubuntu image has no gcloud). Needs the VM's service account to carry the compute scope —
# create.sh grants it (--scopes=…/auth/compute); the default Compute SA already has the
# instances.delete permission. The boot disk auto-deletes with the instance.
#
# The teardown runs detached (setsid): you may be connected over Tailscale SSH, and
# `tailscale logout` would drop that very session — detaching lets the delete still fire.
set -euo pipefail

meta() { curl -sf -H 'Metadata-Flavor: Google' \
  "http://metadata.google.internal/computeMetadata/v1/$1"; }

NAME="$(meta instance/name)"
ZONE="$(basename "$(meta instance/zone)")"     # projects/N/zones/us-west1-b -> us-west1-b
PROJECT="$(meta project/project-id)"
# Grab the access token BEFORE touching Tailscale — the detached job needs it after the
# tailnet (and any Tailscale-SSH session) is gone.
TOKEN="$(meta instance/service-accounts/default/token \
  | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')"
[[ -n "$TOKEN" ]] || { echo "No access token from metadata server (missing compute scope?)." >&2; exit 1; }

echo "Self-destruct: leaving the tailnet, then deleting $NAME ($ZONE) — irreversible."

export NAME ZONE PROJECT TOKEN
setsid bash -c '
  timeout 10 sudo tailscale logout 2>/dev/null || sudo tailscale down 2>/dev/null || true
  curl -sf -X DELETE -H "Authorization: Bearer $TOKEN" \
    "https://compute.googleapis.com/compute/v1/projects/$PROJECT/zones/$ZONE/instances/$NAME"
' </dev/null >/tmp/selfdestruct.log 2>&1 &

echo "Requested. This node will disconnect and vanish shortly (log: /tmp/selfdestruct.log)."
