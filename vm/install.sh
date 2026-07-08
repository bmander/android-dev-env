#!/usr/bin/env bash
# One-time install: build the android-dev container image and bake it into the
# android-dev-golden GCE image, so `vm/create.sh` can spin up ready nodes in ~1 min.
#
# Spins a throwaway builder (your existing VMs are untouched), installs Docker/Tailscale/
# CRD + builds the android-dev container image into the disk, generalizes (strips per-
# machine identity so clones don't collide), then creates the image and deletes the builder.
#
# Run once, and again whenever the Dockerfile or host provisioning changes.
source "$(dirname "$0")/config.sh"

BUILDER="${INSTANCE}-builder"

echo "== 1/6 create builder $BUILDER (ubuntu, full provisioning) =="
gcloud compute instances create "$BUILDER" \
  --project="$PROJECT" --zone="$ZONE" --machine-type="$MACHINE" \
  --image-family="$IMAGE_FAMILY" --image-project="$IMAGE_PROJECT" \
  --boot-disk-size="${DISK_GB}GB" --boot-disk-type=pd-balanced \
  --labels=environment=development,purpose=android-dev-builder \
  --metadata-from-file=startup-script="$REPO_ROOT/vm/startup-script.sh"
  # NB: no tailscale-authkey metadata -> builder never joins the tailnet -> nothing to clean.

echo "== 2/6 wait for Docker, build the android-dev image + bake the launcher =="
wait_remote "$BUILDER" 'command -v docker >/dev/null'
echo " docker ready."
ssh_vm "$BUILDER" "sudo mkdir -p /opt/androiddevenv && sudo chown \$(whoami) /opt/androiddevenv"
gcloud compute scp --recurse --zone="$ZONE" --project="$PROJECT" \
  "$REPO_ROOT/Dockerfile" "$REPO_ROOT/container" "$REPO_ROOT/scripts" "$REPO_ROOT/vm/run-container.sh" \
  "$BUILDER":/opt/androiddevenv/
ssh_vm "$BUILDER" "sudo docker build -t android-dev:latest /opt/androiddevenv \
  && sudo install -m 0755 /opt/androiddevenv/run-container.sh /usr/local/bin/run-android-dev"

echo "== 3/6 wait for CRD install to finish (baked for the primary node) =="
wait_remote "$BUILDER" 'test -x /opt/google/chrome-remote-desktop/start-host'
echo " CRD present."

echo "== 4/6 generalize (strip per-machine identity) =="
ssh_vm "$BUILDER" '
  set -e
  sudo rm -f /var/lib/tailscale/tailscaled.state 2>/dev/null || true
  sudo rm -rf /home/*/.config/chrome-remote-desktop 2>/dev/null || true   # no CRD host baked
  sudo truncate -s 0 /etc/machine-id                         # regenerated per instance
  sudo rm -f /etc/ssh/ssh_host_* 2>/dev/null || true         # GCE regenerates on boot
  sudo cloud-init clean --logs 2>/dev/null || true
  sudo rm -f /var/log/android-dev-startup.log
  sudo apt-get clean
  echo "generalized."
'

echo "== 5/6 stop builder and create image $GOLDEN_IMAGE =="
gcloud compute instances stop "$BUILDER" --zone="$ZONE" --project="$PROJECT"
gcloud compute images delete "$GOLDEN_IMAGE" --project="$PROJECT" -q 2>/dev/null || true
gcloud compute images create "$GOLDEN_IMAGE" \
  --project="$PROJECT" --source-disk="$BUILDER" --source-disk-zone="$ZONE" \
  --family=android-dev --labels=purpose=android-dev-golden

echo "== 6/6 delete builder =="
gcloud compute instances delete "$BUILDER" --zone="$ZONE" --project="$PROJECT" -q

echo
echo "Done. Golden image '$GOLDEN_IMAGE' ready. New nodes: ./vm/create.sh [name]"
