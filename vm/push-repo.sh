#!/usr/bin/env bash
# Copy this repo up to /opt/androiddevenv on the VM and (re)run the startup script
# so the container rebuilds. Use after editing the Dockerfile or scripts.
source "$(dirname "$0")/config.sh"

gcloud compute ssh "$INSTANCE" --zone="$ZONE" --project="$PROJECT" --command \
  "sudo mkdir -p /opt/androiddevenv && sudo chown \$(whoami) /opt/androiddevenv"

gcloud compute scp --recurse --zone="$ZONE" --project="$PROJECT" \
  "$REPO_ROOT/Dockerfile" "$REPO_ROOT/container" "$REPO_ROOT/scripts" \
  "$INSTANCE":/opt/androiddevenv/

echo "Rebuilding container on the VM…"
gcloud compute ssh "$INSTANCE" --zone="$ZONE" --project="$PROJECT" --command \
  "sudo bash /opt/androiddevenv/../../var/lib/cloud/instance/scripts/* 2>/dev/null; \
   sudo docker build -t android-dev:latest /opt/androiddevenv && \
   sudo docker rm -f android-dev 2>/dev/null; \
   sudo docker run -d --name android-dev --restart unless-stopped --network=host \
     -e LAPTOP_TS_HOST=\$(curl -s -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/instance/attributes/laptop-ts-host) \
     -v android-dev-work:/home/dev/work -v android-dev-home:/home/dev/.claude \
     android-dev:latest"
echo "Done."
