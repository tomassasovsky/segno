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

# Absolute: some cases below cd into a fixture directory to prove the hooks
# do not depend on the cwd.
GUARD=$PWD/.claude/hooks/guard-push.sh
FORMAT=$PWD/.claude/hooks/format-dart.sh
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
g deny 'git push --tags'
g deny 'git -c http.sslVerify=false push origin main'
g deny 'git add -A && git commit -m "wip" && git push -u origin HEAD'
g deny 'set -e; git fetch; git push'
g deny 'git rebase --onto main HEAD~2 && git push --force-with-lease'
g deny 'for f in a b; do echo $f; done && git push'
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
# Wrapped pushes are still pushes -- these are ordinary agent constructs.
g deny '(git push)'
g deny '{ git push; }'
g deny 'if ! git push; then echo fail; fi'
g deny 'while ! git push; do sleep 1; done'
g deny 'until git push; do sleep 1; done'
# `<<` that opens no heredoc must not swallow the rest of the line, and an
# opener's own line still runs before the body is read.
g deny 'grep -q x <<< "abc" && git push'
g deny 'x=$((1<<3)); git push'
g deny 'echo "a << b" && git push'
g deny "$(printf 'cat /tmp/f <<EOF; git push\nbody\nEOF')"
g deny "$(printf 'cat > f <<EOF && git push\nbody\nEOF')"
g deny 'if true; then git push; fi'
g deny 'for b in a b; do git push origin $b; done'
g deny 'timeout 60 git push'
# The sanctioned marker has to be a credential.helper assignment, not prose,
# and the internal sentinel that assignment is rewritten to must not be
# forgeable by typing it.
g deny 'git push origin main # remember to use gh auth git-credential'
g deny 'git push origin main # credential.helper=GHSANCTIONED'
g deny 'echo credential.helper=GHSANCTIONED; git push'
# Globbing must not change the verdict. Run these from a directory containing
# a file literally named `push`: without `set -f`, `git *push*` expands to
# `git push` and the answer starts depending on the cwd.
GLOBDIR=$(mktemp -d); : > "$GLOBDIR/push"
KEEP=$PWD; cd "$GLOBDIR" || exit 1
g allow 'git add *push*'
g allow 'git *push*'
cd "$KEEP" || exit 1; rm -rf "$GLOBDIR"
# A heredoc body is prose, but a real push after it is not.
g deny "$(printf 'cat > docs/x.md <<%s\n    git push origin main\n%s\ngit push\n' "'EOF'" 'EOF')"

# The sanctioned form.
g allow "git -c credential.helper='!gh auth git-credential' push origin HEAD:b"
g allow "git -c credential.helper='!gh auth git-credential' push -u origin b 2>&1 | tail -5"
g allow "$(printf 'git \\\n  -c credential.helper=%s push origin main' "'!gh auth git-credential'")"
# Not pushes at all.
g allow 'git status'
# Deliberate: `gh pr create` does push internally, but it is the sanctioned way
# to open a PR and the /ship flow depends on it. Denying it to catch that push
# would break the documented path.
g allow 'gh pr create --fill'
g allow 'ls'
g allow ''
g allow 'git push-something'
# `push` outside the subcommand slot is not a push. Denying these blocks
# routine local commands with a remediation that makes no sense for them.
g allow 'git stash push -m wip'
g allow 'git stash push -u'
g allow 'git stash push --keep-index -- lib/'
g allow 'git help push'
g allow 'git config alias.p push'
g allow 'git diff HEAD -- push'
g allow 'git log --oneline --grep push'
g allow 'git show HEAD:push'
# Prose about pushing: reading it, grepping it, committing it, writing it.
g allow 'echo "remember to git push later"'
g allow 'grep -rn "git push" docs/'
g allow 'cat docs/TRACKING.md | grep -c "git push"'
g allow "git commit -m 'document the git push workaround'"
g allow 'git log --oneline | grep push'
g allow 'git log --grep="push"'
g allow 'git reflog | grep push'
g allow 'man git-push'
# Tooling that reads or rewrites the prose. All of these appear in ordinary
# sessions in this repo, and a deny is unrecoverable for the agent in that turn.
g allow 'rg "git push" -n docs/'
g allow "sed -i '' 's/git push/foo/' file.md"
g allow 'python3 -c "print(\"git push\")"'
g allow "awk '/git push/{print}' CLAUDE.md"
g allow "git config --global alias.pushall 'push --all'"
g allow "$(printf 'cat > docs/x.md <<%s\nRun:\n\n    git push origin main\n%s\n' "'EOF'" 'EOF')"
g allow "$(printf 'cat > docs/x.md <<EOF\n    git push origin main\nEOF')"
# A multi-line quoted argument is ONE argument, not several commands. /ship
# tells the agent to write PR bodies explaining this very rule, so denying them
# would break the documented flow on its own documentation.
g allow "$(printf 'gh pr create --title "fix: x" --body "## What\n\ngit push is denied unless routed through the gh helper.\n\nCloses #937"')"
g allow "$(printf 'git commit -m "chore: x\n\ngit push through the gh helper is the only sanctioned form.\n"')"
g allow "$(printf 'gh pr comment 938 --body "CLAUDE.md says:\ngit push must go through the gh credential helper."')"
g allow 'git commit -m "chore: x && git push"'
# `\"` does not close a double-quoted string in bash. A blanker that thinks it
# does un-blanks the rest of the body, and a separator in the leaked span
# manufactures a `git push` segment out of prose.
g allow 'gh pr create --body "never write \"cd x && git push\" in a script"'
g allow 'git commit -m "docs: explain \"cd repo; git push\" and why it fails"'
g deny  'git commit -m "say \"x\"" && git push'
# The two boundaries of the escape handling. A span that ends too EARLY denies
# prose; one that ends too LATE swallows a real push. `\\"` is an escaped
# backslash followed by the real terminator, so the push after it is visible;
# `\"` is an escaped quote, so the push inside the string is not.
g deny  'echo "a\\" && git push'
g allow 'echo "a\" && git push"'
g deny  'echo "a\\\"" && git push'
g deny  'echo "a" && git push && echo "b"'
g deny  'echo "a" ; git push ; echo "b"'
# Single-quoted spans containing separators: without single-quote blanking at
# all, both of these become deny.
g allow "echo 'x; git push; y'"
g allow "sed -i '' 's/a; git push; b/c/' docs/x.md"

