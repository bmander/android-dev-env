#!/usr/bin/env bash
# Lean per-node startup for instances booted from the android-dev-golden image. Everything
# heavy (Tailscale, CRD, JDK + Android SDK, Studio, Node/Claude, gh — all bare-metal) is
# baked in; this only does per-instance wiring: join Tailscale, write auth/env for the
# desktop shells, resume CRD, enable KVM, and clone+warm the project. Idempotent.
set -euo pipefail
exec > >(tee -a /var/log/android-dev-startup.log) 2>&1
echo "=== golden startup $(date -u) ==="

meta() { curl -s -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$1" || true; }

# --- Tailscale (unique node per instance) ---------------------------------
AUTHKEY="$(meta tailscale-authkey)"
if [[ -n "$AUTHKEY" ]]; then
  tailscale up --authkey="$AUTHKEY" --hostname="$(hostname)" --ssh --accept-routes || true
fi

# --- host env for the workspace shells ------------------------------------
# Claude auth, the adb-over-tailscale target, and the GitHub token. Written to
# /etc/profile.d; the baked /etc/bash.bashrc loop makes non-login (desktop) shells see it.
{
  API_KEY="$(meta anthropic-api-key)"
  [[ -n "$API_KEY" ]] && printf 'export ANTHROPIC_API_KEY=%q\n' "$API_KEY"
  OAUTH_TOKEN="$(meta claude-oauth-token)"
  [[ -n "$OAUTH_TOKEN" ]] && printf 'export CLAUDE_CODE_OAUTH_TOKEN=%q\n' "$OAUTH_TOKEN"
} > /etc/profile.d/claude-auth.sh

LAPTOP_TS_HOST="$(meta laptop-ts-host)"
if [[ -n "$LAPTOP_TS_HOST" ]]; then
  { echo "export LAPTOP_TS_HOST=${LAPTOP_TS_HOST}"
    echo "export ADB_SERVER_SOCKET=tcp:${LAPTOP_TS_HOST}:5037"; } > /etc/profile.d/adb.sh
fi

GH_TOKEN="$(meta github-token)"
if [[ -n "$GH_TOKEN" ]]; then
  { echo "export GH_TOKEN=${GH_TOKEN}"; echo "export GITHUB_TOKEN=${GH_TOKEN}"; } > /etc/profile.d/github.sh
fi

# Skip Claude Code's interactive first-run onboarding (which forces a login) — auth is
# handled by the token. Merge the flag into each user's ~/.claude.json, preserving keys.
for home in /home/*; do
  [[ -d "$home" ]] || continue
  u="$(stat -c %U "$home")"
  python3 - "$home/.claude.json" <<'PY' || true
import json, sys
p = sys.argv[1]
try:
    d = json.load(open(p))
except Exception:
    d = {}
d["hasCompletedOnboarding"] = True
d.setdefault("theme", "dark")
json.dump(d, open(p, "w"))
PY
  chown "$u:$u" "$home/.claude.json" 2>/dev/null || true
done

# --- KVM (for emulators on an Intel nested-virt node; no-op otherwise) -----
modprobe kvm_intel 2>/dev/null || modprobe kvm_amd 2>/dev/null || true
[[ -e /dev/kvm ]] && chmod 0666 /dev/kvm 2>/dev/null || true

# --- Chrome Remote Desktop: resume if this node was registered -------------
for cfg in /home/*/.config/chrome-remote-desktop; do
  compgen -G "$cfg/host#*.json" >/dev/null || continue
  u="$(stat -c '%U' "$cfg")"
  echo "CRD host config found for '$u' — ensuring service is up."
  systemctl enable --now "chrome-remote-desktop@$u" || true
done

# --- project settings for the first-login warm hook -----------------------
# We can't clone here: the desktop user is created at login (after boot), not now. Instead
# expose the repo settings; the baked /etc/profile.d/zz-warmrepo.sh clones + warms into
# ~/work on that user's first interactive login (GH_TOKEN comes from github.sh above).
GIT_REPO="$(meta git-repo)"
if [[ -n "$GIT_REPO" ]]; then
  { echo "export GIT_REPO=${GIT_REPO}"
    echo "export GIT_BRANCH=$(meta git-branch)"
    echo "export GRADLE_WARM_TASK=$(meta gradle-warm-task)"; } > /etc/profile.d/androidproject.sh
fi

echo "=== golden startup done $(date -u) ==="
