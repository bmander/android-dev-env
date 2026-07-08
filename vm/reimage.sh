#!/usr/bin/env bash
# Re-bake the golden image from a CONFIGURED node — "stamping" its set-up state onto
# every future node. Use it to bake a fully, graphically configured Android Studio
# (installed SDK, accepted licenses, preferences) so new nodes come up ready.
#
#   1. ./vm/create.sh seed          # boot a node from the current golden image
#   2. connect at remotedesktop.google.com/access, launch Android Studio, and complete
#      its setup wizard graphically (SDK, licenses, prefs). Configure anything else too.
#   3. ./vm/reimage.sh seed         # generalize + re-bake the golden image from it
#   4. ./vm/create.sh               # new nodes now stamp the configured state
#
# It keeps the home-dir config (~/Android/Sdk, ~/.config/Google/AndroidStudio*, AVDs)
# and strips only per-machine identity. CRD registration can't be baked (single-use),
# so each new node still does its one-time CRD code.
source "$(dirname "$0")/config.sh"
source "$(dirname "$0")/lib-bake.sh"

SEED="${1:-$INSTANCE}"

if ! gcloud compute instances describe "$SEED" --zone="$ZONE" --project="$PROJECT" >/dev/null 2>&1; then
  echo "No instance '$SEED' in $ZONE/$PROJECT. Create+configure one first (see this script's header)." >&2
  exit 1
fi

echo "Generalizing $SEED (keeps Android Studio config/SDK; strips machine identity)…"
generalize_instance "$SEED"

echo "Re-baking $GOLDEN_IMAGE from $SEED…"
bake_golden "$SEED"

echo
echo "Done — new ./vm/create.sh nodes now stamp $SEED's configured state."
echo "$SEED is stopped and spent; delete it when you're satisfied:"
echo "  ./vm/nuke.sh $SEED"
