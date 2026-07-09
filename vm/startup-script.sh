#!/usr/bin/env bash
# BUILDER PROVISIONER (one-time). Used only by vm/install.sh on the throwaway builder to
# install everything that gets baked into the golden image, ALL BARE-METAL on the VM (no
# Docker): Tailscale, Chrome Remote Desktop + XFCE, Google Chrome, JDK 17 + the Android
# SDK (headless, no Studio), gh, tmux, and a system-scope CLAUDE.md. Claude Code (native, no
# Node/npm) installs per-user on first login. Per-instance wiring is startup-golden.sh's job.
set -euo pipefail
exec > >(tee -a /var/log/android-dev-startup.log) 2>&1
echo "=== provisioning $(date -u) ==="

export DEBIAN_FRONTEND=noninteractive
ANDROID_API=34
BUILD_TOOLS=34.0.0
CMDLINE_TOOLS=11076708          # Android cmdline-tools 11.0
SDK=/opt/android-sdk

# --- base tools -----------------------------------------------------------
apt-get update
apt-get install -y --no-install-recommends \
  git curl wget unzip zip ca-certificates gnupg openjdk-17-jdk-headless tmux

# --- Tailscale (install only; nodes join via startup-golden.sh) -----------
command -v tailscale >/dev/null || curl -fsSL https://tailscale.com/install.sh | sh

# --- Desktop + Chrome Remote Desktop --------------------------------------
# CRD host is installed here; the one-time headless auth is done by YOU over SSH
# (see README runbook) because it needs a code from remotedesktop.google.com/headless.
if ! dpkg -s chrome-remote-desktop >/dev/null 2>&1; then
  apt-get install -y --no-install-recommends xfce4 xfce4-terminal desktop-base dbus-x11
  curl -fsSL https://dl.google.com/linux/linux_signing_key.pub \
    | gpg --dearmor -o /usr/share/keyrings/chrome-remote-desktop.gpg
  echo "deb [arch=amd64 signed-by=/usr/share/keyrings/chrome-remote-desktop.gpg] https://dl.google.com/linux/chrome-remote-desktop/deb stable main" \
    > /etc/apt/sources.list.d/chrome-remote-desktop.list
  apt-get update && apt-get install -y --no-install-recommends chrome-remote-desktop
  echo "exec /usr/bin/xfce4-session" > /etc/chrome-remote-desktop-session
fi

# --- Google Chrome --------------------------------------------------------
if ! dpkg -s google-chrome-stable >/dev/null 2>&1; then
  curl -fsSL https://dl.google.com/linux/linux_signing_key.pub \
    | gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg
  echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main" \
    > /etc/apt/sources.list.d/google-chrome.list
  apt-get update && apt-get install -y google-chrome-stable
fi

# --- GitHub CLI -----------------------------------------------------------
if ! command -v gh >/dev/null; then
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list
  apt-get update && apt-get install -y --no-install-recommends gh
fi

# --- Claude Code (native build; no Node/npm) ------------------------------
# The native install is per-user ($HOME-keyed, self-updating), so it can't live system-wide.
# Instead bake it into /etc/skel: useradd copies /etc/skel into every new home, so each user
# gets Claude in ~/.local at ACCOUNT CREATION — present before their first login, no
# background-install race. Self-updates still land in each user's own ~/.local.
echo 'export PATH="$HOME/.local/bin:$PATH"' > /etc/profile.d/local-bin.sh
if HOME=/etc/skel bash -c 'curl -fsSL https://claude.ai/install.sh | bash'; then
  # The installer writes an ABSOLUTE launcher symlink (into /etc/skel); rewrite it relative
  # so it still resolves once skel is copied into a real home. World-rX so any user can run
  # the shared copy until they self-update.
  ver="$(basename "$(readlink -f /etc/skel/.local/bin/claude)")"
  ln -sf "../share/claude/versions/$ver" /etc/skel/.local/bin/claude
  chmod -R a+rX /etc/skel/.local
  # Skip Claude's onboarding for every (skel-created) user. Claude REPLACES a hand-written
  # config on first run (regenerating its own machineID/userID), which drops a pre-set flag —
  # so let `claude config ls` materialize the real config (no API/token needed), then merge
  # the skip flag into THAT; Claude preserves it on later writes. (Single-user VM, so the
  # shared machineID is harmless.) Drop the per-user cache dir so it isn't baked/shared.
  HOME=/etc/skel /etc/skel/.local/bin/claude config ls >/dev/null 2>&1 || true
  python3 - <<'PY'
import json
p = "/etc/skel/.claude.json"
try: d = json.load(open(p))
except Exception: d = {}
d["hasCompletedOnboarding"] = True
d.setdefault("theme", "dark")
json.dump(d, open(p, "w"))
PY
  rm -rf /etc/skel/.claude
  chmod a+r /etc/skel/.claude.json
