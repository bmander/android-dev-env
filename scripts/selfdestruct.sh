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
# Order matters: the delete goes over the public internet (not the tailnet), so we fire it
# FIRST and only leave Tailscale once the API accepts it — a refused delete then never also
# costs us our access path. The teardown runs detached (setsid) so it finishes even if the
# box going away (or the logout) drops the Tailscale-SSH session you launched it from.
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

echo "Self-destruct: deleting $NAME ($ZONE), then leaving the tailnet — irreversible."

export NAME ZONE PROJECT TOKEN
setsid bash -c '
  code=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE -H "Authorization: Bearer $TOKEN" \
    "https://compute.googleapis.com/compute/v1/projects/$PROJECT/zones/$ZONE/instances/$NAME")
  if [[ "$code" == 2* ]]; then
    timeout 10 sudo tailscale logout 2>/dev/null || true   # accepted — leave the tailnet on the way out
  else
    # Delete refused (e.g. the SA lacks the compute scope): stay on the tailnet so the box is
    # still reachable, and leave a durable, findable marker rather than only a /tmp log.
    echo "selfdestruct FAILED: Compute API returned HTTP $code — instance NOT deleted, still on the tailnet." \
      | sudo tee /var/log/selfdestruct-failed.log >&2
  fi
' </dev/null >/tmp/selfdestruct.log 2>&1 &

echo "Requested. On success this node vanishes shortly; on failure it stays up and reachable"
echo "(logs: /tmp/selfdestruct.log, and /var/log/selfdestruct-failed.log if the delete is refused)."
