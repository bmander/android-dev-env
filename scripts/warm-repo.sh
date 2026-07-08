#!/usr/bin/env bash
# Clone the configured Android repo and warm the Gradle build. Launched in the background
# by the container entrypoint at node startup, so the container is usable immediately while
# dependencies download and the Gradle daemon spins up. Logs to ~/work/.warm.log.
#
# Reads from the environment (passed via run-container.sh from instance metadata):
#   GIT_REPO           HTTPS repo URL to clone (required; else this is a no-op)
#   GIT_BRANCH         optional branch to check out
#   GRADLE_WARM_TASK   Gradle task to run to warm caches/daemon (default: assembleDebug)
set -uo pipefail

[[ -n "${GIT_REPO:-}" ]] || exit 0
cd /home/dev/work || exit 0

name="$(basename "${GIT_REPO%.git}")"
if [[ ! -d "$name/.git" ]]; then
  echo "[warm] cloning $GIT_REPO …"
  git clone ${GIT_BRANCH:+--branch "$GIT_BRANCH"} "$GIT_REPO" "$name" || { echo "[warm] clone failed"; exit 1; }
fi
cd "$name" || exit 1

if [[ -x ./gradlew ]]; then
  task="${GRADLE_WARM_TASK:-assembleDebug}"
  echo "[warm] ./gradlew $task …"
  ./gradlew "$task" && echo "[warm] build warmed." || echo "[warm] gradle exited non-zero (cache still warmed)."
else
  echo "[warm] no ./gradlew in $name; skipping build warm."
fi
echo "[warm] done $(date -u)."
