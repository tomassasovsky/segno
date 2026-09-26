# Architecture review

Review date: 2026-09-08. Independent review of the new local JavaScript design
prototype only, against `/tmp/segno-recovery-expansion-before` where a baseline
exists. The repository's production stack is Flutter/Dart with native audio;
this bounded browser prototype uses pure models, study controllers and explicit
host callbacks. No Bloc rewrite, production/native certification, CI status,
commit, PR or merge claim is made.

Scope: root's complete-appliance backup host and browser-store transaction;
Carson's primary-track and temporary-preset-audition models/UI; their new host
integration, state persistence, input/lifecycle guards and display consumers.
The unchanged stage-transport implementation was traced as a dependency. The
reviewer's authored physical-port and multipart-recorder implementation is
excluded from independent review. Multipart use by the separately authored
appliance-backup validator is included as a cross-feature consumer contract.

Role definitions: `workflow-agents/references/architecture-review-agent.md` and
`code-simplicity-review-agent.md`; reporting contract:
`build/references/review-agent-instructions.md`. All paths below are relative to
`docs/design` unless stated otherwise.

## Layer separation

Violations found: 0. Pure primary selection and audition projection expose state
operations without a browser storage client. Their study controllers use host
callbacks. The appliance model validates archive content, the study owns review
and pending choices, the host builds each store's candidate, and the storage
transaction publishes/rolls back those candidates. These dependencies fit the
existing design-prototype architecture.

## State ownership and lifecycle

- Primary selection revalidates mode, captured timelines, pending actions and
  playing tracks before publication. A playing handoff preserves the candidate
  until explicit confirmation. Failed save restores the old primary and playing
  states; successful handoff resets the existing transport owner afterward.
- Preset audition captures the original rack scope once, previews compatible
  values while retaining exact module/parameter IDs, and projects that original
  scope out of ordinary persistence. Keep publishes the current trial values;
  Cancel/navigation/capture restore the original. Source identity, rack bypass
  and assignment rules remain in their established owner.
- Appliance backup captures the live musical session separately from global and
  physical settings. Restore reconstructs all declared stores before publishing;
  it does not partially replace the running rig as the files are validated.
  Current-state and USB-package freshness are rechecked at the final action.
- The browser storage transaction restores earlier keys after ordinary write
  failure and distinguishes failed rollback. It intentionally does not promise
  power-loss atomicity.
- Successful publication immediately latches `applianceRestarting`. Ordinary
  save, transaction callbacks, separate settings writers, transport/mapping and
  physical-input entry points cannot overwrite the restored data before reload.
  A failed publication does not enter this state.

## Resolved findings

1. The initial archive validator accepted reordered/missing performance parts
   because its generic audio predicate only checked outer metadata. It now
   consumes the shared multipart manifest and verifies referenced performance
   descriptors. The original normal-host reproduction and new focused cases
   confirm the defect and its resolution.
2. The initial host scheduled a restart after publishing but left the old rig's
   input/save paths enabled. With that timer deferred, a normal record/play
   command replaced a restored label with the old label. The synchronous
   restarting latch and the independent all-store input replay above resolve
   this publication-to-restart ownership gap.

No unresolved actionable findings remain in the reviewed scope.

## Dependency direction and package structure

Direction violations: 0. No new package/dependency was introduced. The new
modules stay within the established design sandbox and have focused executable
fixtures. Native audio-thread restrictions are not exercised by this JS pass.

## Verdict

Architecture is clean for the bounded local prototype revision below. Real
archive byte copying, native device identity, disk/crash safety and appliance
validation remain explicit production work.

### Verification

- Independently ran `node --test docs/design/verify_primary_track.cjs
  docs/design/verify_preset_audition.cjs docs/design/verify_appliance_backup.cjs
  docs/design/verify_appliance_storage_transaction.cjs`: 51 tests passed.
- Independently ran `verify_appliance_backup_browser.cjs` with screenshots
  disabled: Chrome and Firefox passed normal-storage create, cancel, collision,
  changed package, disconnect, middle-key rollback, retry/restart, exact restored
  payload and reload checks.
- Independently ran `verify_primary_audition_browser.cjs`: Chrome and Firefox
  passed primary handoff, failed-save rollback, first-recording ownership,
  touch/encoder audition, MIDI persistence isolation, Cancel/Keep, reload and
  capture cancellation.
