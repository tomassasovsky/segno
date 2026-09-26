# VGV Code Review

## Summary

No unresolved actionable findings in the checked prototype scope. The three verified correctness gaps below were corrected by their authors and independently rechecked. This result covers the proposed design behavior; it does not establish production/native readiness or whole-audit completion.

## Scope and independence

September 8, 2026. Independent review of the nonauthored recording, audio-port and appliance-backup portion of the approved recovery expansion. The review follows the workflow-agents VGV and test-quality role definitions and the build review-agent instructions. This is plain JavaScript in the existing silent browser prototype, with Node test/strict assertions, VM controller harnesses and Playwright browser journeys. Dart/Flutter conventions, native audio callbacks and firmware are outside this change.

The new recorded-audio, multipart, port-repair, backup-envelope and storage-transaction modules were reviewed in full. Existing files were bounded to their new dependency traversal, multipart playback/export, audio-port dependency UI, capacity accounting and backup host/publication seams. Main-host review covers capture/prepare/restore stores, exact port validation before target construction, recorded asset publication, recording capacity and restart hooks. The coordinator's recovery-expansion-before copies establish those seams; the unrelated working tree was excluded.

The reviewer authored primary/audition modules, their tests, Stage primary markers and the input-grouping host integration/browser test. Those changes are excluded from both independent verdicts. The port model itself was authored by the other agent and is included. No reviewed implementation was edited by this reviewer; verified issues were sent to their owners for correction.

## Critical — must fix

None unresolved.

## Important — should fix

None unresolved.

## Suggestions

None required for this bounded pass.

### Resolved findings verified on the checked revision

- **Multipart backup validity:** a reversed multipart audio asset initially passed backup validation even while the existing performance manifest rejected it. Backup and ordinary recovery now reuse that validator, reject missing/reordered/unreadable parts and verify saved performance descriptors against the current asset. Complete multipart round-trip and invalid-package regressions pass.
- **Malformed audio-port containers:** invalid `stereoPairs` and route collection shapes initially threw in the port predicate. The predicate now refuses those shapes. A separate normal-host reproduction then found target construction throwing before that predicate; `sessionProjection` now preflights the manifest and `commitSession` refuses a missing candidate. The final browser case reaches a controlled dependency state without a commit or page error.
- **Imported audio repair/history coherence:** imported loop repair initially changed `trackImports` while retaining a missing `sourceFile` in layers. Recovery appeared ready but complete backup failed. The shared traversal now tracks live/removed layers and Undo/Redo imported descriptors. Explicit repair changes those references together, retaining timing, gain, regions and history; the original snapshot stays immutable. The original failing reproduction now has no dependencies and passes backup validation.

The archive host also rereads the actual store during review revalidation. The real post-review archive mutation test passes. Recording Discard releases allocated bytes only after successful publication; Cancel/failure keep the charge and successful Discard/reload keeps the released capacity.

## Conventions and architecture

Pure modules own identity, immutable candidates, frame/part allocation and archive validation. Controllers own pending selection/cancellation and inject publication through the host. The storage helper reports successful rollback separately from rollback failure; the UI does not falsely promise unchanged data in the latter case. Data modules do not access DOM, browser storage or devices. New functions and filenames describe their concrete responsibility, and the implementation follows the existing prototype module style. No Dart formatter/analyzer claim is made for this JavaScript-only slice.

## Simplicity assessment

The current implementation reuses the existing multipart manifest and session ownership projection. One traversal covers live and historical recorded/imported references, avoiding separate repair logic for each consumer. Fixture port identities remain explicitly separate from native enumeration claims. No speculative abstraction or compatibility layer warrants a finding. No independent line-removal recommendation.

## Verification

```sh
node --test --experimental-test-coverage \
  --test-coverage-include='docs/design/*model.js' \
  --test-coverage-include='docs/design/appliance-storage-transaction.js' \
  --test-coverage-include='docs/design/session-audio-port-repair.js' \
  docs/design/verify_recorded_audio_recovery.cjs \
  docs/design/verify_appliance_backup.cjs \
  docs/design/verify_appliance_storage_transaction.cjs \
  docs/design/verify_performance_recording_model.cjs \
  docs/design/verify_session_audio_port_repair.cjs \
  docs/design/session-recovery-model.test.cjs \
  docs/design/session-recovery-study.test.cjs \
  docs/design/media-parity-study.test.cjs
```

99 tests passed. The six reported model/transaction files reached 100% line and function coverage, with 88.58% combined branch coverage. Coverage is only supporting evidence; the failure paths and mutation checks are assessed separately in `test-quality.md`.

The reviewer independently ran each normal-storage journey in Chrome and Firefox:

