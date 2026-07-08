#!/usr/bin/env bash
# Sync this repo to /opt/androiddevenv on the VM and (re)build + run the android-dev
# container. Waits for the startup script to finish installing Docker first, so it's
# safe to call immediately after create.sh. Also use it after editing the Dockerfile.
source "$(dirname "$0")/config.sh"

ssh_vm() { gcloud compute ssh "$INSTANCE" --zone="$ZONE" --project="$PROJECT" --command "$1"; }

echo "Waiting for SSH + Docker on the VM (startup script installs Docker)…"
until ssh_vm "command -v docker >/dev/null" >/dev/null 2>&1; do printf '.'; sleep 10; done
echo " ready."

ssh_vm "sudo mkdir -p /opt/androiddevenv && sudo chown \$(whoami) /opt/androiddevenv"
gcloud compute scp --recurse --zone="$ZONE" --project="$PROJECT" \
  "$REPO_ROOT/Dockerfile" "$REPO_ROOT/container" "$REPO_ROOT/scripts" \
  "$INSTANCE":/opt/androiddevenv/

echo "Building + starting the android-dev container…"
ssh_vm '
  set -e
  LAPTOP=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/laptop-ts-host)
  sudo docker build -t android-dev:latest /opt/androiddevenv
  sudo docker rm -f android-dev 2>/dev/null || true
  sudo docker run -d --name android-dev --restart unless-stopped --network=host \
    -e LAPTOP_TS_HOST="$LAPTOP" \
    -v android-dev-work:/home/dev/work -v android-dev-home:/home/dev/.claude \
    android-dev:latest
  sudo docker ps --filter name=android-dev
'
echo "Done. Enter it with: ./vm/ssh.sh  then  sudo docker exec -it -u dev android-dev bash"
