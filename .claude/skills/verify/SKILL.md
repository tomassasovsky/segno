---
name: verify
description: Run the repo's verify loop, selecting the gates the current diff actually needs. Use before declaring any change done, and before opening a PR.
disable-model-invocation: true
---

# verify

Runs the gates from `CLAUDE.md`, picking the applicable subset from what the
diff touches, and prints one PASS / FAIL / SKIP / UNRUN line per gate.

```
bash .claude/skills/verify/run.sh [base-ref]     # default base: origin/master
```

## Gates and when each one fires

Every gate is conditional. "Dart moved" below means any `.dart` / `.arb` /
`pubspec.yaml` / `pubspec.lock` / `assets/` change **at any depth** — a bump to
`packages/<pkg>/pubspec.yaml` counts, and CI puts no path filter on those jobs.

| Gate | Fires when |
|---|---|
| `dart analyze` | Dart moved |
| `dart format --set-exit-if-changed` | Dart moved — over the same `lib test packages/*/lib packages/*/test` CI gates |
| `bloc lint lib test packages` | Dart moved, and the `bloc` CLI is installed |
| `flutter test (root app)` | Dart moved |
| `test (<package>)`, six of them | that package changed, or the Dart surface of `segno_engine` / `wav_codec` did |
| native engine tests | `packages/segno_engine/src/**` changed |
| ffigen bindings in step | `segno_engine_api.h` changed |
| firmware contract + drift gate | `firmware/**`, `hardware/firmware/**`, or `pedal_protocol.*` changed |
| appliance bundle suites (9 + a dash pass) | `deploy/yocto/.../segno-bundle/**` changed |
| agent hook tests | `.claude/hooks/**` changed |
| agent script syntax | `.claude/hooks/**` or `.claude/skills/**` changed |

## Things the script encodes so you do not have to remember them

- **Bare `flutter` / `dart` are hook-blocked.** It calls the SDK by absolute
  path. Override with `SEGNO_FLUTTER_BIN` if your SDK lives elsewhere.
- **An unresolved checkout reports UNRUN and ends the run at exit 3.** Without
  `.dart_tool/package_config.json`, `dart analyze` invents tens of thousands of
  phantom errors and `dart format` rewrites the entire repo, so the script
  refuses to run them — but refusing is not passing, and an earlier version
  that reported "all applicable gates passed" here was the worst bug this
  script has had. Run `pub get` and re-run.
- **`bloc lint` carries rules `dart analyze` does not** — a cubit method
  returning anything but void fails here and passes there. It runs as its own
  gate, and a run that says it checked nothing reports UNRUN rather than a
  false green. Note that exit 64 alone is not that signal: 64 is `EX_USAGE`, so
  a genuinely broken invocation returns it too and is reported as a failure.
- **A root `flutter test` runs the root app's `test/` only.** It does not
  descend into `packages/*`. CI gives six packages their own job — `daw_export`
  and the five `*_repository` packages — so until they had gates here, a change
  confined to one of them passed verify and failed CI. Each now runs when its
  own package moves. Their coverage floors stay CI's job; this answers "do the
  tests pass", not "is the floor still met".
- **A sub-package that has never had `pub get` reports UNRUN, not PASS.** A root
  `pub get` does not resolve `packages/*`. The script will not run `pub get`
  for you — that rewrites a tracked `pubspec.lock`, and a verify run must not
  dirty the tree.
- **ffigen output must be formatted after regeneration**, or a small API change
  becomes whole-file churn. The gate says so when it fires.
- **The pedal protocol is hand-copied into two directories.** The firmware gate
  diffs both copies and compares the sketches' colour-mapping signatures.

## Reading the result

| Exit | Meaning |
|---|---|
| 0 | every gate that applied ran and passed |
| 1 | a gate failed — the tail of each failing log is printed, full logs in a temp dir |
| 2 | the base ref does not exist |
| 3 | **UNVERIFIED** — a gate applied but could not run |

`SKIP` and `UNRUN` are different answers and the script keeps them apart, because
collapsing them is how a verify run reports success having verified nothing:

- **SKIP** — the gate does not apply to this diff. A wall of these is a real
  answer; it means the change did not touch those subsystems.
- **UNRUN** — the gate applies, but a fixable local condition stopped it: no
  `pub get`, no `bloc` CLI. That is not a pass. The run ends 3 and says so.

## What a green run still does not prove

- CI runs the native suite four more ways — ASan, TSan, telemetry-off, and a
  fuzz job. This runs the plain one only. For an engine change, green here is
  necessary and not sufficient.
- CI also compiles the app and engine for Windows, Linux and Linux/arm64, and
  builds the VST3 plugins on Linux. None of that runs here.
- Coverage floors are CI's (root 90, and a per-package floor on each of the six).
  Nothing here measures coverage.
- Screenshot goldens are author-machine-only and rot silently. After any UI
  redesign, regenerate and eyeball them separately.

## Why the format gate matters more than it looks

The `dart format` PostToolUse hook only sees `Edit` and `Write`. Edits made by
shell (`sed`, `python3`, a heredoc) never reach it and land unformatted. The
`dart format --set-exit-if-changed` gate here is what actually catches those, so
a session that edited Dart through the shell and skipped `/verify` will fail CI
on formatting alone.
