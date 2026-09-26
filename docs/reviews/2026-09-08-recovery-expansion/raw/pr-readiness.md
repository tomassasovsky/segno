# PR Readiness Review

## Scope and independence

Final local validation: September 9, 2026, for the September 8 recovery expansion
plan and issue #919. This is a silent HTML/CSS/JavaScript prototype in the
Flutter/Dart repository. No commit, PR, CI, merge or native release was requested.
The unrelated working tree, production code, generated CAD and existing workflow
changes are excluded.

Independent scope is the root-authored main/Library integration and appliance
capture, restore, restart and multi-store publication boundary, compared with
`/tmp/segno-recovery-expansion-before`. Mechanical checks also include the new
nonauthored port, primary, audition and multipart modules and browser tests.
The reviewer authored recorded-audio/recovery changes, the generic backup
model/study and their focused tests. Those files are included as dependency and
execution evidence only; this report does not independently approve its own
implementation or test quality. The other review roles independently cover them.

Role contract: `workflow-agents/references/pr-readiness-review-agent.md` and
`build/references/review-agent-instructions.md`.

## Formatting

Status: clean in the bounded source additions. Added lines were compared with
the saved baseline; new modules were checked in full. No trailing whitespace or
merge conflict markers were found. This design directory has no configured
JavaScript formatter or linter. The repository workflow's Dart formatting and
analysis gates target `lib`, `test` and package Dart sources; they do not apply to
these prototype files. No unrelated formatter was introduced or applied.

## Static analysis

Errors: 0. Warnings: 0. Infos: 0 from applicable syntax/dependency checks.

`node --check` passed on the following nonauthored modules and tests:

- `appliance-backup-host.js`, `appliance-storage-transaction.js`
- `session-library-study.js`, `session-field-ownership.js`, `session-audio-port-repair.js`
- `audio-routing-study.js`, `stage-transport-study.js`, `stage-display-study.js`, `loop-ux-study.js`
- `primary-track-study.js`, `preset-audition-study.js`, `fx-preset-library.js`
- `performance-recording-model.js`, `performance-recording-study.js`, `audio-library-study.js`, `storage-study.js`
- `verify_appliance_storage_transaction.cjs`, `verify_session_audio_port_repair_browser.cjs`, `verify_primary_audition_browser.cjs`, `verify_long_performance_recording_browser.cjs`

The main HTML's one inline script also parsed through `node:vm.Script`. Every
local script and stylesheet URL resolved to a file. The final host guard,
study adapter and extended appliance browser test were syntax-checked again
after the last correction. Browser runs below reported no page errors.
These are syntax and runtime checks, not a configured JavaScript lint result.

## Debug artifacts

Artifacts requiring removal: 0. The source scan found no new TODO/FIXME/HACK,
debugger statement, ad hoc production logging or conflict markers. Browser
verification scripts print their outcome intentionally. Named review scenes,
simulation APIs, storage-failure injection and silent-audio labels belong to the
explicit design sandbox. No `test.skip`, `test.only`, `describe.skip` or equivalent
suppression was found in the scoped new checks. No new secret-bearing file or
production debug dependency was introduced by this slice.

## Behavior and resolved integration findings

No unresolved actionable integration findings remain on the checked revision.

- **Changed USB archive after review:** the host initially cached its archive
  collection. It now rereads the actual store at revalidation. A real archive
  mutation after opening Review is refused without changing the live or saved
  setup.
- **Last performance metadata:** restore initially reconstructed recorder state
  without retaining the saved last recording. It now preserves that metadata and
  only clears the active capture. Exact whole-payload equality after restart and
  a further reload verifies the preserved last recording, sessions, recordings,
  presets, display/network/controller/update settings and preset packages.
- **Incomplete host preset collections:** the generic envelope intentionally
  leaves host-owned settings schema to its caller. A package missing either
  `presets.saved` or `settings.presetFiles` initially reached host preparation,
  clearing one collection and producing an undefined ancillary store value.
  The host now requires both arrays and validates them during archive inspection
  as well as final preparation. Both actual stored-package omissions show
  “Needs repair” and disable Review; the tests recompute generic summary counts
  so they exercise this host boundary. Removing either collection after Review
  also refuses publication, preserving all stores and live state.
- **Publication failures:** a real middle-key write failure rolls back every
  earlier write. The pending review is retained; encoder retry restarts only
  after successful publication. Unit checks distinguish rollback failure from
  a safely restored previous setup. The archive store is not overwritten by
  restore.

The root's synchronous restarting guard was traced through save, separate
settings writers, input dispatch and timer/render entry points. The architecture
review separately deferred the restart timer and verified that subsequent live
input cannot overwrite the newly restored stores. That independent race proof is
recorded in `architecture.md`; this report does not claim to have authored or
rerun that separate probe.

## Verification commands and outcomes

