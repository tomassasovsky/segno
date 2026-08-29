---
name: verify
description: Run the repo's verify loop, selecting the gates the current diff actually needs. Use before declaring any change done, and before opening a PR.
disable-model-invocation: true
---

# verify

Runs the gates from `CLAUDE.md`, picking the applicable subset from what the
diff touches, and prints one PASS / FAIL / SKIP line per gate.

```
bash .claude/skills/verify/run.sh [base-ref]     # default base: origin/master
```

## Gates and when each one fires

| Gate | Fires when |
|---|---|
| `dart analyze` | always (skipped if the checkout is unresolved) |
| `dart format --set-exit-if-changed` | always — CI gates it over `lib test packages/*/lib packages/*/test` |
| `bloc lint lib test packages` | always, if the `bloc` CLI is installed |
| `flutter test (root app)` | any `.dart` / `.arb` / `pubspec` / `assets/` change |
| `test (<package>)`, six of them | that package under `packages/` changed |
| native engine tests | `packages/segno_engine/src/**` changed |
| ffigen bindings in step | `segno_engine_api.h` changed |
| firmware contract + drift gate | `firmware/**`, `hardware/firmware/**`, or `pedal_protocol.*` changed |
| agent hook tests | `.claude/hooks/**` changed |

## Things the script encodes so you do not have to remember them

- **Bare `flutter` / `dart` are hook-blocked.** It calls the SDK by absolute
  path. Override with `SEGNO_FLUTTER_BIN` if your SDK lives elsewhere.
- **An unresolved checkout is skipped, not failed.** Without
  `.dart_tool/package_config.json`, `dart analyze` invents tens of thousands of
  phantom errors and `dart format` rewrites the entire repo. The script skips
  those gates and tells you to run `pub get` instead of reporting the noise.
- **`bloc lint` carries rules `dart analyze` does not** — a cubit method
  returning anything but void fails here and passes there. It runs as its own
  gate, and a zero-file run reports as SKIP rather than a false green.
- **A root `flutter test` runs the root app's `test/` only.** It does not
  descend into `packages/*`. CI gives six packages their own job — `daw_export`
  and the five `*_repository` packages — so until they had gates here, a change
  confined to one of them passed verify and failed CI. Each now runs when its
  own package moves. Their coverage floors stay CI's job; this answers "do the
  tests pass", not "is the floor still met".
- **A sub-package that has never had `pub get` reports SKIP, not PASS.** A root
  `pub get` does not resolve `packages/*`. The script will not run `pub get`
  for you — that rewrites a tracked `pubspec.lock`, and a verify run must not
  dirty the tree.
- **ffigen output must be formatted after regeneration**, or a small API change
  becomes whole-file churn. The gate says so when it fires.
- **The pedal protocol is hand-copied into two directories.** The firmware gate
  diffs both copies and compares the sketches' colour-mapping signatures.

## Reading the result

Exit 0 means every gate that applied passed. Exit 1 prints the tail of each
failing gate's log, then re-prints the summary, with full logs in a temp dir.

A wall of SKIPs is a real answer — it means the diff did not touch those
subsystems. But a SKIP for an unresolved checkout means that gate is
**unverified**: run `pub get` and re-run before calling the change done.

`flutter test` here does not cover the screenshot goldens, which are
author-machine-only and rot silently. After any UI redesign, regenerate and
eyeball those separately.

## Why the format gate matters more than it looks

The `dart format` PostToolUse hook only sees `Edit` and `Write`. Edits made by
shell (`sed`, `python3`, a heredoc) never reach it and land unformatted. The
`dart format --set-exit-if-changed` gate here is what actually catches those, so
a session that edited Dart through the shell and skipped `/verify` will fail CI
on formatting alone.
