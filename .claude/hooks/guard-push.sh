#!/bin/bash
# PreToolUse hook (Bash): refuse a `git push` that is not routed through the
# `gh` credential helper.
#
# Pushing through the macOS keychain credential helper hangs or dies with
# `Device not configured` in the agent sandbox. The failure is silent in the
# worst way -- the branch simply never leaves the machine, and a later session
# reading the remote concludes the work was never started.
#
# Note what this is and is not worth. A machine may already be safe by config:
# `git config --get-urlmatch credential.helper <remote-url>` resolving to the
# gh helper means a bare push on THAT remote never reaches osxkeychain. But
# ~/.gitconfig is machine-local and unversioned, a fresh container or a second
# machine has none of it, and any non-GitHub remote still falls through to
# osxkeychain. The guard is cheap insurance against a failure whose signature
# is "the work was never done"; it is not a claim that every bare push breaks.
#
# The matching is structural, not a substring search, and the reason is that
# this hook sees EVERY Bash command while the repo's own CLAUDE.md,
# docs/TRACKING.md and skills/ship/SKILL.md are all ABOUT `git push`. A plain
# `case "$CMD" in *"git push"*)` denies `grep -rn "git push" docs/`,
# `git commit -m "note the git push workaround"`, and every PR body that
# explains the rule. A guard that blocks writing the documentation is worse
# than no guard, because the next session simply routes around it. So:
#
#   1. backslash continuations are joined -- one command, one line;
#   2. the sanctioned `-c credential.helper='!gh auth git-credential'` is
#      normalised to an unquoted sentinel BEFORE anything else, so it survives
#      the blanking in step 3 and is still recognisable per segment;
#   3. every quoted span is blanked to spaces -- INCLUDING newlines inside it,
#      so a multi-line `--body "..."` collapses onto one logical line instead
#      of masquerading as several commands. That is what keeps
#      `gh pr create --body "<a PR body about git push>"` from being denied;
#   4. heredoc bodies are skipped, since that is the other place docs get
#      written;
#   5. what is left is split on ; && || | and newlines, and each segment is
#      judged alone -- so one sanctioned push no longer whitelists a bare push
#      later in the same chain;
#   6. a segment counts only if `git` is its first word and `push` lands in
#      the SUBCOMMAND slot, after git's global options. `git stash push`,
#      `git help push` and `git log --grep push` are not pushes.
#
# Known and deliberate gaps, all in the allow direction: a push hidden inside a
# quoted string (`bash -c "git push"`) or a command substitution is not seen,
# because blanking quoted spans is the same mechanism that protects the prose.
# `gh pr create` is allowed on purpose too -- it is the sanctioned way to open a
# PR and the /ship flow depends on it. Erring toward allowing is the right
# direction for something that gates every Bash call.
set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0
command -v awk >/dev/null 2>&1 || exit 0

CMD=$(jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$CMD" ] || exit 0

# Cheap bail-out: no "push" anywhere means nothing below can match.
case "$CMD" in *push*) ;; *) exit 0 ;; esac

MARKER=credential.helper=GHSANCTIONED
HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# 1 + 2 + 3. Two normalisations have to happen BEFORE the blanking, because
# both markers live inside quotes and would otherwise be erased with them: the
# heredoc delimiter (`<<'"'"'EOF'"'"'` -> `<<EOF`, so step 4 can still see where a body
# starts) and the sanctioned credential helper. Blanking itself is a character
# walk, so it lives in awk rather than a bash loop -- the bash version was
# quadratic and cost seconds on a large heredoc; this is ~80 ms on 5 MB.
SCAN=$(printf '%s' "$CMD" \
  | sed -e ':a' -e '/\\$/{N;s/\\\n//;ta' -e '}' \
  | sed -e "s/<<\(-\{0,1\}\)['\"]\([A-Za-z_][A-Za-z0-9_]*\)['\"]/<<\1\2/g" \
  | sed -e "s/credential\.helper=['\"]\{0,1\}!\{0,1\}[^'\" ]*gh auth git-credential['\"]\{0,1\}/$MARKER/g" \
  | awk -f "$HOOK_DIR/blank-quotes.awk") || exit 0

# Step over leading environment assignments, wrappers and shell keywords, none
# of which change which program runs, and require what is left to be `git`.
# Leaves the remaining words in SKIPPED.
SKIPPED=""
skip_to_git() {
  local first
  while [ $# -gt 0 ]; do
    case "$1" in
      *=*) shift ;;
      env|command|sudo|nohup|time|timeout) shift ;;
      # Keywords that can precede or follow a command in a compound statement.
      if|while|until|then|do|else|elif|!|'{'|'(') shift ;;
      # `timeout 60 git push` -- a leading bare number is never a program.
      [0-9]*) shift ;;
      *) break ;;
    esac
  done
  [ $# -gt 0 ] || return 1
  # `(git push)` glues punctuation onto the first word; `{ git push; }` does
  # not, because `{` is always its own word (handled above).
  first=${1#[({]}
  case "${first##*/}" in git) ;; *) return 1 ;; esac
  shift
  SKIPPED=$*
  return 0
}

