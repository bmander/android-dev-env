#!/usr/bin/env bash
# Create an android-dev node from the golden image (fast boot). Usage:
#   ./vm/create.sh [--desktop] [name]
# Requires a reusable TAILSCALE_AUTHKEY in .env. Nodes are headless by default; pass --desktop
# to interactively register Chrome Remote Desktop (needs CRD_PIN in .env).
NAME=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      cat <<'EOF'
Usage: ./vm/create.sh [--desktop] [--ssh] [--issue N] [NAME]

Create an android-dev VM node from the golden image (~1 min boot). Config comes from .env
(see .env.example); TAILSCALE_AUTHKEY is required. Nodes are headless by default; pass
--desktop to register Chrome Remote Desktop (prompts once for the auth code). On boot the
node clones $GIT_REPO into ~/work, warms Gradle, and wires phone-adb / Claude / GitHub auth.

Arguments:
  NAME                    instance name (default: $INSTANCE, i.e. android-dev)

Options:
  --desktop               register Chrome Remote Desktop (prompts for the auth code; needs CRD_PIN)
  --headless              no desktop — the DEFAULT now; accepted as an explicit no-op
  --ssh                   SSH straight into the node once it's up (drops you into a shell)
  --issue N               start an unattended Claude worker on GitHub issue N in $GIT_REPO —
                          kicked off automatically (no login needed), running in tmux so you
                          can SSH in and watch. Needs GIT_REPO + a GitHub token.
  -h, --help              show this help and exit

Key .env knobs:
  TAILSCALE_AUTHKEY       required, reusable Tailscale auth key
  PHONE_TS_HOST           phone's tailscale IP for the adb install loop
  MACHINE                 machine type (default e2-standard-4)
  NESTED_VIRT=1           enable KVM for emulators (Intel machine only)
  DISK_GB                 boot disk size in GB (default 60)
  GIT_REPO / GIT_BRANCH   repo auto-cloned + Gradle-warmed at launch
  GITHUB_TOKEN            GitHub token (else taken from local `gh auth token`)
  CLAUDE_CODE_OAUTH_TOKEN / ANTHROPIC_API_KEY    Claude auth

Examples:
  ./vm/create.sh                  # headless node named android-dev
  ./vm/create.sh --desktop        # ...with Chrome Remote Desktop registered
  ./vm/create.sh issue-1234       # a node for one GitHub issue
  ./vm/create.sh --issue 1234 issue-1234   # ...and set Claude working on issue #1234
  ./vm/create.sh --ssh w-1        # ...and drop me into a shell on it once it's up
EOF
      exit 0 ;;
    --desktop) WANT_DESKTOP=1 ;;
    --headless) WANT_DESKTOP=0 ;;   # now the default; kept as an explicit no-op for back-compat
    --ssh) DO_SSH=1 ;;
    --issue) WORK_ISSUE="${2:?--issue needs a GitHub issue number}"; shift ;;
    --issue=*) WORK_ISSUE="${1#*=}" ;;
    -*) echo "create.sh: unknown option '$1' (try --help)" >&2; exit 1 ;;
    *) NAME="$1" ;;
  esac
  shift
done

source "$(dirname "$0")/config.sh"
require_env

NAME="${NAME:-$INSTANCE}"

# The golden image must exist first (run ./vm/bake.sh once).
if ! gcloud compute images describe "$GOLDEN_IMAGE" --project="$PROJECT" >/dev/null 2>&1; then
  echo "Golden image '$GOLDEN_IMAGE' not found. Build it once with:  ./vm/bake.sh" >&2
  exit 1
fi