- `verify_recorded_audio_recovery_browser.cjs`: exact original selection, pending cancellation, failed publication/retry/reload, internal copy, sparse Multi regions, encoder selection, device and USB loss.
- `verify_appliance_backup_browser.cjs`: review/cancel, Keep both/Replace, real archive-store mutation after review, disconnected media, a real middle-key `Storage.prototype.setItem` failure and rollback, retry/restart, exact complete-payload equality and reload.
- `verify_long_performance_recording_browser.cjs`: three ordered parts, cross-part preview/seek/prepared playback, export/import identity, missing/reordered parts, low/unknown capacity, durable checkpoint allocation, confirmed Discard release and reload.
- `verify_session_audio_port_repair_browser.cjs`: explicit port selection, pending cancellation, failed Apply/retry/reload, offline and held-contact race, stereo outputs, missing and malformed manifests with no page errors.

All passed. Browser tests use the real prototype command/storage seams on normal URLs for persistence. Review fixtures only provide screenshot checks. These are local author/reviewer browser checks, not CI, physical storage recovery, native audio, checksum or power-loss evidence.

## Final host-schema follow-up — September 9, 2026

Re-reviewed only the final backup-host schema guard, the study's `inspectArchive`
adapter and the added browser regression. The host now requires explicit arrays
for `settings.presetFiles` and `presets.saved`; it does not replace a missing saved
preset collection with an empty list. The read-only preparation path checks the
host settings shape before the UI advertises restore readiness. Final publication
rechecks the same host preparation after the existing archive/current-state guards.

The browser removes each collection independently and recomputes the generic
manifest summary. This proves the host schema guard is responsible for “Needs
repair” and disabled Review restore. It also removes each collection after opening
review and verifies unchanged stores and live state. The reviewer independently
reran the updated full browser journey in Chrome and Firefox and the 24 focused
backup/transaction Node tests; all passed. Both single-guard removal mutations
failed the new readiness assertion. No new actionable finding. Other reviewed
source, including the main host, is unchanged from the preceding revision.

## Checked source hashes

Whole-file hashes identify the reviewed revision; existing-file scope remains bounded as described above.

| File | SHA256 |
| --- | --- |
| `docs/design/recorded-audio-model.js` | `8c4d2d3834f4b9da22a1c6059fb3bb6be5693467fd71afef3ce2e53707b26bf3` |
| `docs/design/session-recovery-model.js` | `395f4687fd9185c569009011033125303def002f45baff25f978cc3637f7d774` |
| `docs/design/session-recovery-study.js` | `6072a01114227cd293d027e5e2d4c2aafafeb7ff2c604d28fc55aca26e7c64f9` |
| `docs/design/appliance-backup-model.js` | `d9af82178d2b7bebf529f838a822156db88c2e9ef2453c5944967a1deb27db0a` |
| `docs/design/appliance-backup-study.js` | `7ffa10d1c748aeb94869a60651023540e229c3b0ef21aea7ded979f03a8a7a07` |
| `docs/design/appliance-backup-study.css` | `d741b6f51ca1bb4ae81099626acc6dffddd5ff82458884c3a71fc65edd4f38e2` |
| `docs/design/appliance-backup-host.js` | `6a6b0ad103c48393a9bb42a0d49d37609f353e79eb64f9d608613930e6aa766e` |
| `docs/design/appliance-storage-transaction.js` | `9d89f4935df8628f6609a7c1522ad11f43bb9db426a99233cd7b854910f1d546` |
| `docs/design/performance-recording-model.js` | `403aa6e3a88455b7c35c1a5801d8325c9a598c9770684e78977e4ac472898600` |
| `docs/design/performance-recording-study.js` | `66335027c00b815c29f17538116f4d766ded91dd2c814c1367e2b6d0a6f2464e` |
| `docs/design/performance-recording-study.css` | `f4c6c9f29c1642afd218a16066928a3bbcabfdae64c88d6168a2c4538a33ed6c` |
| `docs/design/session-audio-port-repair.js` | `ccad704c9d5affa1c07da4d708d568de03204fe32c7aa581432a051fb7a01e07` |
| `docs/design/audio-library-study.js` | `544d12fa11f3857e6a4969ff23372d3d607a0563aad5ed0473f03111c7914a40` |
| `docs/design/session-library-study.js` | `25f556b5e278b3ff7980ac898dfd8067023310625064bdd1c32d8ff512c5be33` |
| `docs/design/session-library-study.css` | `dde7ba1f85516198558c5022960bd0adf6b4f5b2fe13715917338a69fc6c9c29` |
| `docs/design/storage-study.js` | `7a253aa4a4d135a1f2f7db03f4f65892442fd260667676885ee11cf347c1ae21` |
| `docs/design/fx-ux-prototype.html` | `c821a23af292aafd32d08e7e88fc9f60c732d6bcb037f6e9682525d0979d9bb4` |