# Is this segment a git invocation whose SUBCOMMAND is push? Quoted spans are
# already blanked by the time a segment gets here.
is_push() {
  local seg=$1 verb
  # Two O(1) rejections first: a segment with no "push" cannot be one, and
  # `set --` on a long segment is not free.
  case "$seg" in *push*) ;; *) return 1 ;; esac
  # `set --` word-splits, and globbing is on by default: a segment containing
  # `*` would otherwise expand against whatever directory the hook happens to
  # run in, so the same command could be judged differently in two checkouts.
  set -f
  set -- ${seg:0:2000}
  if ! skip_to_git "$@"; then set +f; return 1; fi
  set -- $SKIPPED
  set +f

  # `push` must be git's SUBCOMMAND, not merely a word somewhere in the argv.
  # Scanning every position denies `git stash push -m wip` (purely local, and
  # the modern spelling of `git stash save`), `git help push`,
  # `git log --oneline --grep push` and `git diff HEAD -- push` -- all
  # ordinary, all unrecoverable for the agent in that turn, and none of them a
  # push. So step over git's global options and judge only the token that
  # lands in the subcommand slot.
  while [ $# -gt 0 ]; do
    case "$1" in
      # Global options that consume the NEXT argument.
      -C|-c|--git-dir|--work-tree|--namespace|--exec-path|--super-prefix)
        [ $# -ge 2 ] || return 1
        shift 2 ;;
      # Everything else beginning with `-` is self-contained
      # (-c k=v, --git-dir=..., --no-pager, -p, --bare, ...).
      -*) shift ;;
      *) break ;;
    esac
  done
  [ $# -gt 0 ] || return 1
  # `(git push)` and `do git push; done` leave punctuation on the last word.
  verb=${1%%;*}
  verb=${verb%%)*}
  [ "$verb" = "push" ]
}

# 4 + 5. Walk what is left line by line, skipping heredoc bodies.
OFFENDER=""
DELIM=""
while IFS= read -r LINE; do
  if [ -n "$DELIM" ]; then
    TRIMMED=${LINE#"${LINE%%[![:space:]]*}"}
    TRIMMED=${TRIMMED%"${TRIMMED##*[![:space:]]}"}
    [ "$TRIMMED" = "$DELIM" ] && DELIM=""
    continue
  fi

  # A heredoc opener: <<WORD, <<-WORD, <<'WORD', <<"WORD". Note `<<<` is a
  # herestring and `$((1<<3))` is arithmetic -- neither opens a body, and
  # neither may truncate the line, or a real push after it would be lost.
  case "$LINE" in
    *"<<"*)
      PRE=${LINE%<<*}
      REST=${LINE##*<<}
      REST=${REST#-}
      REST=${REST#"${REST%%[![:space:]]*}"}
      CAND=${REST%%[[:space:];|&]*}
      case "$CAND" in
        ""|*[!A-Za-z0-9_]*) CAND="" ;;
      esac
      if [ -n "$CAND" ]; then
        DELIM=$CAND
        # Drop only the `<<DELIM` token. Anything after it on the opener line
        # is a command that still runs before the body is even read --
        # `cat f <<EOF; git push` pushes -- so truncating the rest of the line
        # would lose it.
        LINE="$PRE ${REST#"$CAND"}"
      fi
      ;;
  esac

  SEGS=$(printf '%s' "$LINE" | sed -e 's/&&/\n/g' -e 's/||/\n/g' -e 's/[;|]/\n/g')
  while IFS= read -r SEG; do
    [ -n "$SEG" ] || continue
    is_push "$SEG" || continue
    case "$SEG" in *"$MARKER"*) continue ;; esac
    OFFENDER=$SEG
    break
  done <<EOS
$SEGS
EOS
  [ -n "$OFFENDER" ] && break
done <<EOC
$SCAN
EOC

[ -n "$OFFENDER" ] || exit 0

# Kept out of the jq program: the suggested command contains single quotes.
read -r -d '' REASON <<MSG || true
A bare \`git push\` hangs on the osxkeychain credential helper in this sandbox --
it fails as \`Device not configured\` and leaves the branch silently unpushed,
which a later session reads as "this work was never started".

Blocked on this segment (quoted text shown blanked):

  ${OFFENDER}

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
