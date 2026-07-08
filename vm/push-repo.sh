#!/usr/bin/env bash
# Rebuild the android-dev image on a node after editing the Dockerfile (or scripts),
# then relaunch the container via the baked launcher. Usage:
#   ./vm/push-repo.sh [name]     # default: $INSTANCE
source "$(dirname "$0")/config.sh"

NAME="${1:-$INSTANCE}"

echo "Waiting for SSH + Docker on $NAME…"
wait_remote "$NAME" 'command -v docker >/dev/null'
echo " ready."

ssh_vm "$NAME" "sudo mkdir -p /opt/androiddevenv && sudo chown \$(whoami) /opt/androiddevenv"
gcloud compute scp --recurse --zone="$ZONE" --project="$PROJECT" \
  "$REPO_ROOT/Dockerfile" "$REPO_ROOT/container" "$REPO_ROOT/scripts" "$REPO_ROOT/vm/run-container.sh" \
  "$NAME":/opt/androiddevenv/

echo "Rebuilding image + relaunching container on $NAME…"
ssh_vm "$NAME" '
  set -e
  sudo docker build -t android-dev:latest /opt/androiddevenv
  sudo install -m 0755 /opt/androiddevenv/run-container.sh /usr/local/bin/run-android-dev
  sudo run-android-dev --force
  sudo docker ps --filter name=android-dev
'
echo "Done. Enter it with: ./vm/ssh.sh  then  sudo docker exec -it -u dev android-dev bash"
