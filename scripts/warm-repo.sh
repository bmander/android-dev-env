#!/usr/bin/env bash
# Clone the configured Android repo into ~/work and warm the Gradle build. Runs as the
# desktop user (launched in the background by startup-golden.sh at node startup), so the
# node is usable immediately while dependencies download and the daemon spins up.
#
# Env (passed by startup-golden.sh from instance metadata):
#   GIT_REPO           HTTPS repo URL to clone (required; else no-op)
#   GIT_BRANCH         optional branch to check out
#   GRADLE_WARM_TASK   Gradle task to warm caches/daemon (default: assembleDebug)
#   GH_TOKEN           GitHub token for private clones/pushes
#   WORK_ISSUE         if set (create.sh --issue N), hand the repo to Claude after cloning
set -uo pipefail

[[ -n "${GIT_REPO:-}" ]] || exit 0
mkdir -p "$HOME/work" && cd "$HOME/work" || exit 0

# Configure git to use the token for github.com HTTPS (clone + later pushes).
[[ -n "${GH_TOKEN:-}" ]] && gh auth setup-git 2>/dev/null || true

name="$(basename "${GIT_REPO%.git}")"
if [[ ! -d "$name/.git" ]]; then
  echo "[warm] cloning $GIT_REPO …"
  git clone ${GIT_BRANCH:+--branch "$GIT_BRANCH"} "$GIT_REPO" "$name" || { echo "[warm] clone failed"; exit 1; }
fi
cd "$name" || exit 1

# create.sh --issue N: set Claude to work the issue now, and skip the local Gradle warm —
# Claude runs its own builds, and a second concurrent Gradle would contend on the build lock.
if [[ -n "${WORK_ISSUE:-}" ]]; then
  echo "[warm] handing issue #$WORK_ISSUE to Claude (skipping Gradle warm)…"
  work-issue "$WORK_ISSUE" "$PWD" || echo "[warm] work-issue launch failed"
  exit 0
fi

if [[ -x ./gradlew ]]; then
  task="${GRADLE_WARM_TASK:-assembleDebug}"
  echo "[warm] ./gradlew $task …"
  ./gradlew "$task" && echo "[warm] build warmed." || echo "[warm] gradle exited non-zero (cache still warmed)."
else
  echo "[warm] no ./gradlew in $name; skipping build warm."
fi
echo "[warm] done $(date -u)."
