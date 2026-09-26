# PR Readiness Review

Review date: September 8, 2026. No unresolved Critical, Important or Suggestion findings remain for the reviewed local prototype revision. This report concerns local prototype readiness, not a production release or ready-to-merge decision.

## Scope and independence

Reviewed the root-authored host and Library JavaScript/CSS changes against the supplied `segno-session-target-before` filesystem baseline, Carson's new target-repair browser verification, and the approved target-repair plan. Scope also includes the root's bounded correction to the existing ownership browser assertion: display the friendly saved label while retaining an exact missing-key assertion and a visible Replace action.

This reviewer authored `session-target-repair.js` and `verify_session_target_repair.cjs`; those files are excluded from independent review. The older pure connection/media-recovery models were also authored by this reviewer. Executing them through regression tests does not independently approve their implementation. Other reviewers own independent model and test-quality review. No source, Pen, commit or publishing change was made by this reviewer.

The production repository uses Flutter/Bloc and a native engine. This slice contains standalone JavaScript, HTML and CSS under `docs/design`, exercised through Node/VM and Playwright. No Dart/native implementation, dependency manifest or generated binding changed in this scope.

## Formatting

Status: clean for applicable checks. `git diff --no-index --check` passed for the host and Library JavaScript/CSS against the supplied baseline, and for the new browser suite and corrected ownership browser file against `/dev/null`.

There is no JavaScript/HTML/CSS formatter or linter configuration for these design studies. The existing study formatting is retained. Dart formatting and the production analyzer configuration do not apply to these files; no new formatter dependency was introduced during review.

## Static analysis

Errors: 0. Warnings: 0 from the applicable bounded checks. Library JavaScript and the browser runner compile with Node's `vm.Script`. The host's inline script was extracted and compiled separately. Successful browser journeys check normal external-script loading and collect page errors.

This is syntax and runtime evidence, not a claim that a JavaScript linter, Dart analysis, Bloc lint, native sanitizers, coverage gates or GitHub CI ran for this design slice.

## Debug artifacts

Artifacts requiring removal: 0. Reviewed additions contain no conflict markers, TODO/FIXME/HACK markers, debugger statements, temporary exclusive/skipped tests, ad-hoc production logs or credentials. The browser suite's success and caught-error output is intentional test reporting. The storage-failure fixtures and named review routes are explicitly scoped prototype utilities.

## Behavioral verification

The following commands ran locally with the bundled Node runtime, Playwright supplied through `NODE_PATH`, and Chrome selected through `ATLAS_CHROME`:

```sh
node docs/design/verify_session_target_repair_browser.cjs
node docs/design/verify_session_connection_repair_browser.cjs
node docs/design/verify_session_field_ownership_browser.cjs
node docs/design/verify_session_recovery.cjs
node --test docs/design/verify_session_field_ownership.cjs docs/design/session-recovery-model.test.cjs docs/design/session-recovery-study.test.cjs docs/design/media-parity-study.test.cjs
```

- **New target repair: Chrome and Firefox pass.** Removed processors and removed parameters use the incoming snapshot's exact targets. Typed expression, external-button and MIDI values are reviewed across pages and published only after Use control followed by Apply and open. Same-source collisions are disabled. Cancel/Reset, a real storage-writer failure, retry/reload, current hardware preservation, media/CTRL/target composition, full encoder and foot flows, and retired held contacts all pass.
- **Existing connection repair: Chrome and Firefox pass.** CTRL/MIDI replacement, disabled/collision choices, disconnect and failed-save retry, touch/encoder/foot controls, media composition and reload remain green on the reviewed host and Library.
- **Existing ownership browser: Chrome and Firefox pass on the corrected final test.** The initial run exposed an obsolete raw-ID display assertion. The coordinator replaced it with checks for the friendly saved label, the exact missing key in `dialog.issues` using `kind`, and a visible Replace action. The complete rerun also passes musical/current-physical ownership, touch/encoder/STOP/MODE dependency handling, candidate target identity, media repair, failed publication, reload, held release and offline New Loop.
- **Existing media recovery browser: Chrome and Firefox pass.** Pending repair, exact imported duration, Cancel, failed-save retry/reload, device setup/return, encoder and bounds remain green.
- **Existing ownership/media/recovery Node regressions: 53/53 pass**, with no skipped or cancelled tests.

