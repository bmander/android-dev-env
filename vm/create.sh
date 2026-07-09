#!/usr/bin/env bash
# Create an android-dev node from the golden image (fast boot). Usage:
#   ./vm/create.sh [--headless] [name]
# Requires a reusable TAILSCALE_AUTHKEY in .env. The Chrome Remote Desktop registration is
# offered interactively unless --headless (or SKIP_CRD=1, which fleet.sh sets).
NAME=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      cat <<'EOF'
Usage: ./vm/create.sh [--headless] [NAME]

Create an android-dev VM node from the golden image (~1 min boot). Config comes from .env
(see .env.example); TAILSCALE_AUTHKEY is required. Once up, the node prompts once for the
Chrome Remote Desktop auth code (skip with --headless), then on boot clones $GIT_REPO into
~/work, warms Gradle, and wires phone-adb / Claude / GitHub auth from your .env.

Arguments:
  NAME                    instance name (default: $INSTANCE, i.e. android-dev)

Options:
  --headless              skip the Chrome Remote Desktop desktop-registration prompt
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
  ./vm/create.sh                  # primary node named android-dev (prompts for CRD)
  ./vm/create.sh issue-1234       # a node for one GitHub issue
  ./vm/create.sh --headless w-1   # a headless worker, no desktop
EOF
      exit 0 ;;
    --headless) SKIP_CRD=1 ;;
    -*) echo "create.sh: unknown option '$1' (try --help)" >&2; exit 1 ;;
    *) NAME="$1" ;;
  esac
  shift
done

source "$(dirname "$0")/config.sh"
require_env

NAME="${NAME:-$INSTANCE}"

# The golden image must exist first (run ./vm/install.sh once).
if ! gcloud compute images describe "$GOLDEN_IMAGE" --project="$PROJECT" >/dev/null 2>&1; then
  echo "Golden image '$GOLDEN_IMAGE' not found. Build it once with:  ./vm/install.sh" >&2
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
  --metadata=tailscale-authkey="$TAILSCALE_AUTHKEY",phone-ts-host="${PHONE_TS_HOST:-}",anthropic-api-key="${ANTHROPIC_API_KEY:-}",claude-oauth-token="${CLAUDE_CODE_OAUTH_TOKEN:-}",github-token="${GITHUB_TOKEN}",git-repo="${GIT_REPO:-}",git-branch="${GIT_BRANCH:-}",gradle-warm-task="${GRADLE_WARM_TASK:-}" \
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

# --- Chrome Remote Desktop (primary node only) ----------------------------
if [[ "${SKIP_CRD:-}" == "1" ]]; then
  echo "Headless — skipping Chrome Remote Desktop registration."
elif [[ -z "${CRD_PIN:-}" ]]; then
  echo "CRD_PIN not set in .env — skipping desktop. Register later: ./vm/crd-setup.sh '<code>'"
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
echo "SSH:  gcloud compute ssh $NAME --zone=$ZONE --project=$PROJECT"
