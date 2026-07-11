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
# Register under the GCE instance name so the tailnet node matches `./vm/*` names. Take it
# from the metadata server, not `$(hostname)`: the golden image can carry a stale /etc/hostname
# (baked off the seed) that the guest agent hasn't reset yet this early in boot.
AUTHKEY="$(meta tailscale-authkey)"
if [[ -n "$AUTHKEY" ]]; then
  NODE_NAME="$(curl -s -H 'Metadata-Flavor: Google' \
    http://metadata.google.internal/computeMetadata/v1/instance/name)"
  tailscale up --authkey="$AUTHKEY" --hostname="${NODE_NAME:-$(hostname)}" --ssh --accept-routes || true
fi

# --- host env for the workspace shells ------------------------------------
# Auth, the adb-over-tailscale target, the GitHub token, and the project settings, written
# to /etc/profile.d (the baked bash.bashrc loop makes non-login desktop shells see them).
# %q-quoted so a token/branch with odd characters can't break the sourced file.
emit() { [ -n "${2:-}" ] || return 0; printf 'export %s=%q\n' "$1" "$2"; }

{ emit ANTHROPIC_API_KEY "$(meta anthropic-api-key)"
  emit CLAUDE_CODE_OAUTH_TOKEN "$(meta claude-oauth-token)"; } > /etc/profile.d/claude-auth.sh
emit PHONE_TS_HOST "$(meta phone-ts-host)" > /etc/profile.d/adb.sh
GH="$(meta github-token)"
{ emit GH_TOKEN "$GH"; emit GITHUB_TOKEN "$GH"; } > /etc/profile.d/github.sh
{ emit GIT_REPO "$(meta git-repo)"
  emit GIT_BRANCH "$(meta git-branch)"
  emit GRADLE_WARM_TASK "$(meta gradle-warm-task)"
  emit WORK_ISSUE "$(meta work-issue)"; } > /etc/profile.d/androidproject.sh
# (Claude onboarding + folder-trust skip is handled by the claude() wrapper in
#  /etc/profile.d/claude-wrapper.sh — it needs the real $HOME/$PWD. See startup-script.sh.)

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

echo "=== golden startup done $(date -u) ==="