All browser suites used their normal storage-enabled URL for behavior. The only in-memory runner change replaced each screenshot output directory with a dedicated temporary review directory; all assertions and image captures remained enabled. This preserved the authors' repository screenshots. The new target suite captured five screens per browser and passed dialog/button bounds checks. The Chrome control picker and Firefox endpoint-review captures were also visually inspected; no clipping was observed in those views. Host, Library, CSS and new browser-suite hashes remained unchanged across these checks and the final reconciliation.

## Commit hygiene

Commits reviewed for this slice: 0. This is an authorized uncommitted local prototype; the scoped source files are untracked within a broader working tree. Unrelated history and dirty files were excluded. The repository ignores ordinary build, cache and log artifacts. Intentional design reference images are not mistaken for accidental build outputs.

No PR head, PR metadata, GitHub CI or merge gate was evaluated. Pen reconciliation is owned by the coordinator. Native DSP, physical appliance verification, missing-plugin installation and parameter-domain inference remain outside this report. Downstream-tail decisions remain open.

## Auto-fixable

None. The ownership assertion correction and its complete browser rerun are resolved.

## Reviewed source hashes

| File | SHA-256 |
| --- | --- |
| `docs/design/fx-ux-prototype.html` | `a98d6b45bcd8fe6fb94d0a7c0c07f88592437c0493505b06c1fbae69fabeec6d` |
| `docs/design/session-library-study.js` | `829c7062da23519fec9e0bd7cf51ea704b257e3367c87968bb3f2be5a71c5a43` |
| `docs/design/session-library-study.css` | `4b221b9e76499237d48fb3b39cde4f638f0388f7723c5bd90babab78a4eb58e6` |
| `docs/design/verify_session_target_repair_browser.cjs` | `0614158bb8908b923c43d42245346e8fe76b7a3d8a2072e333f8f09d1770041d` |
| `docs/design/verify_session_field_ownership_browser.cjs` | `d44b51cf922ddb5c6a959087cec3020f067ba9310d5c602b16241fd3096f3ece` |
| `docs/plan/2026-09-08-session-target-repair-plan.md` | `a02eb66c03aad7a805e6f20df5dba268da29744bd737dd79c19224ecff1fd674` |

## Regression hashes

| File | SHA-256 |
| --- | --- |
| `docs/design/verify_session_connection_repair_browser.cjs` | `1bb5c330ac09bfc3b9b7c8319192157b05b19c9eb5bf3b949e03707b12b3a8dd` |
| `docs/design/verify_session_recovery.cjs` | `b6264f000fc19c3cc8d39bcf835088a244e6722b9ff40cb5ab50a3366378dfd5` |
| `docs/design/verify_session_field_ownership.cjs` | `74705dbd128afd4c2d59d30e40a56fcb87b6f2060aa3df03fdc1d9084ac972b4` |
| `docs/design/session-recovery-model.test.cjs` | `7b42b59c507225143f4b5a0dfb4f69a7a13337bd13bfdca7e85a0af1d94d4153` |
| `docs/design/session-recovery-study.test.cjs` | `59461775911185d19ad36ddb4ce120187de1c4690ec308e9c0ac54d68560d1ea` |
| `docs/design/media-parity-study.test.cjs` | `9698374d0b22375c12c464c3b8b5acd34f43b84c5b6a6c1d1d6371efc35f2cd2` |

## Verdict

Ready for the bounded local prototype review, with no unresolved actionable findings. Production and merge readiness are outside the authorized review scope.