# A PreToolUse hook that errors blocks the Bash tool outright, so malformed or
# absent input must be a silent allow, never a crash. Bound the run time too:
# this executes before every Bash call.
raw() { # raw <stdin> <label>
  local out
  out=$(printf '%s' "$1" | bash "$GUARD" 2>&1)
  if [ $? -eq 0 ] && [ -z "$out" ]; then ok; else
    bad "guard-push: expected a silent allow for $2, got rc=$? out='$out'"
  fi
}
raw '' 'empty stdin'
raw 'not json at all' 'malformed json'
raw '{"tool_name":"Read","tool_input":{"file_path":"/x"}}' 'a non-Bash payload'
raw '{"tool_input":{"command":null}}' 'a null command'

# 500 kB, and a 2 s ceiling. Sized so that reverting the quote-blanking to a
# bash character loop blows the budget rather than sneaking under it: this
# hook runs before every Bash call, so an unbounded cost is a defect.
BIG=$(printf 'git commit -m "push %s"' "$(head -c 500000 /dev/zero | tr '\0' 'x')")
START=$(date +%s)
printf '%s' "$BIG" | jq -Rs '{tool_input:{command:.}}' | bash "$GUARD" >/dev/null 2>&1
ELAPSED=$(( $(date +%s) - START ))
if [ "$ELAPSED" -le 2 ]; then ok; else
  bad "guard-push: took ${ELAPSED}s on a 500 kB command -- it runs before every Bash call"
fi

# ---- format-dart ------------------------------------------------------------
# The hazard: `dart format` keeps trailing commas only because
# `formatter: trailing_commas: preserve` reaches it through
# analysis_options.yaml's `include: package:very_good_analysis/...`, and a
# `package:` include resolves only through a .dart_tool/package_config.json.
# Where that resolution fails the formatter still exits 0 while collapsing
# every trailing comma in the file.
# Sort by version, not lexically: `ls | tail -1` picks 9.0.0 over 10.3.0.
VGA=$(ls -d "$HOME"/.pub-cache/hosted/pub.dev/very_good_analysis-* 2>/dev/null | sort -t- -k2 -V | tail -1)
if [ -z "$VGA" ]; then
  echo "SKIP: very_good_analysis not in the pub cache; format-dart tests need it"
else
F=$(mktemp -d)
SPLIT='void f(\n  int a,\n  int b,\n) {}\n'   # trailing commas: must survive
UGLY='void   g(int a){return;}\n'              # must be fixed when resolvable

mkpkg() { # mkpkg <dir> <resolved|unresolved|broken>
  mkdir -p "$1/lib" "$1/.dart_tool"
  printf 'name: fixture\nenvironment:\n  sdk: ^3.11.0\n' > "$1/pubspec.yaml"
  printf 'include:\n  - package:very_good_analysis/analysis_options.yaml\n' \
    > "$1/analysis_options.yaml"
  case "$2" in
    resolved) printf '{"configVersion":2,"packages":[{"name":"fixture","rootUri":"../","packageUri":"lib/","languageVersion":"3.11"},{"name":"very_good_analysis","rootUri":"file://%s","packageUri":"lib/","languageVersion":"3.9"}]}\n' "$VGA" > "$1/.dart_tool/package_config.json" ;;
    broken) printf '{"configVersion":2,' > "$1/.dart_tool/package_config.json" ;;
    unresolved) rm -rf "$1/.dart_tool" ;;
  esac
}

