#!/bin/bash
# PreToolUse hook (Bash): refuse a `git push` that is not routed through the
# `gh` credential helper.
#
# Pushing through the macOS keychain credential helper hangs or dies with
# `Device not configured` in the agent sandbox. The failure is silent in the
# worst way -- the branch simply never leaves the machine, and a later session
# reading the remote concludes the work was never started.
#
# The matching is deliberately structural rather than a substring search. This
# hook sees EVERY Bash command, and this repo documents the workaround in
# CLAUDE.md, docs/TRACKING.md and .claude/skills/ship/SKILL.md -- so a plain
# `case "$CMD" in *"git push"*)` also denies `grep -rn "git push" docs/`,
# `git commit -m "note the git push workaround"`, and every heredoc that writes
# those docs. A guard that blocks reading and writing prose about pushing is
# worse than no guard. So:
#
#   - heredoc bodies are skipped (that is where docs get written);
#   - quoted spans are blanked before looking for the verb (that is where
#     prose lives), while the `gh` marker is looked for in the ORIGINAL text
#     (the sanctioned form quotes the helper);
#   - the command is split on ; && || | and newlines, and each segment is
#     judged on its own, so one sanctioned push no longer whitelists a bare
#     push later in the same chain;
#   - a segment only counts if `git` is its first word and `push` appears as a
#     whole word -- `git push-something` and `echo git push` are not pushes.
set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0

CMD=$(jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$CMD" ] || exit 0

# Cheap bail-out: no "push" anywhere means nothing below can match.
case "$CMD" in *push*) ;; *) exit 0 ;; esac

# Join backslash continuations, so `git \<newline>  push` is still one segment.
CMD=$(printf '%s' "$CMD" | sed -e ':a' -e '/\\$/{N;s/\\\n//;ta' -e '}')

# Replace every quoted span with a single space. Bash 3.2, no regex engine:
# walk the string tracking which quote (if any) is open. Backslash escapes
# outside single quotes swallow the next character.
strip_quotes() {
  local s=$1 out="" i=0 c q=""
  while [ $i -lt ${#s} ]; do
    c=${s:$i:1}
    if [ -z "$q" ]; then
      case "$c" in
        \'|\") q=$c; out="$out " ;;
        \\) i=$((i + 1)) ;;
        *) out="$out$c" ;;
      esac
    else
      if [ "$c" = "$q" ]; then
        q=""
      elif [ "$q" = '"' ] && [ "$c" = "\\" ]; then
        i=$((i + 1))
      fi
    fi
    i=$((i + 1))
  done
  printf '%s' "$out"
}

# Is this segment a git invocation that pushes?
is_push() {
  local seg=$1
  # Two O(1) rejections before strip_quotes, whose bash-3.2 character loop is
  # quadratic in the segment length: a segment with no "push" at all cannot be
  # one, and neither can one whose first word is already something else. This
  # is what keeps a 20 kB heredoc mentioning "push" from costing seconds on a
  # hook that runs before every Bash call.
  case "$seg" in *push*) ;; *) return 1 ;; esac
  set -- $seg
  while [ $# -gt 0 ]; do
    case "$1" in
      *=*) shift ;;
      env|command|sudo|nohup|time) shift ;;
      *) break ;;
    esac
  done
  [ $# -gt 0 ] || return 1
  case "${1##*/}" in git|\"git\"|\'git\') ;; *) return 1 ;; esac

  # Only the head of a segment can hold the verb -- `git push` puts it inside
  # ~60 characters, the sanctioned `-c credential.helper=...` form inside ~100.
  # Capping bounds strip_quotes' quadratic loop on a long single-line
  # `git commit -m "...push..."`. It can only ever hide a verb, never invent
  # one: truncation removes trailing text, so a `push` that was inside a quote
  # stays inside it (the quote simply never closes) and no new UNQUOTED push
  # can appear. Errs toward allowing, which is the safe direction for a hook
  # that gates every Bash call.
  seg=${seg:0:2000}
  seg=$(strip_quotes "$seg")
  # Leading environment assignments and wrappers do not change the verb.
  set -- $seg
  while [ $# -gt 0 ]; do
    case "$1" in
      *=*) shift ;;
      env|command|sudo|nohup|time) shift ;;
      *) break ;;
    esac
  done
  [ $# -gt 0 ] || return 1
  case "${1##*/}" in git) ;; *) return 1 ;; esac
  shift
  while [ $# -gt 0 ]; do
    [ "$1" = "push" ] && return 0
    shift
  done
  return 1
}

# Walk the command line by line, skipping heredoc bodies, and collect the
# segments that are candidate pushes but carry no `gh` credential helper.
OFFENDER=""
DELIM=""
while IFS= read -r LINE; do
  if [ -n "$DELIM" ]; then
    # Inside a heredoc body: only the terminator line ends it.
    TRIMMED=${LINE#"${LINE%%[![:space:]]*}"}
    TRIMMED=${TRIMMED%"${TRIMMED##*[![:space:]]}"}
    [ "$TRIMMED" = "$DELIM" ] && DELIM=""
    continue
  fi

  # A heredoc opener: <<WORD, <<-WORD, <<'WORD', <<"WORD".
  case "$LINE" in
    *"<<"*)
      REST=${LINE##*<<}
      REST=${REST#-}
      REST=${REST#"${REST%%[![:space:]]*}"}
      case "$REST" in
        \'*) REST=${REST#\'}; DELIM=${REST%%\'*} ;;
        \"*) REST=${REST#\"}; DELIM=${REST%%\"*} ;;
        *) DELIM=${REST%%[[:space:]]*} ;;
      esac
      case "$DELIM" in
        ""|*[!A-Za-z0-9_]*) DELIM="" ;;   # `<<<` or an expression, not a heredoc
      esac
      LINE=${LINE%%<<*}
      ;;
  esac

  # Split the line into command segments. Only ; && || | separate commands.
  SEGS=$(printf '%s' "$LINE" | sed -e 's/&&/\n/g' -e 's/||/\n/g' -e 's/[;|]/\n/g')
  while IFS= read -r SEG; do
    [ -n "$SEG" ] || continue
    is_push "$SEG" || continue
    case "$SEG" in *"gh auth git-credential"*) continue ;; esac
    OFFENDER=$SEG
    break
  done <<EOS
$SEGS
EOS
  [ -n "$OFFENDER" ] && break
done <<EOC
$CMD
EOC

[ -n "$OFFENDER" ] || exit 0

# Kept out of the jq program: the suggested command contains single quotes.
read -r -d '' REASON <<MSG || true
A bare \`git push\` hangs on the osxkeychain credential helper in this sandbox --
it fails as \`Device not configured\` and leaves the branch silently unpushed,
which a later session reads as "this work was never started".

Blocked on this segment:

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
