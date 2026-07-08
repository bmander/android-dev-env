#!/usr/bin/env bash
# Launch the android-dev container on THIS VM — the single source of truth for the
# container's run arguments (env, volumes, restart policy, networking). Reads per-instance
# metadata (laptop-ts-host, anthropic-api-key), so the same launch is used everywhere.
#
#   run-container.sh            # start it if not already present (boot path)
#   run-container.sh --force    # recreate it (after an image rebuild)
#
# Baked to /usr/local/bin/run-android-dev in the golden image; called by startup-golden.sh
# at boot and by push-repo.sh after a rebuild. Run as root (docker).
set -euo pipefail

meta() { curl -s -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$1" || true; }

if docker ps -a --format '{{.Names}}' | grep -qx android-dev; then
  if [[ "${1:-}" == "--force" ]]; then
    docker rm -f android-dev >/dev/null
  else
    echo "android-dev already present."; exit 0
  fi
fi

if ! docker image inspect android-dev:latest >/dev/null 2>&1; then
  echo "!! android-dev:latest image missing — rebuild via ./vm/push-repo.sh or ./vm/install.sh" >&2
  exit 1
fi

LAPTOP_TS_HOST="$(meta laptop-ts-host)"
API_KEY="$(meta anthropic-api-key)"
OAUTH_TOKEN="$(meta claude-oauth-token)"
GH_TOKEN="$(meta github-token)"
GIT_REPO="$(meta git-repo)"
GIT_BRANCH="$(meta git-branch)"
GRADLE_WARM_TASK="$(meta gradle-warm-task)"
docker run -d --name android-dev --restart unless-stopped --network=host \
  -e LAPTOP_TS_HOST="${LAPTOP_TS_HOST}" \
  ${API_KEY:+-e ANTHROPIC_API_KEY="${API_KEY}"} \
  ${OAUTH_TOKEN:+-e CLAUDE_CODE_OAUTH_TOKEN="${OAUTH_TOKEN}"} \
  ${GH_TOKEN:+-e GH_TOKEN="${GH_TOKEN}" -e GITHUB_TOKEN="${GH_TOKEN}"} \
  ${GIT_REPO:+-e GIT_REPO="${GIT_REPO}"} \
  ${GIT_BRANCH:+-e GIT_BRANCH="${GIT_BRANCH}"} \
  ${GRADLE_WARM_TASK:+-e GRADLE_WARM_TASK="${GRADLE_WARM_TASK}"} \
  -v android-dev-work:/home/dev/work \
  -v android-dev-home:/home/dev/.claude \
  android-dev:latest
echo "android-dev container started."
