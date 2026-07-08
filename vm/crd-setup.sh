#!/usr/bin/env bash
# Register the VM as a Chrome Remote Desktop host, non-interactively, using CRD_PIN
# from .env. You need this once per node: the registration persists on the boot disk
# across stop/start (the systemd service auto-starts on boot), so CRD comes back on its
# own after a pause. A fresh node (create.sh) does need its own one-time code.
#
# The auth code is the one thing that can't be automated (single-use Google OAuth):
#   1. open  https://remotedesktop.google.com/headless
#   2. Begin -> Next -> Authorize
#   3. copy the value inside --code="..." from the command it shows
# Then:
#   ./vm/crd-setup.sh '4/0Axxxxxxxx...' [name]     # name defaults to $INSTANCE
source "$(dirname "$0")/config.sh"

CODE="${1:?pass the auth code from https://remotedesktop.google.com/headless as the first argument}"
NAME="${2:-$INSTANCE}"
: "${CRD_PIN:?set CRD_PIN in .env}"

echo "Registering $NAME as a CRD host (PIN from .env)…"
ssh_vm "$NAME" \
  "DISPLAY= /opt/google/chrome-remote-desktop/start-host \
     --code='$CODE' \
     --redirect-url='https://remotedesktop.google.com/_/oauthredirect' \
     --name=\$(hostname) \
     --pin=$CRD_PIN"

echo "Done. Connect from your laptop at https://remotedesktop.google.com/access (use your CRD_PIN)."
