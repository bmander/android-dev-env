#!/usr/bin/env bash
# Set an autonomous Claude session working on a GitHub issue, in a tmux window of the shared
# "main" session — so `./vm/ssh.sh` drops you straight into watching it. Wired up by
# create.sh --issue N  ->  WORK_ISSUE metadata  ->  warm-repo (right after the clone).
#   work-issue <issue-number> [repo-dir]
#
# Auth comes from the environment the caller inherits (CLAUDE_CODE_OAUTH_TOKEN / GH_TOKEN,
# written to /etc/profile.d by startup-golden.sh). gh infers the repo from the git remote.
set -uo pipefail

ISSUE="${1:?usage: work-issue <issue-number> [repo-dir]}"
DIR="${2:-$PWD}"

command -v claude >/dev/null 2>&1 || { echo "work-issue: claude not installed" >&2; exit 1; }
command -v tmux   >/dev/null 2>&1 || { echo "work-issue: tmux not installed" >&2; exit 1; }

PROMPT="Work on GitHub issue #$ISSUE in this repository. Run \`gh issue view $ISSUE\` to read \
it and its comments, create a branch, implement the change, and verify it builds. Then commit \
your work and open a pull request that closes the issue; if anything is ambiguous, spell out \
your assumptions in the PR description."

# Run via a login+interactive shell so the claude() wrapper (onboarding + folder-trust
# pre-accept, from /etc/profile.d) is in scope and the auth/env vars are loaded. tmux gives
# it a pty, so the TUI runs and you can attach to watch or take over. --dangerously-skip-
# permissions: this is a throwaway single-user VM built to run Claude unattended. `exec bash
# -li` keeps the window open (in the repo) after Claude exits. tmux execs these argv directly
# (no intervening sh -c), so INNER only needs the one layer of quoting on $DIR/$PROMPT.
INNER="cd $(printf %q "$DIR") && claude --dangerously-skip-permissions $(printf %q "$PROMPT"); exec bash -li"
WIN="issue-$ISSUE"

if tmux has-session -t main 2>/dev/null; then
  tmux new-window -t main -n "$WIN" bash -lic "$INNER"
else
  tmux new-session -d -s main -n "$WIN" bash -lic "$INNER"
fi
echo "work-issue: Claude working on issue #$ISSUE — tmux session 'main', window '$WIN'."