else
  echo "WARN: Claude skel-install failed (network?); the first-login fallback hook will cover it." >&2
fi
# Fallback only: install on first login if a user somehow lacks it (e.g. skel didn't apply).
# Skel makes this a no-op in the normal case (~/.local/bin/claude already exists).
cat > /etc/profile.d/zz-claude.sh <<'EOF'
if [ ! -x "$HOME/.local/bin/claude" ] && command -v curl >/dev/null 2>&1 && [ ! -e "$HOME/.claude-installing" ]; then
  touch "$HOME/.claude-installing"
  nohup sh -c 'curl -fsSL https://claude.ai/install.sh | bash; rm -f "$HOME/.claude-installing"' </dev/null >/dev/null 2>&1 &
fi
EOF

# --- Android SDK (bare-metal, system-wide) --------------------------------
if [[ ! -d "$SDK/platform-tools" ]]; then
  mkdir -p "$SDK/cmdline-tools"
  wget -q "https://dl.google.com/android/repository/commandlinetools-linux-${CMDLINE_TOOLS}_latest.zip" -O /tmp/clt.zip
  unzip -q /tmp/clt.zip -d "$SDK/cmdline-tools" && rm /tmp/clt.zip
  mv "$SDK/cmdline-tools/cmdline-tools" "$SDK/cmdline-tools/latest"
  # `yes |` gets SIGPIPE when sdkmanager stops reading; shield it from set -o pipefail.
  set +o pipefail
  yes | "$SDK/cmdline-tools/latest/bin/sdkmanager" --sdk_root="$SDK" --licenses >/dev/null
  set -o pipefail
  # A broad recent set so command-line Gradle builds work without opening Studio. The SDK
  # stays writable + all licenses accepted below, so Gradle auto-downloads anything a
  # project pins that isn't here (that's how we cover "all" without a 50 GB image).
  "$SDK/cmdline-tools/latest/bin/sdkmanager" --sdk_root="$SDK" --install \
    "platform-tools" \
    "platforms;android-33" "platforms;android-34" "platforms;android-35" \
    "build-tools;33.0.2" "build-tools;34.0.0" "build-tools;35.0.0" \
    "emulator" "system-images;android-${ANDROID_API};google_apis;x86_64" >/dev/null
  chmod -R a+rwX "$SDK"          # single-user dev box: any user can build / auto-fetch SDK bits
fi
# Shared adb client key baked into the image: every node presents the same identity, so
# you authorize the phone once ("always allow") and all future nodes are trusted.
if [[ ! -f /etc/android/adbkey ]]; then
  mkdir -p /etc/android
  HOME=/etc/android "$SDK/platform-tools/adb" keygen /etc/android/adbkey >/dev/null 2>&1 || true
  chmod 644 /etc/android/adbkey /etc/android/adbkey.pub 2>/dev/null || true
fi
# System-wide env (see the /etc/bash.bashrc loop below for non-login shells too).
cat > /etc/profile.d/android.sh <<EOF
export ANDROID_SDK_ROOT=$SDK
export ANDROID_HOME=$SDK
export ANDROID_AVD_HOME=/opt/avd
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
export ADB_VENDOR_KEYS=/etc/android/adbkey
export PATH="$SDK/cmdline-tools/latest/bin:$SDK/platform-tools:$SDK/emulator:\$PATH"
EOF
# A ready-to-run AVD in a shared writable location (needs KVM to boot — Intel nested-virt).
mkdir -p /opt/avd && chmod a+rwX /opt/avd
if [[ ! -d "/opt/avd/android${ANDROID_API}.avd" ]]; then
  echo no | ANDROID_AVD_HOME=/opt/avd "$SDK/cmdline-tools/latest/bin/avdmanager" create avd \
    -n "android${ANDROID_API}" -k "system-images;android-${ANDROID_API};google_apis;x86_64" -d pixel_6 >/dev/null 2>&1 || true
  chmod -R a+rwX /opt/avd
fi

# Android Studio is intentionally NOT installed — builds run headless from the CLI
# (the SDK above is self-sufficient) and device-checking is `push-build` to a real phone
# over Tailscale, so there's no IDE to fiddle with.

# --- KVM device access ----------------------------------------------------
# /dev/kvm is root:kvm 0660 by default; make it world-accessible so the desktop user can
# run the emulator without kvm-group juggling. (Single-user dev VM.) Applied by udev.
echo 'KERNEL=="kvm", GROUP="kvm", MODE="0666"' > /etc/udev/rules.d/99-kvm.rules