fmt() { printf '%s' "$1" | jq -Rs '{tool_input:{file_path:.}}' | bash "$FORMAT" >/dev/null 2>&1; }

expect() { # expect <file> <expected-content> <label>
  local want; want=$(printf "$2")
  if [ "$(cat "$3")" = "$want" ]; then ok; else
    bad "format-dart: $4"$'\n'"      want: $(printf "$2" | tr '\n' '~')"$'\n'"      got:  $(tr '\n' '~' < "$3")"
  fi
}

# 1. Resolved: trailing commas survive.
mkpkg "$F/ok" resolved
printf "$SPLIT" > "$F/ok/lib/a.dart"; fmt "$F/ok/lib/a.dart"
expect x "$SPLIT" "$F/ok/lib/a.dart" "collapsed trailing commas in a RESOLVED package"

# 2. Resolved: badly formatted code is actually fixed. Without this the suite
#    cannot tell "correctly skipped" from "hook is a total no-op".
printf "$UGLY" > "$F/ok/lib/b.dart"; fmt "$F/ok/lib/b.dart"
expect x 'void g(int a) {\n  return;\n}\n' "$F/ok/lib/b.dart" "did NOT format a file it could resolve"

# 3. A sub-package with no .dart_tool of its own, under a root that has one.
#    Every packages/* in this repo looks like this, and the formatter resolves
#    them through the root -- a guard that stops at the nearest pubspec.yaml
#    silently skips all of them, ffigen bindings included.
mkpkg "$F/mono" resolved
mkdir -p "$F/mono/packages/sub/lib"
printf 'name: sub\nenvironment:\n  sdk: ^3.11.0\n' > "$F/mono/packages/sub/pubspec.yaml"
printf "$UGLY" > "$F/mono/packages/sub/lib/c.dart"; fmt "$F/mono/packages/sub/lib/c.dart"
expect x 'void g(int a) {\n  return;\n}\n' "$F/mono/packages/sub/lib/c.dart" "skipped a sub-package file the root config resolves"
printf "$SPLIT" > "$F/mono/packages/sub/lib/d.dart"; fmt "$F/mono/packages/sub/lib/d.dart"
expect x "$SPLIT" "$F/mono/packages/sub/lib/d.dart" "collapsed trailing commas in a sub-package"

# 4. Unresolved: must not touch. This is the ~200-file collapse.
mkpkg "$F/un" unresolved
printf "$SPLIT" > "$F/un/lib/a.dart"; fmt "$F/un/lib/a.dart"
expect x "$SPLIT" "$F/un/lib/a.dart" "reformatted a file in an UNRESOLVED package"

# 5. Broken config -- what an interrupted `pub get` leaves behind.
mkpkg "$F/br" broken
printf "$SPLIT" > "$F/br/lib/a.dart"; fmt "$F/br/lib/a.dart"
expect x "$SPLIT" "$F/br/lib/a.dart" "reformatted against a TRUNCATED package_config.json"

# 6. A syntax error makes dart format exit non-zero with empty output; writing
#    that back would truncate the file.
printf 'void broken( {\n' > "$F/ok/lib/e.dart"; fmt "$F/ok/lib/e.dart"
expect x 'void broken( {\n' "$F/ok/lib/e.dart" "damaged a file that does not parse"

# 7. Non-Dart files and missing paths are no-ops, not errors.
# VALID, badly-formatted Dart in a .txt: unparseable content would be rejected
# by the stderr guard instead and the suffix filter would go untested.
printf 'void   g(int a){return;}\n' > "$F/ok/lib/a.txt"; fmt "$F/ok/lib/a.txt"
expect x 'void   g(int a){return;}\n' "$F/ok/lib/a.txt" "touched a non-Dart file"
fmt "$F/ok/lib/gone.dart"
[ $? -eq 0 ] && ok || bad "format-dart: non-zero exit on a missing file"

# 8. A read-only file is left alone silently. A hook has nowhere useful to put
#    "Permission denied", and a raw shell error on every edit is worse noise
#    than the silence.
printf 'void   g(int a){return;}\n' > "$F/ok/lib/ro.dart"; chmod 444 "$F/ok/lib/ro.dart"
RO_ERR=$(printf '%s' "$F/ok/lib/ro.dart" | jq -Rs '{tool_input:{file_path:.}}' | bash "$FORMAT" 2>&1)
if [ -z "$RO_ERR" ]; then ok; else
  bad "format-dart: leaked an error on a read-only file: $RO_ERR"
fi
chmod 644 "$F/ok/lib/ro.dart"

rm -rf "$F"
fi

# ---- report -----------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "ALL PASSED"
