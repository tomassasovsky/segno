#!/bin/bash
# Pre-flight for the two CI gates that are cheap to check locally and annoying
# to discover after the fact: the semantic PR title, and cspell over Markdown.
#
# Usage: precheck.sh "<proposed pr title>" [base-ref]
set -uo pipefail

TITLE=${1:-}
BASE=${2:-origin/master}
ROOT=$(git rev-parse --show-toplevel)
cd "$ROOT" || exit 1

RC=0

# --- semantic PR title ------------------------------------------------------
# CI runs very_good_workflows' semantic_pull_request, i.e. conventional commits.
if [ -z "$TITLE" ]; then
  echo "SKIP  semantic title  (no title passed)"
else
  TYPES="build|chore|ci|docs|feat|fix|perf|refactor|revert|style|test"
  if ! printf '%s' "$TITLE" | grep -qE "^($TYPES)(\([a-z0-9 ,._/-]+\))?!?: .+"; then
    echo "FAIL  semantic title"
    echo "      '$TITLE'"
    echo "      expected: type(optional-scope): description"
    echo "      types: $TYPES"
    RC=1
  else
    SUBJECT=${TITLE#*: }
    if printf '%s' "$SUBJECT" | grep -qE '^[A-Z][a-z]'; then
      echo "FAIL  semantic title  (description starts with a capital: '$SUBJECT')"
      RC=1
    elif printf '%s' "$SUBJECT" | grep -qE '\.$'; then
      echo "FAIL  semantic title  (description ends with a period)"
      RC=1
    else
      echo "PASS  semantic title"
    fi
  fi
fi

# --- cspell over Markdown ---------------------------------------------------
# CI spell-checks **/*.md with modified_files_only: false, so a new word in a
# doc fails the run for everyone. Unknown words go in .github/cspell.json.
if ! command -v npx >/dev/null 2>&1; then
  echo "SKIP  cspell  (npx not on PATH)"
else
  MD=$(git diff --name-only "$BASE"...HEAD -- '*.md'; git diff --name-only HEAD -- '*.md'; git ls-files --others --exclude-standard -- '*.md')
  MD=$(printf '%s\n' "$MD" | sort -u | grep -v '^$')
  if [ -z "$MD" ]; then
    echo "SKIP  cspell  (no Markdown changed)"
  else
    OUT=$(mktemp)
    # Keep the summary line: cspell exits non-zero both for real spelling issues
    # and for "checked nothing at all", and those mean opposite things.
    # shellcheck disable=SC2086
    npx --yes cspell@latest --config .github/cspell.json --no-progress $MD >"$OUT" 2>&1
    CS_RC=$?
    CHECKED=$(grep -oE 'Files checked: [0-9]+' "$OUT" | grep -oE '[0-9]+' | head -1)
    if [ "${CHECKED:-0}" = "0" ]; then
      # The repo config sets useGitignore, so gitignored paths (.claude/** among
      # them) are skipped here exactly as they are in CI. Nothing to gate.
      echo "SKIP  cspell  (0 files checked -- changed Markdown is gitignored, as it is in CI)"
    elif [ $CS_RC -eq 0 ]; then
      echo "PASS  cspell  ($CHECKED file(s))"
    else
      echo "FAIL  cspell"
      grep -v '^CSpell:' "$OUT" | sed 's/^/      /' | head -30
      echo "      -> fix the spelling, or add the word to .github/cspell.json (\"words\", alphabetical)"
      RC=1
    fi
    rm -f "$OUT"
  fi
fi

exit $RC