Commands use the available Node runtime and Playwright dependency path. There is
no production build or CI inference from these local commands.

```sh
node --test \
  docs/design/verify_recorded_audio_recovery.cjs \
  docs/design/verify_appliance_backup.cjs \
  docs/design/session-recovery-model.test.cjs \
  docs/design/session-recovery-study.test.cjs \
  docs/design/verify_session_field_ownership.cjs \
  docs/design/media-parity-study.test.cjs \
  docs/design/verify_appliance_storage_transaction.cjs
```

Result: **92 passed, 0 failed, 0 skipped** on the final dependency/host adapter
revision. This combined count is separate from the other reviewer's 99-test
coverage selection and is not added to it.

```sh
RECORDED_AUDIO_OUTPUT=/tmp/segno-recorded-audio-validation SKIP_SCREENSHOTS=1 \
  node docs/design/verify_recorded_audio_recovery_browser.cjs
APPLIANCE_BACKUP_OUTPUT=/tmp/segno-appliance-backup-validation SKIP_SCREENSHOTS=1 \
  node docs/design/verify_appliance_backup_browser.cjs
```

Both scripts passed **Chrome and Firefox**. They exercise normal persisted
storage, Cancel, device/USB loss, stale source, failure/retry, encoder commands
and reload. Recorded repair preserves a four-beat/two-second take within its
sixteen-beat Multi loop and copies an intact backup internally only at commit.
The backup suite includes the final incomplete-collection regressions above.
Previously inspected screenshots were retained because product geometry/copy did
not change in these final validation fixes.

Existing browser regressions also passed **Chrome and Firefox**:

```sh
node /tmp/segno-readiness-browser.cjs docs/design/verify_session_field_ownership_browser.cjs
node /tmp/segno-readiness-browser.cjs docs/design/verify_session_connection_repair_browser.cjs
node /tmp/segno-readiness-browser.cjs docs/design/verify_session_recovery.cjs
```

The temporary runner compiled each original test with its original filename and
module lookup paths, changing only the `output` directory to a dedicated `/tmp`
folder. It did not change assertions, fixtures or repository test files.
Ownership, connection repair and media recovery retained their existing
normal-storage, failure/reload, touch, encoder, foot and device-return checks.

## Commit hygiene

Commits reviewed: 0. Commit/PR/CI/merge operations are outside the authorization;
no commit-history or merge-readiness claim is made. This review uses explicit
local source hashes because much of the design sandbox is uncommitted. Browser
captures for this pass were directed outside shared screenshot paths. No source
or generated asset was staged by this reviewer.

## Auto-fixable

None remaining in the bounded review.

## Verdict

Local prototype code is mechanically ready on the checked revision. The final
Pen save gate is complete based on the coordinator's evidence: native File > Save
produced `segno-ui.pen` at 97,263,957 bytes, with SHA256
`b031cbb64477a2f1d5714565bf1aa48c8877636fb7fd0f7a78ed8779895e249a`
verified twice. Sections 42–47 contain fifteen full-size editable roots; all 495
text positions and fifteen focus outlines aligned with zero mismatches or clipped
focus. The coordinator inspected all fifteen native TakeScreenshot renders and
exported them to `docs/design/recovery-expansion-previews/pen/`. Browser scene
captures used a 1920 × 1080 canvas with no page errors; the review gallery is
`docs/design/recovery-expansion-previews/index.html`.

This Pen/render evidence was supplied by the coordinator, not independently
repeated by this reviewer. The reviewer confirmed the saved file size and gallery
existence and rechecked that main source remains at the reviewed
`c821a23af292aafd32d08e7e88fc9f60c732d6bcb037f6e9682525d0979d9bb4`
hash. No pending Pen save gate remains. Native audio bytes, physical device
identity, filesystem recovery and crash/power-loss durability remain separate
documented implementation gates. This is not a “ready to merge” or CI verdict.

## Checked hashes

Paths below are relative to `docs/design`. Whole-file hashes identify the
revision; they do not expand the independent review scope described above.

