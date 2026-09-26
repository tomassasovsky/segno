# VGV Code Review

September 8, 2026. No unresolved actionable findings in the bounded final
revision identified below. This is an independent review of the new simulated
session recovery slice, including re-review of the coordinator's corrections.
It is not a production merge gate or verification of native audio or storage.

## Scope and method

Read AGENTS.md, the progress build notes, tracking contract, dependency
manifest and analyzer configuration. Applied the workflow-agents VGV role
and build review-agent instructions. The repository uses Flutter/Dart, while
this slice uses native JavaScript, HTML and CSS with Node and Playwright.
Dart widget, Bloc, generated-model and package-specific rules do not apply to
these isolated studies. No dependency or lint configuration changes belong to
this slice.

Reviewed the complete new recovery model, study, CSS and focused tests. The
coordinator did not retain exact pre-recovery copies of the existing files.
For session-library-study.js and the host, review was therefore bounded to the
recovery entry, guarded transition, draft lifecycle, files/device callbacks,
script loading and scroll routing identified in the task, with neighboring
callers inspected. For media-parity-study.test.cjs, reviewed the added module
loading, context fixtures and recovery regression cases; the existing suite
was also run to check transaction behavior. Unrelated edits in the large dirty
working tree and the earlier audit-closure work were excluded.

## Critical — must fix

None remaining.

## Important — should fix

None remaining.

## Suggestions

None remaining.

## Resolved observations

1. **Discard abandoned recovery on ordinary navigation.** The initial Chrome
   reproduction opened a ready recovery draft, went to Stage and reopened
   Library. The pending Evening set intercepted the Library visit instead of
   returning to the normal session list. The coordinator added discard(),
   forwards the navigation destination to leave(next), and preserves the
   draft only for the explicit Audio setup excursion. Stage, Library, New
   Loop and reveal clear it. Independent recheck now shows Library, a normal
   load control, no recovery draft and the unchanged current session.
2. **Reject malformed audio-reference containers and candidates consistently.**
   A saved prepared field containing an object rendered in Library but threw
   an unhandled iterable error on Open. The model now exposes validation and
   the session owner guards both request and final transition, showing a
   controlled error while preserving the current loop. Re-review also caught
   readable() accepting a descriptor without a name that valid() rejected
   after repair. readable() now reuses descriptor validation; the independent
   probe returns no candidate and refuses that repair. Tests cover malformed
   containers and candidates.
3. **Route Find audio to the current unresolved identity.** After a chosen
   replacement became unreadable, the rendered button originally carried the
   old missing ID while inspection reported the replacement ID. The emitted
   action could not open the picker. It now uses problem.id, and re-repair
   updates affected rows. The regression exercises the rendered action,
   selects a second recording and opens the repaired draft successfully.
4. **Style the new chooser edge explicitly.** Browser inspection found the
   native 2px outset border and square corners. The coordinator specified a
   2px solid border and 8px radius. Independent Chrome and Firefox checks
   confirm those values and the existing 90px hit height.

The last test rerun also caught an outdated expected label after the
coordinator replaced an internal ID with “Missing backing audio.” The expected
product label was corrected; no assertion was removed or weakened.

## Architecture and lifecycle assessment

The pure model owns reference validation, deduplication, compatibility and
immutable repair results. The study owns pending selection and presentation;
the session owner retains saved-source checks and atomic publication through
the existing host commit. The model has no UI or persistence dependency.
Choosing a replacement does not mutate the saved session or current loop.

The final Open rechecks selected descriptors, current file availability,
audio readiness, the saved source and capture/transfer guards. Failed commit
retains the repair draft. Cancel and navigation exits discard it. The existing
Audio setup return intentionally preserves it. No new timer, subscription,
background job or compatibility fallback needs disposal in this slice.

## Testing assessment

Independently observed:

- `node --test docs/design/session-recovery-model.test.cjs
  docs/design/session-recovery-study.test.cjs
  docs/design/media-parity-study.test.cjs`: **37 passed, 0 failed** on the final
  test revision. Cases assert immutable snapshots, shared references, timing
  preservation, stale/removed sources, changed candidates, malformed data,
  device readiness, failed publication, cancellation and ordinary sessions.
- `verify_session_recovery.cjs`: Chrome and Firefox passed pending repair,
  picker Back, Cancel, failed save and retry, persistence/reload, Audio setup
  return, Stage/Library exit and full encoder completion. This independent
  rerun included the final behavioral fixes; later changes were only the
  chooser border, fallback display label and corresponding test expectation.
- Separate Chrome and Firefox probes passed ordinary stopped session load,
  playback confirmation, Cancel and confirmed load without entering recovery.
- Independent Chrome reproductions verified both reported failures and their
  corrections. Node probes checked current action identity and candidate
  validation. Final browser geometry checks kept the chooser inside the
  1920 × 1080 screen and confirmed a scrollable list with nine candidates.
- Visually inspected the recovery, chooser, ready, disconnected-device and
  save-error screenshots. Final border values were checked in both browsers.

These are meaningful state and interaction tests for a silent prototype.
They do not establish native file validity, audio processing, hardware input,
filesystem durability, appliance behavior, Pen contents or complete audit
coverage. The reviewer did not edit implementation files.

## Checked SHA-256 revisions

Paths are relative to `docs/design/`. Existing-file hashes identify the checked
version, not a retrospective review of unrelated contents.

| File | SHA-256 |
| --- | --- |
| session-recovery-model.js | 4412f284920b64055593335192df5f9b4cdb01ef1d1d1a8b1aa5f9eaa8097cc4 |
| session-recovery-study.js | 35381a51085faf131c3d9382b4f24b7b81d62f4aa97096c674730f5788bdcb93 |
| session-recovery-study.css | c0c7bb29062f346254eb8f4b9f261b8b41906b8e30d9cbb666debad780ac07bf |
| session-library-study.js | 90834527f21568c17a3949796e3b45051feec67abb1f4cdabcad00bf1e51fffb |
| fx-ux-prototype.html | 4cb77e7aa11ed4b2de0f3f18ef96428b0d1581654002a2ff109c565f6b1c667d |
| verify_session_recovery.cjs | b6264f000fc19c3cc8d39bcf835088a244e6722b9ff40cb5ab50a3366378dfd5 |
| session-recovery-model.test.cjs | 7b42b59c507225143f4b5a0dfb4f69a7a13337bd13bfdca7e85a0af1d94d4153 |
| session-recovery-study.test.cjs | 59461775911185d19ad36ddb4ce120187de1c4690ec308e9c0ac54d68560d1ea |
| media-parity-study.test.cjs | fb72e88c26e22bde1def41dbd59cac62d0ae146be351e52b9d9e3e3b2beb2be8 |

Later source edits invalidate the matching part of this evidence.
