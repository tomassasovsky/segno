#!/bin/bash
# Tests for the hooks in .claude/hooks/.
#
# These hooks run unattended on EVERY session in this repo, so a misfire blocks
# work repo-wide and a silent reformat is worse than no hook at all. That makes
# "I read it and it looks right" an inadequate standard: run this before
# changing either script.
#
#   bash .claude/hooks/test/run_hook_tests.sh
set -uo pipefail
cd "$(dirname "$0")/../../.." || exit 1

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

GUARD=.claude/hooks/guard-push.sh
FORMAT=.claude/hooks/format-dart.sh
PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }

# ---- guard-push -------------------------------------------------------------
# The guard must deny a push that would go through osxkeychain, and must NOT
# deny commands that merely CONTAIN the words "git push" -- this repo documents
# the workaround in CLAUDE.md, docs/TRACKING.md and skills/ship/SKILL.md, so
# grepping and writing that prose has to keep working.
g() { # g <deny|allow> <command>
  local want=$1 cmd=$2 out got
  out=$(printf '%s' "$cmd" | jq -Rs '{tool_name:"Bash",tool_input:{command:.}}' |
        bash "$GUARD" 2>&1)
  if [ -z "$out" ]; then
    got=allow
  else
    got=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null) || got=malformed
  fi
  if [ "$got" = "$want" ]; then ok; else
    bad "guard-push: got '$got', want '$want' for: $(printf '%s' "$cmd" | tr '\n' '~')"
  fi
}

# Real pushes that would hit the keychain.
g deny 'git push'
g deny 'git push origin HEAD:my-branch'
g deny 'git push --force-with-lease origin HEAD'
g deny 'git   push'
g deny 'git -C /some/dir push origin main'
g deny '/usr/bin/git push origin main'
g deny 'GIT_TRACE=1 git push origin main'
g deny 'cd /x && git push'
g deny 'git commit -m x; git push'
g deny 'git push || echo failed'
g deny 'git push 2>&1 | tail -3'
# One sanctioned push must not whitelist a bare one later in the same chain.
g deny "git -c credential.helper='!gh auth git-credential' push origin A && git push origin B"
# A continuation is still one command.
g deny "$(printf 'git \\\n  push origin main')"
# A heredoc body is prose, but a real push after it is not.
g deny "$(printf 'cat > docs/x.md <<%s\n    git push origin main\n%s\ngit push\n' "'EOF'" 'EOF')"

# The sanctioned form.
g allow "git -c credential.helper='!gh auth git-credential' push origin HEAD:b"
g allow "git -c credential.helper='!gh auth git-credential' push -u origin b 2>&1 | tail -5"
g allow "$(printf 'git \\\n  -c credential.helper=%s push origin main' "'!gh auth git-credential'")"
# Not pushes at all.
g allow 'git status'
g allow 'gh pr create --fill'
g allow 'ls'
g allow ''
g allow 'git push-something'
# Prose about pushing: reading it, grepping it, committing it, writing it.
g allow 'echo "remember to git push later"'
g allow 'grep -rn "git push" docs/'
g allow 'cat docs/TRACKING.md | grep -c "git push"'
g allow "git commit -m 'document the git push workaround'"
g allow 'git log --oneline | grep push'
g allow 'git log --grep="push"'
g allow "$(printf 'cat > docs/x.md <<%s\nRun:\n\n    git push origin main\n%s\n' "'EOF'" 'EOF')"

# ---- format-dart ------------------------------------------------------------
# The one thing this hook must never do is run `dart format` in a worktree that
# has not been `pub get`-resolved: the `formatter: trailing_commas: preserve`
# setting reaches the formatter through analysis_options.yaml's
# `include: package:very_good_analysis/...`, which needs
# `.dart_tool/package_config.json`. Without it every trailing comma in the repo
# collapses.
f_dir=$(mktemp -d)
mkdir -p "$f_dir/pkg/lib"
printf 'name: fixture\nenvironment:\n  sdk: ^3.11.0\n' > "$f_dir/pkg/pubspec.yaml"
printf 'void f(\n  int a,\n  int b,\n) {}\n' > "$f_dir/pkg/lib/a.dart"
cp "$f_dir/pkg/lib/a.dart" "$f_dir/expected.dart"

printf '%s' "$f_dir/pkg/lib/a.dart" | jq -Rs '{tool_input:{file_path:.}}' |
  bash "$FORMAT" >/dev/null 2>&1
if cmp -s "$f_dir/expected.dart" "$f_dir/pkg/lib/a.dart"; then ok; else
  bad "format-dart: reformatted a file in an unresolved package (trailing commas would collapse repo-wide)"
fi

# Non-Dart files are left alone even when resolved.
printf 'x   =1\n' > "$f_dir/pkg/lib/a.txt"
cp "$f_dir/pkg/lib/a.txt" "$f_dir/expected.txt"
printf '%s' "$f_dir/pkg/lib/a.txt" | jq -Rs '{tool_input:{file_path:.}}' |
  bash "$FORMAT" >/dev/null 2>&1
cmp -s "$f_dir/expected.txt" "$f_dir/pkg/lib/a.txt" && ok || bad "format-dart: touched a non-Dart file"

# A path that does not exist must be a no-op, not an error.
printf '%s' "$f_dir/pkg/lib/gone.dart" | jq -Rs '{tool_input:{file_path:.}}' |
  bash "$FORMAT" >/dev/null 2>&1
[ $? -eq 0 ] && ok || bad "format-dart: non-zero exit on a missing file"

rm -rf "$f_dir"

# ---- report -----------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "ALL PASSED"
