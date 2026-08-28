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
| `flutter test` | any `.dart` / `.arb` / `pubspec` / `assets/` change |
| native engine tests | `packages/segno_engine/src/**` changed |
| ffigen bindings in step | `segno_engine_api.h` changed |
| firmware contract + drift gate | `firmware/**`, `hardware/firmware/**`, or `pedal_protocol.*` changed |

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
