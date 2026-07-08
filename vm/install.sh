#!/usr/bin/env bash
# One-time install, guided end to end:
#   A) build the base golden image from a throwaway builder;
#   B) spin up a seed node from it, drop you into its desktop to configure graphically
#      (Android Studio's setup wizard, browser sign-ins, dotfiles, …);
#   C) re-bake the golden image from that configured seed, so every future ./vm/create.sh
#      stamps it — then delete the seed.
#
# Re-run whenever the Dockerfile / host provisioning changes, or to reconfigure the image.
# Phase B/C are interactive; with no TTY (or no TAILSCALE_AUTHKEY) it stops after the base
# image and you can configure later with:  create.sh seed -> (configure) -> reimage.sh seed
source "$(dirname "$0")/config.sh"
source "$(dirname "$0")/lib-bake.sh"

BUILDER="${INSTANCE}-builder"
SEED="${INSTANCE}-seed"

# ===== A. base golden image (throwaway builder) ===========================
echo "== A1 create builder $BUILDER ($BUILDER_MACHINE, $BUILDER_DISK_TYPE) =="
gcloud compute instances create "$BUILDER" \
  --project="$PROJECT" --zone="$ZONE" --machine-type="$BUILDER_MACHINE" \
  --image-family="$IMAGE_FAMILY" --image-project="$IMAGE_PROJECT" \
  --boot-disk-size="${DISK_GB}GB" --boot-disk-type="$BUILDER_DISK_TYPE" \
  --labels=environment=development,purpose=android-dev-builder \
  --metadata-from-file=startup-script="$REPO_ROOT/vm/startup-script.sh"
  # NB: no tailscale-authkey metadata -> builder never joins the tailnet -> nothing to clean.

echo "== A2 wait for Docker, build the android-dev image + bake the launcher =="
wait_remote "$BUILDER" 'command -v docker >/dev/null'
echo " docker ready."
ssh_vm "$BUILDER" "sudo mkdir -p /opt/androiddevenv && sudo chown \$(whoami) /opt/androiddevenv"
gcloud compute scp --recurse --zone="$ZONE" --project="$PROJECT" \
  "$REPO_ROOT/Dockerfile" "$REPO_ROOT/container" "$REPO_ROOT/scripts" "$REPO_ROOT/vm/run-container.sh" \
  "$BUILDER":/opt/androiddevenv/
ssh_vm "$BUILDER" "sudo docker build -t android-dev:latest /opt/androiddevenv \
  && sudo install -m 0755 /opt/androiddevenv/run-container.sh /usr/local/bin/run-android-dev"

echo "== A3 wait for CRD install to finish =="
wait_remote "$BUILDER" 'test -x /opt/google/chrome-remote-desktop/start-host'
echo " CRD present."

echo "== A4 generalize + bake base image $GOLDEN_IMAGE, delete builder =="
generalize_instance "$BUILDER"
bake_golden "$BUILDER"
gcloud compute instances delete "$BUILDER" --zone="$ZONE" --project="$PROJECT" -q
echo "Base golden image ready."

# ===== B/C. configure a seed graphically, then re-bake ====================
if [[ ! -t 0 || -z "${TAILSCALE_AUTHKEY:-}" ]]; then
  echo
  echo "Base image is ready — new nodes: ./vm/create.sh [name]"
  echo "To bake a graphically-configured setup in, run interactively (with TAILSCALE_AUTHKEY):"
  echo "  ./vm/create.sh seed  ->  configure the desktop  ->  ./vm/reimage.sh seed"
  exit 0
fi

echo
read -r -p "Spin up a seed now to configure the image graphically (Android Studio, etc.)? [Y/n] " ans
case "$ans" in
  [Nn]*) echo "Skipped. Base image ready — new nodes: ./vm/create.sh [name]"; exit 0 ;;
esac

echo "== B spin up seed $SEED and register its desktop =="
"$(dirname "$0")/create.sh" "$SEED"

echo
echo "== configure the desktop =="
echo "Connect below, launch Android Studio and finish its setup wizard (SDK, licenses),"
echo "and set up anything else you want on every node. It all gets baked in."
ACCESS="https://remotedesktop.google.com/access"
command -v open >/dev/null && open "$ACCESS" 2>/dev/null || true
echo "  $ACCESS"
echo "  (shell instead:  NODE=$SEED ./vm/ssh.sh  — but Studio setup is graphical)"
echo
read -r -p "When $SEED is configured the way you want, press Enter to bake it in… "

echo "== C re-bake $GOLDEN_IMAGE from the configured seed, delete seed =="
generalize_instance "$SEED"
bake_golden "$SEED"
gcloud compute instances delete "$SEED" --zone="$ZONE" --project="$PROJECT" --delete-disks=all -q

echo
echo "Done. '$GOLDEN_IMAGE' now includes your configured setup. New nodes: ./vm/create.sh [name]"
