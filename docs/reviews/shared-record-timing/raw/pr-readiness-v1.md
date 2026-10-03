# PR readiness — shared Record timing, local candidate v1

Read-only mechanical review of the intended M3.15 working diff against `8749688c51912f808c3f36d4eb5bca665ede3ade`. There is no PR or child commit yet. This reviewer inspected tracked changes and new files, excluding the unrelated `packages/controller_repository/analysis_options.yaml` and five prior `docs/reviews/design-loop-settings-restack/raw/*` reports. The tracked intended source diff (`.github`, `lib`, `packages`, `test`, `segno-ui.pen`) had SHA-256 `4d6938e1dbd8c58b3c0a3f7777f796e79e33ee360b200a1937c304457ca8ceda` when reviewed. New-file hashes are included below. Later writer changes require a new check; this is not a published-head review or a CI result.

## Formatting and static checks

- `dart format --output=none --set-exit-if-changed` over all 103 changed/new Dart files: **0 changes**, exit 0. `git diff --check 8749688c` also found no whitespace errors.
- `flutter analyze lib test packages`: **no issues**, exit 0 on the inspected working tree. This supersedes the earlier two import-order infos in `analyze-all-v1.log`; the current imports are sorted.
- Existing `m315-timing-runtime/bloc-v2.log` reports 0 issues over 21 runtime files; it is scoped author evidence, not yet a fresh whole-diff Bloc pass. The final aggregate/coverage/Bloc gate must bind the final source revision after the native author's F1/F2 edits and root fixture work.

## Debug artifacts and test gates

No new production debug print, unfinished TODO/FIXME/HACK, commented-out implementation, hardcoded secret/private path, or conflict marker appeared in added source lines. The five added C `printf` calls report test names in `test_engine_core.c`; they are test harness output. No root/package test assertion was silently disabled. The conditional native Dart skips in `record_timing_snapshot_test.dart:97` and `record_timing_persistence_test.dart:51` are intentional for environments without a test engine: `.github/workflows/main.yaml:337–365` explicitly builds a library, verifies it exists, and runs the real Session file plus the full `segno_engine` package tests with `SEGNO_ENGINE_LIB` set. This is a source-route check only; remote CI has not run. Screenshot tests are author-only and font-gated, distinct from CI behavior assertions.

The new generated FFI bindings accompany the changed C API/`ffigen.yaml`; no extra generator output or dependency churn appears in the candidate. Two PNGs (about 416 KiB and 84 KiB) are intentional golden references for the two timing editors, not stray build artifacts. The saved `segno-ui.pen` belongs to the visual change; coordinator's separate saved/hash and native-render inspection evidence is referenced by the broader gate, not independently verified here. The public plan and current raw review docs contain no private absolute filesystem path or machine identifier. The plan links issue #1026 and identifies the human merge gate.

## Diff and commit hygiene

The intended source changes trace to `docs/plan/2026-10-03-shared-record-timing.md`: pure model, native vector/receipt and bindings, owner/repository/Settings/Control, App/Session/Loop settings composition, tests, generated files, and editor references. No obsolete generic timing API is carried forward in the reviewed diff; prior `setRecordTiming`/split setter uses are replaced by the confirmed vector path and adapted fakes. The unrelated controller package analyzer exclusion and five prior raw review files must stay out of explicit staging.

`HEAD` still equals the base and `git log 8749688c..HEAD` is empty. Thus commit-message quality, staged-path accuracy, PR body (`Closes #1026`), PR labels, remote CI and review of the eventual published head are **not yet assessable**. Those are pending publication gates, not source defects. The current source is uncommitted, and PR readiness cannot mean ready to merge yet. `autonomy:merge-gate` reserves the final merge decision for the human even after gates pass.

## Pending independent gates

At the time of review, the native author's F1/F2 test-strengthening, the adversary's 34-case matrix, root's full app aggregate v2, native app restart/interaction, final static/Bloc/coverage and issue/PR metadata were still in progress or not yet recorded for this exact candidate. The fixed CI route has not run remotely. This review does not certify those outcomes, the bug-focused code-review gate, physical hardware, or the final commit/PR head. Recheck any changed source and repeat the mechanical gates after the final freeze.

## Verdict

**No actionable PR-readiness source finding in this local read set.** Formatting, analyzer, whitespace, artifact hygiene and CI test-route inspection are clean. The branch is **not yet ready to publish/merge** because the named verification, commit, PR and head-bound review gates remain open. Stage intended paths explicitly, excluding unrelated files, after the writers freeze.

## New-file binding

| File | SHA-256 prefix |
| --- | --- |
| `docs/plan/2026-10-03-shared-record-timing.md` | `656db85268563a06` |
| `lib/looper/model/record_timing.dart` | `fe9c470d991190d6` |
| `packages/looper_repository/test/record_timing_receipt_test.dart` | `ab607d4d00a75865` |
| `packages/segno_engine/test/record_timing_snapshot_test.dart` | `922e50e569ebdc3d` |
| `packages/settings_repository/test/record_timing_checkpoint_test.dart` | `437f1037fcca9c95` |
| `test/control/record_timing_dispatch_test.dart` | `3073c75967c700bb` |
| `test/helpers/fake_record_timing_control.dart` | `76ca52af8c96af8a` |
| `test/screenshots/goldens/external_pedals_record_timing_held_released.png` | `784b3ca202e7a6cd` |
| `test/screenshots/goldens/midi_controls_record_timing_range.png` | `f0c3aa6d134f87a7` |
| `test/session/record_timing_persistence_test.dart` | `3137a009fecc387b` |
