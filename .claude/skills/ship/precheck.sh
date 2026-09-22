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
  # `design` is in the list because the repo has merged one (#548) with CI
  # green. Keep this list a mirror of what CI accepts, never a stricter one.
  TYPES="build|chore|ci|design|docs|feat|fix|perf|refactor|revert|style|test"
  if ! printf '%s' "$TITLE" | grep -qE "^($TYPES)(\([a-z0-9 ,._/-]+\))?!?: .+"; then
    echo "FAIL  semantic title"
    echo "      '$TITLE'"
    echo "      expected: type(optional-scope): description"
    echo "      types: $TYPES"
    RC=1
  else
    echo "PASS  semantic title"
    # Advisory only, and deliberately so. CI is
    # very_good_workflows/semantic_pull_request.yml@v1, which sets no
    # subjectPattern -- so casing and punctuation are unchecked there. Thirty
    # of the last four hundred merged titles start their subject with a
    # capital, nearly all proper nouns (`Android`, `Wi-Fi`, `AppText`,
    # `Ableton`). A local pre-flight that fails what CI merges is a gate the
    # agent learns to route around; keep it a subset of CI, never a superset.
    SUBJECT=${TITLE#*: }
    if printf '%s' "$SUBJECT" | grep -qE '^[A-Z][a-z]'; then
      echo "WARN  semantic title  (subject starts with a capital: '$SUBJECT')"
      echo "      house style is lowercase unless it is a proper noun. CI does not check this."
    fi
    if printf '%s' "$SUBJECT" | grep -qE '\.$'; then
      echo "WARN  semantic title  (subject ends with a period). CI does not check this."
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
  # Split on newlines only: an unquoted $MD would also split a path containing
  # a space into two nonexistent arguments.
  MD_FILES=()
  while IFS= read -r f; do [ -n "$f" ] && MD_FILES+=("$f"); done <<EOF
$MD
EOF
  if [ ${#MD_FILES[@]} -eq 0 ]; then
    echo "SKIP  cspell  (no Markdown changed)"
  else
    OUT=$(mktemp)
    # Keep the summary line: cspell exits non-zero both for real spelling issues
    # and for "checked nothing at all", and those mean opposite things.
    npx --yes cspell@latest --config .github/cspell.json --no-progress \
      "${MD_FILES[@]}" >"$OUT" 2>&1
    CS_RC=$?
    SUMMARY=$(grep -oE 'Files checked: [0-9]+' "$OUT" | head -1)
    CHECKED=$(printf '%s' "$SUMMARY" | grep -oE '[0-9]+')
    if [ -z "$SUMMARY" ]; then
      # No summary line at all means cspell never ran -- npx could not fetch it,
      # or the remote dictionaries in .github/cspell.json were unreachable.
      # Reporting that as "nothing to check" is how a spell gate silently stops
      # being a gate, so say what actually happened and fail.
      echo "FAIL  cspell  (the tool did not run -- no 'Files checked' summary)"
      sed 's/^/      /' "$OUT" | head -20
      RC=1
    elif [ "$CHECKED" = "0" ]; then
      # The repo config sets useGitignore, so gitignored paths are skipped here
      # exactly as they are in CI. Nothing to gate.
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