# --- Claude Code auth: long-lived subscription OAuth token -----------------
# Minted once on this machine with `claude setup-token`, cached in .env, then reused
# for every node (including headless fleet workers). Skipped if you already set
# ANTHROPIC_API_KEY, or if there's no TTY / no local claude (e.g. fleet.sh workers).
if [[ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" && -z "${ANTHROPIC_API_KEY:-}" && -t 0 ]] && command -v claude >/dev/null; then
  echo
  echo "No Claude auth in .env — minting a long-lived token with 'claude setup-token'"
  echo "(requires a Claude subscription). Complete the browser authorization it shows."
  tokout="$(mktemp)"
  claude setup-token 2>&1 | tee "$tokout" || true
  CLAUDE_CODE_OAUTH_TOKEN="$(grep -oE 'sk-ant-oat[0-9A-Za-z_-]+' "$tokout" | tail -1 || true)"
  rm -f "$tokout"
  if [[ -z "$CLAUDE_CODE_OAUTH_TOKEN" ]]; then
    printf 'Paste the long-lived token shown above (or press Enter to skip): '
    read -r CLAUDE_CODE_OAUTH_TOKEN
  fi
  if [[ -n "$CLAUDE_CODE_OAUTH_TOKEN" ]] && ! grep -q '^CLAUDE_CODE_OAUTH_TOKEN=' "$REPO_ROOT/.env" 2>/dev/null; then
    printf '\n# Long-lived Claude Code OAuth token (from `claude setup-token`)\nCLAUDE_CODE_OAUTH_TOKEN=%s\n' \
      "$CLAUDE_CODE_OAUTH_TOKEN" >> "$REPO_ROOT/.env"
    echo "Cached CLAUDE_CODE_OAUTH_TOKEN in .env — future nodes reuse it non-interactively."
  fi
fi

# GitHub token to hand to the node (for cloning GIT_REPO): .env's GITHUB_TOKEN, else the
# local gh login. Non-interactive, so fleet workers get it too. Empty is fine for public repos.
GITHUB_TOKEN="${GITHUB_TOKEN:-$(gh auth token 2>/dev/null || true)}"
if [[ -n "${GIT_REPO:-}" && -z "$GITHUB_TOKEN" ]]; then
  echo "note: GIT_REPO set but no GitHub token (set GITHUB_TOKEN in .env or run 'gh auth login') — private clone will fail." >&2
fi

# --issue N sets Claude to work the issue in the cloned repo on first login — so it needs a
# repo to clone (and, to view the issue / open a PR, a GitHub token).
if [[ -n "${WORK_ISSUE:-}" && -z "${GIT_REPO:-}" ]]; then
  echo "--issue $WORK_ISSUE needs a repo to work in — set GIT_REPO in .env." >&2
  exit 1
fi

# Nested virtualization (KVM) for Android emulators — opt-in via NESTED_VIRT=1.
NV_FLAG=""
if [[ -n "${NESTED_VIRT:-}" ]]; then
  case "$MACHINE" in
    e2-*|t2a-*|t2d-*|n2d-*|c2d-*|c3d-*)
      echo "NESTED_VIRT needs an INTEL machine — GCP nested virt is VT-x only." >&2
      echo "AMD (n2d/c2d/c3d), E2, and Arm (t2a) never expose virtualization to the guest." >&2
      echo "Set MACHINE=n2-standard-4 (or n2-standard-8 for a grid) in .env." >&2
      exit 1 ;;
  esac
  NV_FLAG="--enable-nested-virtualization"
fi

echo "Creating $NAME ($MACHINE${NV_FLAG:+, KVM}) from $GOLDEN_IMAGE in $ZONE / $PROJECT …"
gcloud compute instances create "$NAME" \
  --project="$PROJECT" --zone="$ZONE" --machine-type="$MACHINE" $NV_FLAG \
  --image="$GOLDEN_IMAGE" --boot-disk-type=pd-balanced --boot-disk-size="${DISK_GB}GB" \
  --labels=environment=development,purpose=android-dev \
  --scopes=https://www.googleapis.com/auth/compute \
  --metadata=tailscale-authkey="$TAILSCALE_AUTHKEY",phone-ts-host="${PHONE_TS_HOST:-}",anthropic-api-key="${ANTHROPIC_API_KEY:-}",claude-oauth-token="${CLAUDE_CODE_OAUTH_TOKEN:-}",github-token="${GITHUB_TOKEN}",git-repo="${GIT_REPO:-}",git-branch="${GIT_BRANCH:-}",gradle-warm-task="${GRADLE_WARM_TASK:-}",work-issue="${WORK_ISSUE:-}" \
  --metadata-from-file=startup-script="$REPO_ROOT/vm/startup-golden.sh"

echo "Waiting for the node to be reachable (baked image, ~1 min)…"
wait_remote "$NAME" 'true'

# Finish provisioning YOUR login user before handing off, so the first `./vm/ssh.sh` is
# ready — no first-login race where Claude installs in the background. `wait_remote` above
# connected as (and thus created) the same account you SSH in as; Claude is baked into
# /etc/skel, but if that user didn't get it (skel miss / older image), install it now,
# synchronously, rather than lazily on your first interactive login.
echo "Finishing setup for your login user (Claude)…"
ssh_vm "$NAME" 'test -x "$HOME/.local/bin/claude" || curl -fsSL https://claude.ai/install.sh | bash >/dev/null 2>&1' \
  || echo "  note: couldn't pre-install Claude; it'll install on first login instead." >&2
echo " up. (Project clone + Gradle warm run in the background: ~/work/.warm.log)"

# --issue N: start the worker now, without waiting for a human to log in. A login shell
# sources /etc/profile.d, which fires the same first-login hook (zz-warmrepo) a person would
# trigger: it clones the repo and, with WORK_ISSUE set, hands it to Claude in tmux. The hook
# nohup-backgrounds the work (so this returns at once) and is marker-guarded (so your later
# SSH won't relaunch it). It runs as your login user, so `./vm/ssh.sh` drops you into the
# shared tmux 'main' where Claude is already working.
if [[ -n "${WORK_ISSUE:-}" ]]; then
  echo "Starting the Claude worker on issue #$WORK_ISSUE (no login needed)…"
  # One SSH: wait for startup-golden to have written the per-node env (GIT_REPO/WORK_ISSUE/
  # tokens) to this file, then run a login shell so it's in scope when the hook reads it. The
  # node's already reachable (two SSHs above), so an in-shell wait beats a second connection.
  ssh_vm "$NAME" 'until test -f /etc/profile.d/androidproject.sh; do sleep 5; done; bash -lc :' \
    || echo "  note: couldn't kick it off remotely; it'll start on your first login instead." >&2
  echo " Worker launched. SSH in anytime to watch: it's in tmux window 'issue-$WORK_ISSUE'."
fi

# --- Chrome Remote Desktop (opt-in via --desktop) -------------------------
# Headless is the default; a desktop is only set up when you pass --desktop. SKIP_CRD=1 in the
# env still force-disables it (fleet.sh sets it for bulk workers).
if [[ "${WANT_DESKTOP:-0}" != "1" || "${SKIP_CRD:-}" == "1" ]]; then
  echo "Headless — no desktop (pass --desktop to set up Chrome Remote Desktop)."
elif [[ -z "${CRD_PIN:-}" ]]; then
  echo "CRD_PIN not set in .env — skipping desktop. Register later: ./vm/crd-setup.sh '<code>' $NAME"
else
  CRD_URL="https://remotedesktop.google.com/headless"
  echo
  echo "Set up the Chrome Remote Desktop for this node (one-time). To get an auth code:"
  echo "  1. Opening $CRD_URL …   2. Begin -> Next -> Authorize   3. copy the command/code."
  command -v open >/dev/null && open "$CRD_URL" 2>/dev/null || echo "     (open $CRD_URL manually)"
  echo
  printf 'Paste the auth code (or the full start-host command), or press Enter to skip: '
  read -r CRD_INPUT
  if [[ -n "$CRD_INPUT" ]]; then
    if [[ "$CRD_INPUT" == *--code=* ]]; then     # accept a full pasted start-host command
      CODE="${CRD_INPUT#*--code=}"; CODE="${CODE%% *}"; CODE="${CODE//[\"\']/}"
    else                                          # ...or a bare code
      CODE="$CRD_INPUT"
    fi
    "$(dirname "$0")/crd-setup.sh" "$CODE" "$NAME"
  else
    echo "Skipped. Register later with: ./vm/crd-setup.sh '<code>' $NAME"
  fi
fi

echo
echo "Done. '$NAME' is up. Desktop (if registered): https://remotedesktop.google.com/access"

# --ssh: hand off straight into an interactive shell on the new node. exec so the SSH session
# replaces this script as the foreground process (reuses ssh.sh, which takes NAME as arg 1).
if [[ "${DO_SSH:-}" == "1" ]]; then
  echo "Connecting to '$NAME' over SSH…"
  exec "$(dirname "$0")/ssh.sh" "$NAME"
fi
echo "SSH:  gcloud compute ssh $NAME --zone=$ZONE --project=$PROJECT"