- Independently reproduced the restore-to-restart race, then rechecked the fix
  in both browsers with only the restart timer deferred. After successful
  restore, actual transport/session dispatch, MIDI, external switches, foot
  contacts, encoder, Back and subsequent timer ticks left every localStorage
  entry byte-for-byte identical to the just-restored stores. The screen stayed
  Restarting. Normal failed-publication tests remain retryable.
- Normal-host inspection confirmed the prior multipart validator gap. The final
  model now uses the shared manifest validator and exact referenced performance
  metadata; dedicated complete, reversed, missing, unreadable and incomplete
  part cases pass in the 51-test run above.

Browser commands used the existing Playwright runtime, `ATLAS_CHROME`, and the
normal prototype server at `http://127.0.0.1:8768/fx-ux-prototype.html`.

### Final delta reconciliation — 2026-09-09

Scope of this final rereview is only `appliance-backup-host.js` and
`appliance-backup-study.js`, plus their focused validation evidence. The main
host remains at the previously reviewed `c821a23a…` revision; the successful
restore latch and its input replay findings are unchanged.

`prepare` now requires explicit arrays for both `presets.saved` and
`settings.presetFiles`, including an explicitly empty array. It no longer
silently restores a missing saved collection as empty. The study consumes the
host's `inspectArchive` predicate for archive availability and review entry,
so an incomplete package says Needs repair and disables Review restore.
Final publication still invokes `prepare`, and a package changed after review
is refused by the existing exact-source freshness check.

The host inspection adapter remains a read/candidate operation: it invokes the
existing validation/projection and pure store serializer, with no publication.
An independent frozen-input probe called preparation, capture and archive reads,
then modified the returned archive copy. The input payload, rig, current USB
list and archive catalogue were unchanged; publication count was zero. Missing
either collection was rejected before the store candidate builder was called.

Independent focused rerun: backup and storage transaction suites passed 24
Node tests. The settled backup browser suite (`8ae1eee1…`) passed Chrome and
Firefox, including both missing collections, Needs repair/disabled Review,
unchanged live state/stores, and collection removal after review. These tests
alter actual browser storage rather than replacing the host validator.

Architecture and simplicity verdicts remain unchanged: no unresolved actionable
findings in this bounded local prototype delta. Explicit required collections
and one shared host inspection seam avoid a compatibility fallback and keep the
UI's readiness indication aligned with the final adapter contract.

### Reviewed revision hashes

| File | SHA-256 |
|---|---|
| `fx-ux-prototype.html` | `c821a23af292aafd32d08e7e88fc9f60c732d6bcb037f6e9682525d0979d9bb4` |
| `appliance-backup-host.js` | `6a6b0ad103c48393a9bb42a0d49d37609f353e79eb64f9d608613930e6aa766e` |
| `appliance-backup-model.js` | `d9af82178d2b7bebf529f838a822156db88c2e9ef2453c5944967a1deb27db0a` |
| `appliance-backup-study.js` | `7ffa10d1c748aeb94869a60651023540e229c3b0ef21aea7ded979f03a8a7a07` |
| `appliance-storage-transaction.js` | `9d89f4935df8628f6609a7c1522ad11f43bb9db426a99233cd7b854910f1d546` |
| `primary-track-study.js` | `70b8ca703aaf12f62ad27ab5ec506d42c4d93b42b383970aa4de02e25acd7fb1` |
| `preset-audition-study.js` | `22e501294f90ca31a70ec5ac2ee60640185e869e06c593477506855cbde0615a` |
| `stage-transport-study.js` | `ad1022a28f7672385062d961610b75b6a118bb41ca6be48419216af3d99dd20d` |
| `stage-display-study.js` | `b2c7d968ec39ec562a8dd62f11b16fe939a8e957e7ad69e64d04b28804f6216d` |
| `stage-display-study.css` | `587d0f355ae205f0e1581ef8ed98d19cbfa34d9c43763df4c2cf2ac350c2c482` |
| `verify_appliance_backup_browser.cjs` | `8ae1eee1c96e71699e8cd965f69f5f6b9d5ac31be93b78074d8c6bd739caff48` |
| `verify_primary_audition_browser.cjs` | `a1fd01c8f30e48c6cc016fbf7d794403153e5a72ec49af6b542e3d78370eb203` |
| `verify_appliance_backup.cjs` | `664e1814da5dc1fb411ba9aea6786680794609c28ca1b410e04f66769b558a81` |
