# PR Readiness Review

No unresolved Critical, Important or Suggestion findings remain for the reviewed local prototype revision. This is readiness for local design review, not a ready-to-merge or production-release decision.

## Scope and independence

Reviewed the host, Library and CSS delta against the supplied `segno-connection-repair-before` snapshot, plus the new normal-host browser verification and approved connection-repair plan. The final Library simplification uses the repair result's affected labels instead of reading options twice. The exact-action foot contact and pending token/revision changes are included.

The repair model and its focused Node tests were authored by this reviewer and are excluded from independent review. The older media-recovery model was also authored by this reviewer; executing its regression tests here does not independently approve that implementation. Independent model/test review belongs to another reviewer. No source, Pen, commit or publishing change was made during this review.

The project uses Flutter/Bloc and a native engine in production. This slice consists of standalone JavaScript, HTML and CSS under `docs/design`, with Node/VM and Playwright verification. No Dart/native implementation, dependency manifest or generated binding changed within this scope.

## Formatting

Status: clean for applicable checks. Added-line whitespace checks passed for the host, Library JavaScript/CSS and new browser suite using `git diff --no-index --check` against the supplied baseline, or `/dev/null` for the new suite.

No JavaScript/HTML/CSS formatter or linter configuration applies to these design studies. The existing study formatting is retained; running Dart formatting on these files is not applicable. No arbitrary new formatting convention or dependency was introduced for this review.

## Static analysis

No syntax errors found. The final Library and browser verification compile through Node's `vm.Script`; the host's inline script was extracted and compiled separately. Browser verification exercises the external-script load path, rendered CSS and action handlers without page errors.

These are bounded syntax/runtime checks, not a claim that Dart analysis, Bloc lint, a JavaScript linter, native sanitizers or project CI ran for this design-only change.

## Debug artifacts

No added merge-conflict markers, TODO/FIXME/HACK markers, debugger statements, exclusive/skipped tests, ad-hoc production logs or credentials were found in the reviewed additions. The browser runner's success output and caught-error output are intentional test reporting. Simulated controller/disconnection/storage-failure fixtures and `review` routes are explicitly scoped design utilities; they are not production behavior or unfinished debug code.

## Browser and regression evidence

All commands ran locally with the bundled Node runtime, Playwright provided through `NODE_PATH`, and Chrome selected through `ATLAS_CHROME`.

```sh
node docs/design/verify_session_connection_repair_browser.cjs
node docs/design/verify_session_field_ownership_browser.cjs
node docs/design/verify_session_recovery.cjs
node --test docs/design/verify_session_field_ownership.cjs docs/design/media-parity-study.test.cjs docs/design/session-recovery-model.test.cjs docs/design/session-recovery-study.test.cjs
```

- **New connection repair: Chrome and Firefox pass independently on the final host/Library/browser revision.** The suite covers staged CTRL/MIDI replacement, disabled and collision choices, original/live state preservation, disconnection and failed-storage retry, successful publication and reload, media repair followed by connection repair, touch and full encoder flow, foot selection/Back/Cancel/Reset/Apply, and BANK wrap.
- **Stale foot contacts:** a held USB choice does not become DIN when USB disconnects. Cancel/reopen, Back, Back then reentering the same picker, and Reset while Apply is held retire the earlier action. The assertions check the pending dialog and live/stored state, not just displayed labels.
- **Existing ownership browser: Chrome and Firefox pass.** Musical/current-physical split, candidate FX target identity, dependency Retry/Cancel with touch/encoder/STOP/MODE, media repair, storage failure/retry/reload, released held state and offline New Loop remain covered.
- **Existing media recovery browser: Chrome and Firefox pass.** Pending repair, exact imported duration, Cancel, save failure/retry/reload, device setup/return, encoder and bounds remain covered.
- **Existing ownership/media/recovery Node suite: 53/53 pass.** This was rerun after the final Library simplification.

Browser verification used the normal storage-enabled URL for behavior. Only screenshot output directories were redirected into temporary review directories in memory, retaining every browser assertion and image capture. This avoided rewriting the suite author's repository evidence. The final new-suite run used browser hash `1bb5c330ac09bfc3b9b7c8319192157b05b19c9eb5bf3b949e03707b12b3a8dd`; earlier executions are not substituted for this result.

The older browser regressions passed during this review; the subsequent token/revision guard and affected-label simplification were exercised by the expanded final connection suite. Screenshots and bounds assertions are prototype evidence, not automated visual-baseline CI or physical-device validation.

## Commit hygiene and remaining gates

This is an authorized uncommitted local prototype slice. Its reviewed source files are untracked within a broader working tree. No commits were created or reviewed for this slice, and unrelated existing history was excluded. Standard build, cache and log artifacts are covered by the repository's ignore rules; deliberate design reference images are not mistaken for accidental build outputs.

No PR head, PR metadata, GitHub CI or merge gate was evaluated. Pen reconciliation is owned by the coordinating task. Native audio, physical controller discovery/calibration, appliance storage guarantees and the open downstream-tail decision remain outside this report. There are no outstanding auto-fixable items in the reviewed scope.

## Final reviewed hashes

| File | SHA-256 |
| --- | --- |
| `docs/design/fx-ux-prototype.html` | `c745de666af7687569f823d95bf92949f7a8b02b9792f5625651a946297af3b8` |
| `docs/design/session-library-study.js` | `4af02ea38e908b1f44575d8452b8ebe820ad1ad4bdd628f1f23e9456518873e9` |
| `docs/design/session-library-study.css` | `425905c502838a59d29eae8b24bedebcd21c7a18d547ea4ce2a18b8644438446` |
| `docs/design/verify_session_connection_repair_browser.cjs` | `1bb5c330ac09bfc3b9b7c8319192157b05b19c9eb5bf3b949e03707b12b3a8dd` |
| `docs/plan/2026-09-08-session-connection-repair-plan.md` | `8c85b3f48d42cf746cff4887adc12bf4b9a93f5c57d6fc97a0b0269d0143fa2c` |

## Regression evidence hashes

| File | SHA-256 |
| --- | --- |
| `docs/design/verify_session_field_ownership_browser.cjs` | `d0974567e41e905da7b8eaed7b3ecea099f05eaae0ac454224348f72c326d132` |
| `docs/design/verify_session_recovery.cjs` | `b6264f000fc19c3cc8d39bcf835088a244e6722b9ff40cb5ab50a3366378dfd5` |
| `docs/design/verify_session_field_ownership.cjs` | `74705dbd128afd4c2d59d30e40a56fcb87b6f2060aa3df03fdc1d9084ac972b4` |
| `docs/design/media-parity-study.test.cjs` | `9698374d0b22375c12c464c3b8b5acd34f43b84c5b6a6c1d1d6371efc35f2cd2` |
| `docs/design/session-recovery-model.test.cjs` | `7b42b59c507225143f4b5a0dfb4f69a7a13337bd13bfdca7e85a0af1d94d4153` |
| `docs/design/session-recovery-study.test.cjs` | `59461775911185d19ad36ddb4ce120187de1c4690ec308e9c0ac54d68560d1ea` |