# --- make /etc/profile.d reach non-login shells (XFCE terminal) -----------
# Login shells already source /etc/profile.d via /etc/profile; guard so we don't source it
# a second time for them — only non-login interactive shells (desktop terminal) need this.
grep -q 'androiddevenv profile.d' /etc/bash.bashrc || cat >> /etc/bash.bashrc <<'BRC'
# androiddevenv: source /etc/profile.d in non-login interactive shells (desktop terminal)
if ! shopt -q login_shell; then for _f in /etc/profile.d/*.sh; do [ -r "$_f" ] && . "$_f"; done; unset _f; fi
BRC

# --- singleton tmux on SSH login ------------------------------------------
# Any interactive SSH login lands in the one shared "main" tmux session (attach-or-create),
# so work survives disconnects. Only for SSH (not the desktop terminal) and not already
# inside tmux. (Named zz-* to load last.)
cat > /etc/profile.d/zz-tmux.sh <<'EOF'
if command -v tmux >/dev/null 2>&1 && [ -z "${TMUX:-}" ] && [ -n "${SSH_CONNECTION:-}" ] && [ -n "${PS1:-}" ]; then
  # Some terminals (ghostty, kitty, …) don't have terminfo on this host; fall back so tmux
  # can start instead of dying with "missing or unsuitable terminal".
  infocmp "${TERM:-dumb}" >/dev/null 2>&1 || export TERM=xterm-256color
  # Not `exec`: if tmux can't start, fall through to a normal shell (never brick the login).
  tmux new-session -A -s main && exit
fi
EOF
# tmux: propagate the (Claude-set) window name to the terminal tab title too.
cat > /etc/tmux.conf <<'EOF'
set -g set-titles on
set -g set-titles-string '#W'
EOF

# --- first-login hook: clone the project + warm Gradle once ---------------
# The desktop user is created at login (after boot), so the clone can't run at boot.
# This fires once per user on their first interactive shell. GIT_REPO/GIT_BRANCH/
# GRADLE_WARM_TASK/GH_TOKEN come from the other /etc/profile.d/*.sh sourced before it (zz-
# name => sourced last). The done-marker is set only on success (lock always cleared), so a
# transient clone/warm failure retries next login instead of being silently disabled.
cat > /etc/profile.d/zz-warmrepo.sh <<'EOF'
if [ -n "${GIT_REPO:-}" ] && [ -w "$HOME" ] && [ ! -e "$HOME/work/.warm-done" ] && [ ! -e "$HOME/work/.warm-running" ] && command -v warm-repo >/dev/null 2>&1; then
  mkdir -p "$HOME/work" && touch "$HOME/work/.warm-running"
  nohup sh -c 'warm-repo && touch "$HOME/work/.warm-done"; rm -f "$HOME/work/.warm-running"' > "$HOME/work/.warm.log" 2>&1 < /dev/null &
fi
EOF

# --- system-scope CLAUDE.md (read by every Claude session on this VM) ------
mkdir -p /etc/claude-code
cat > /etc/claude-code/CLAUDE.md <<'MD'
# This VM: Android device access via adb over Tailscale

Android apps are built here and installed/run on a PHYSICAL phone reachable over Tailscale.
There is no USB and no emulator by default. The phone is a Tailscale node running adb in TCP
mode on port 5555; its Tailscale IP is in the `PHONE_TS_HOST` environment variable.

## Connect (do this before any adb command; it's idempotent)
    adb connect "$PHONE_TS_HOST:5555"
    adb devices                 # expect: <ip>:5555   device
If it shows `offline` or is missing (phone changed networks or rebooted), just run
`adb connect "$PHONE_TS_HOST:5555"` again.

## Build + install (the normal loop)
- In a Gradle project, `push-build` does everything: assembleDebug, connect, and install.
- Manually:
    ./gradlew assembleDebug
    adb -s "$PHONE_TS_HOST:5555" install -r app/build/outputs/apk/debug/app-debug.apk

## Run / launch an app on the phone
- Launch it:   adb -s "$PHONE_TS_HOST:5555" shell monkey -p <applicationId> -c android.intent.category.LAUNCHER 1
- Or an activity:  adb -s "$PHONE_TS_HOST:5555" shell am start -n <applicationId>/<activity>
- Logs:        adb -s "$PHONE_TS_HOST:5555" logcat
- Uninstall:   adb -s "$PHONE_TS_HOST:5555" uninstall <applicationId>

## Keep the tmux window titled with what you're working on
So each tmux window / terminal tab shows its current task at a glance, name the tmux window
after what you're doing. Whenever you start a new task or the topic changes, silently run:
    tmux rename-window '<short topic>' 2>/dev/null || true
Use a short 1-3 word label (e.g. "arrivals bug", "gradle upgrade"). Don't announce it.

## Notes
- Always target the phone explicitly with `adb -s "$PHONE_TS_HOST:5555" ...` to avoid ambiguity.
- Keep Tailscale ON on the phone. The link may relay via DERP (slower but fine for installs).
- Do NOT start an emulator unless nested virtualization (KVM, /dev/kvm) is present.
MD

apt-get clean
touch /var/lib/android-dev-provisioned
echo "=== provisioning done $(date -u) ==="
