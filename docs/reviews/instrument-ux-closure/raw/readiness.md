# PR Readiness Review

Date: 2026-09-09. Scope: the instrument HTML prototype and shared-controller integration described by `docs/plan/2026-09-09-fix-instrument-ux-plan.md`.

Reviewed `instrument-catalogue.js`, `instrument-runtime.js`, `virtual-instruments.js`, `virtual-instruments.css`, the instrument host integration in `fx-ux-prototype.html`, and the instrument additions in `pedal-action-catalogue.js`, `mapping-action-dispatch.js`, `pedal-ux-study.js`, `pedal-performance-study.js`, `external-switch-study.js`, `expression-ux-study.js`, and `midi-controls-study.js`. Reviewed all eight `verify_instrument*.cjs` / `verify_virtual_instruments.cjs` scripts. Paths in this paragraph are under `docs/design/`.

The prototype files are untracked in a larger dirty checkout. Unrelated existing prototype work, Dart/native changes, CAD artifacts, and the author's concurrent Pen/documentation work were excluded. No implementation or formatting changes were made by this review.

## Formatting

- Status: clean for applicable mechanical checks.
- No JavaScript/HTML/CSS formatter or linter configuration/package manifest exists in this checkout. No unrelated formatter was imposed on the prototype.
- `git diff --check --no-index /dev/null <file>` passed for all 20 scoped files, including untracked files; this checks whitespace without mutating them.
- The repository CI formatting and analyzer commands target Dart source. No Dart code is in this review's scope.

## Static Analysis

- Errors: 0.
- Warnings: 0.
- Infos: 0 actionable findings.
- `node --check` passed for all 18 scoped JavaScript/CommonJS files. The revised virtual-instrument UI, MIDI controls module, and complete-journey script were checked again after the final numeric-editor changes.
- The host page's inline JavaScript parsed successfully through `vm.Script`.
- All 100 local script/stylesheet references in the host page resolve to existing files.
- The served instrument JavaScript was checked against the working file to confirm the local browser verification exercised this checkout.

## Verification

Passed independently:

- `node docs/design/verify_instrument_runtime.cjs`: 19 patches, independent ownership/routes/audio buses, splits/layers, sustain, remaps, expression, disconnect/reconnect, pending-start cancellation, audition persistence, and audio-start failure.
- `node docs/design/verify_instrument_shared_controls.cjs`: all 12 shared-controller contracts. Repeated successfully after the MIDI editor's held-action validation changes.
- `node docs/design/verify_instrument_complete_journeys.cjs`: Chrome and Firefox.
- `node docs/design/verify_virtual_instruments.cjs`: Chrome and Firefox.
- `node docs/design/verify_instrument_hardware_journeys.cjs`: Chrome and Firefox; simulated controls, not physical-device evidence.
- `node docs/design/verify_instrument_management.cjs`: Chrome and Firefox.
- `node docs/design/verify_instrument_note_mappings.cjs`: Chrome and Firefox.
- `node docs/design/verify_instrument_sustain.cjs`: Chrome and Firefox.

The browser suites ran with the available Playwright dependencies, installed Chrome, and the local design server. These are author-side browser checks; they are not CI or production Linux/audio/MIDI proof.

The implementation changed while the first suite pass was running. The author owns the final complete-suite rerun. Independent focused checks on the latest numeric-editor version additionally passed in both Chrome and Firefox: enter MIDI note 127, activate Add note once, save the mapping, verify `[48, 127]`; then edit the low MIDI boundary and activate Done once, verifying the dialog closes and the boundary persists. Neither browser reported a page error.

## Debug Artifacts

- Artifacts found: 0 actionable findings.
- No ad hoc console output, debugger statements, TODO/FIXME/HACK markers, merge-conflict markers, skipped/focused tests, hardcoded credentials, or private machine paths were found in the scoped implementation.
- Console output in the verification scripts reports pass/failure results and is intentional.
- Simulator controls and test hooks are intentional prototype features.

## Commit Hygiene

- Commits reviewed: 0; the current branch is `master`, and no PR/commit was requested for this local prototype task.
- Issues found: 0 in the assigned scope.
- The repository's existing ignore rules cover its Dart/native build outputs and common tooling caches. Existing unrelated untracked files were preserved.
- Screenshot assets are prototype verification/design evidence, not an accidental compiled bundle.

## Corrections Verified During Review

The author corrected a transient malformed note-entry selector. A subsequent focused journey exposed that numeric-field blur rerendered the dialog between pointerdown and click, dropping the first Add note action. Both browsers reproduced the latter failure before correction. The author changed numeric fields to update values without replacing the dialog, and the fresh one-click Add note and MIDI Done journeys now pass in both browsers. No unresolved finding remains from either issue.

## Remaining Integration Step

The author explicitly reserved the host asset cache-query refresh until the independent reviews finish. Existing paths are valid; content-hash query finalization is still owned by that implementation step and was not treated as a defect in work declared in progress. The final author-side check should compare the refreshed queries with the completed source files. Pen geometry and narrative updates are outside this mechanical review.

## Auto-Fixable

None.

## Verdict

Ready within the reviewed prototype scope: no unresolved mechanical findings. This report does not grant a repository merge gate or claim CI, physical-device, production audio, or final Pen validation.