| File | SHA256 |
| --- | --- |
| `fx-ux-prototype.html` | `c821a23af292aafd32d08e7e88fc9f60c732d6bcb037f6e9682525d0979d9bb4` |
| `appliance-backup-host.js` | `6a6b0ad103c48393a9bb42a0d49d37609f353e79eb64f9d608613930e6aa766e` |
| `appliance-storage-transaction.js` | `9d89f4935df8628f6609a7c1522ad11f43bb9db426a99233cd7b854910f1d546` |
| `session-library-study.js` | `25f556b5e278b3ff7980ac898dfd8067023310625064bdd1c32d8ff512c5be33` |
| `session-library-study.css` | `dde7ba1f85516198558c5022960bd0adf6b4f5b2fe13715917338a69fc6c9c29` |
| `session-field-ownership.js` | `d89e7d1d7d6f83075e4da2f838c4512548e2f07288c42fb4e6971bc9192f1932` |
| `session-audio-port-repair.js` | `ccad704c9d5affa1c07da4d708d568de03204fe32c7aa581432a051fb7a01e07` |
| `audio-routing-study.js` | `d559cfec375a623a96b7c3c7ece29c73d2184f3d37cfa9436738c66f1a2a889b` |
| `stage-transport-study.js` | `ad1022a28f7672385062d961610b75b6a118bb41ca6be48419216af3d99dd20d` |
| `stage-display-study.js` | `b2c7d968ec39ec562a8dd62f11b16fe939a8e957e7ad69e64d04b28804f6216d` |
| `loop-ux-study.js` | `a862cd5777cfbfe88dbf511f546eb0bdc75e1ee02a83981f00a757f0d75f4b56` |
| `primary-track-study.js` | `70b8ca703aaf12f62ad27ab5ec506d42c4d93b42b383970aa4de02e25acd7fb1` |
| `primary-track-study.css` | `a8e59f7131aff60ca3a73ef1f9367fd97a899cd2efb87c51507cef58e5ee0d12` |
| `preset-audition-study.js` | `22e501294f90ca31a70ec5ac2ee60640185e869e06c593477506855cbde0615a` |
| `preset-audition-study.css` | `39d68633f2e9f0933dcb4d0141747f13fdaaa2b92222880921af1fe640ea4689` |
| `fx-preset-library.js` | `049cd20c658262a90ec5852bfd06c666e1933ae62ddd82884c7ef83f70c8e233` |
| `performance-recording-model.js` | `403aa6e3a88455b7c35c1a5801d8325c9a598c9770684e78977e4ac472898600` |
| `performance-recording-study.js` | `66335027c00b815c29f17538116f4d766ded91dd2c814c1367e2b6d0a6f2464e` |
| `audio-library-study.js` | `544d12fa11f3857e6a4969ff23372d3d607a0563aad5ed0473f03111c7914a40` |
| `storage-study.js` | `7a253aa4a4d135a1f2f7db03f4f65892442fd260667676885ee11cf347c1ae21` |
| `verify_appliance_storage_transaction.cjs` | `4f6f135db6071eebd106be102dc0d0e8e7ce470f097effb231d8c059b428da80` |
| `verify_session_audio_port_repair_browser.cjs` | `f78dfa08d64c47e2ad7c6b052f97e81d0396c96b3da0c9a12ad61755ce4fb641` |
| `verify_primary_audition_browser.cjs` | `a1fd01c8f30e48c6cc016fbf7d794403153e5a72ec49af6b542e3d78370eb203` |
| `verify_long_performance_recording_browser.cjs` | `578ee85600c63db2269af9ac93ded79ab9025d7396cac3746a111c6eb3d1d2c7` |
| `verify_session_field_ownership_browser.cjs` | `d44b51cf922ddb5c6a959087cec3020f067ba9310d5c602b16241fd3096f3ece` |
| `verify_session_connection_repair_browser.cjs` | `1bb5c330ac09bfc3b9b7c8319192157b05b19c9eb5bf3b949e03707b12b3a8dd` |
| `verify_session_recovery.cjs` | `b6264f000fc19c3cc8d39bcf835088a244e6722b9ff40cb5ab50a3366378dfd5` |
| `verify_recorded_audio_recovery_browser.cjs` | `d4748d72d634dca9c2b761fafed5155461f99f03ebce9a68bbc673cacd365904` |
| `verify_appliance_backup_browser.cjs` | `8ae1eee1c96e71699e8cd965f69f5f6b9d5ac31be93b78074d8c6bd739caff48` |
| `recorded-audio-model.js` | `8c4d2d3834f4b9da22a1c6059fb3bb6be5693467fd71afef3ce2e53707b26bf3` |
| `session-recovery-model.js` | `395f4687fd9185c569009011033125303def002f45baff25f978cc3637f7d774` |
| `session-recovery-study.js` | `6072a01114227cd293d027e5e2d4c2aafafeb7ff2c604d28fc55aca26e7c64f9` |
| `appliance-backup-model.js` | `d9af82178d2b7bebf529f838a822156db88c2e9ef2453c5944967a1deb27db0a` |
| `appliance-backup-study.js` | `7ffa10d1c748aeb94869a60651023540e229c3b0ef21aea7ded979f03a8a7a07` |
| `appliance-backup-study.css` | `d741b6f51ca1bb4ae81099626acc6dffddd5ff82458884c3a71fc65edd4f38e2` |
| `verify_recorded_audio_recovery.cjs` | `28c03d62ac7a085a4e84bc573b10921af26f5e3f392fceb20361cde8c27022c0` |
| `verify_appliance_backup.cjs` | `664e1814da5dc1fb411ba9aea6786680794609c28ca1b410e04f66769b558a81` |
