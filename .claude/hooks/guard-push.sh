#!/bin/bash
# PreToolUse hook (Bash): refuse a bare `git push`.
#
# Pushing through the macOS keychain credential helper hangs or dies with
# `Device not configured` in the agent sandbox. The failure is silent in the
# worst way -- the branch simply never leaves the machine, and a later session
# reading the remote concludes the work was never started. Route pushes through
# the `gh` credential helper instead.
set -euo pipefail

command -v jq >/dev/null 2>&1 || exit 0

CMD=$(jq -r '.tool_input.command // empty')
[ -n "$CMD" ] || exit 0

# Not a push at all.
case "$CMD" in
  *"git push"*|*"git "*" push"*) ;;
  *) exit 0 ;;
esac

# Already routed through gh -- let it through.
case "$CMD" in
  *"gh auth git-credential"*) exit 0 ;;
esac

# Kept out of the jq program: the suggested command contains single quotes.
read -r -d '' REASON <<'MSG' || true
A bare `git push` hangs on the osxkeychain credential helper in this sandbox --
it fails as `Device not configured` and leaves the branch silently unpushed,
which a later session reads as "this work was never started".

Re-run it through the gh credential helper, keeping every other argument the same:

  git -c credential.helper='!gh auth git-credential' push <args>
MSG

jq -n --arg reason "$REASON" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $reason
  }
}'
