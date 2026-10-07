Model: Claude Opus (subagent), in-session

# Review of PR #1211: fix(session): convert older saved sessions to the current schema on open

## Scope

- Branch `origin/claude/session-migration-1196` at 579b1ed9a: one change commit (c0775b9b7) plus a merge of the trunk at 56033baf0. Issue #1196.
- Reviewed against `docs/plan/2026-10-06-fix-session-schema-migration-plan.md`, AGENTS.md, the owner rules and the owner decision. The owner decided that saved v7 sessions must keep opening, be converted on open, keep the original as a backup, and show a notice.
- I read the whole migration module and the repository, cubit, state, notice, dialog and l10n diffs. I traced each default against the code that wrote the schema: master `bedcecf27`, the slice commits and the trunk commits.
- The trunk has since moved to 7a9fdcbd9, a UI-only commit. The PR still merges into it cleanly.

## Runs

| Check | Result |
| --- | --- |
| `packages/session_repository` tests, `SEGNO_ENGINE_LIB` exported | 150 passed |
| Root `test/session`, `test/looper/view/session_outcome_notice_test.dart`, `test/app/application/app_runtime_test.dart`, `test/app/view/app_test.dart` | 290 passed, 6 skipped (author-only goldens) |
| `dart analyze` | No issues |
| `bloc lint lib test packages` | 0 issues, 847 files |
| cspell on the plan (CI checks only `**/*.md`) | 0 issues |
| Fixture `v8_trunk_a0a54e57e` regenerated in a fresh worktree at a0a54e57e with its own generator | all 9 files byte-identical |
| Fixtures `v7_master_full` and `v7_master_empty` regenerated in a fresh worktree at master `bedcecf27` with the native test library built there | all 12 WAVs byte-identical. The manifests are identical except the random 8-hex prefix of the slot ids, which `_clampAndMint` mints on every run. |
| Probe A: open v7, write the conversion back, save, then restore `session.v7.json` | the backup no longer opens (finding 1) |
| Probe B: make the backup fail during `save` | the v7 manifest is left over overwritten audio (finding 4) |
| 5 mutations (below) | 2 caught, 3 survived (finding 7) |
| Merge with Peel P2 (531addc0d), plus a draft 11→12 step | see "Peel's 11→12 step" |

Nothing was committed, pushed or posted. The probes, mutations and merges stayed in scratch worktrees.

## Verified correct (traced)

- **The strict decoder is unchanged.** `models/session.dart` is not in the diff. `decodeSessionManifest` sends version ≥ current, or a non-int version, straight to `Session.fromJson`. It converts a version from 7 up to the current one step by step, then applies the same strict decode. Every error is wrapped as `SessionUnconvertible`, except `SessionCorruptLayers`.
- **No "newer" message for old files.** An older version can only reach `SessionUnsupportedVersion` through the strict decoder, and the driver never sends it there unconverted. Older-than-7, a failed step, a failed strict decode and a failed tempo or grid check after conversion all raise `SessionUnconvertible`. That maps to `SessionError.unconvertible` and its own text, which the dialog shows in the version banner and the snackbar shows as its own message. On the trunk today a v7 bundle shows "saved by a newer version". This PR fixes that.
- **Every refusal leaves the bundle unchanged.** `open` never writes. `commitConversion` runs only after `applySession` succeeds (`session_cubit.dart:348`), and it returns early if `session.json` changed since the open. The byte-identical refusal tests cover newer, older-than-7, a step failure, a strict-decode failure, a tempo failure and a sample-rate mismatch.
- **The fixtures are genuine.** I regenerated the v8 trunk fixture and both v7 master fixtures at their named commits; see Runs.
- **v7 track settings.**
  - Master's `applySession` resets every track to AUTO and One Shot off, then arms only what the rig names (`looper_repository.dart` at bedcecf27). So `defaultOneShot: false`, `defaultLengthPresetBars: 0`, `trackOneShotOverrides` built from `oneShotChannels` plus per-track `oneShot`, and `trackLengthPresetOverrides` built from presets above 0 reproduce master exactly.
- **`loopBars: 0` matches master.** Master's `LE_CMD_COMMIT_SESSION` stores `a_loop_bars = 0`: "until then an import is grid-free".
- **Master saved tempo and click but never applied them.** Master's `rigFromBundle` passes no tempo, signature, grid, click or count-in to `SessionRig`. Applying the saved values is a deliberate change that the notice covers. The saved tempo is the one the takes were recorded at, so I agree with the choice.
- **Live values for the formerly global toggles are right.** Master kept `tempo.sync`, `looper.rec_dub`, `looper.auto_record`, `looper.default_multiple` and `looper.quantize` as global settings keys, and a load never changed them.
- **The master enums match.** ClickMode, GridDivision, LooperMode and MonitorMode have the same names on master and the trunk.
  - Master's UI offers only count-ins of 0, 1, 2 and 4, so trunk's `_readCountIn` accepts every value master wrote.
  - Master's TempoSource `external` is "reserved, unused", and every master tempo writer clamps to 30–300, so `_validateMusicalGrid` accepts every master tempo.
- **Master's v7 manifest never changed.** `session.dart` was not touched between `990a60f5b` (#611) and `bedcecf27`, so one master fixture covers every v7 master file.
- **`masterChain` → output bus 0 for schemas 8 and 9 is right.**
  - At a0a54e57e, `_applyMasterEffects` calls `setOutputFx(bus: kMasterOutputBus)`.
  - From slice 3b (f628c7412), `LE_CMD_SET_MASTER_FX` writes `outputs[0]` ("The Master insert (51) is bus 0's chain").
  - A file with both `masterChain` and a bus-0 chain is refused rather than merged, and no writer produced both.
- **`masterChain` → `allTracksChain` for a master v7 file is the closer stage.**
  - Master's `master_fx_frame` runs after `mix_tracks_frame` and before `mix_monitors_frame`, so it colours only the tracks.
  - Trunk's All tracks stage also runs on the recorded mix only, before monitoring joins. An output chain would colour live monitoring.
  - The one difference is the one the plan states. Master processed only the first two enabled output channels, while All tracks runs one instance per bus. A lane routed outside the first enabled pair was dry on master and is wet now. That is rare on a single-pair rig, but it is audible on a 4i4 rig that sends a lane to the 3–4 pair.
- **Lane routing and level are unchanged.** Trunk's `outputMask` is still channel bits (`out_mask[t][l] & out_enabled` → `le_fx_route`). Trunk's pan law is unity at centre (`le_pan_gains`). Master had no track fader: its `setVolume` sets lane volumes. So empty `trackLevels`/`trackPans` and centre lane pan reproduce master's levels.
- **The monitor ceiling is enforced.** The strict `SessionMonitor.fromJson` refuses a volume above 1, so the clamp is the only alternative to refusing the session.
- **The native apply works.** `session_conversion_test` applies the converted v7 bundle to a `PumpedNativeEngine` with its audio, its undo/redo history and its chains.

## Judgement of each chosen default

| Default | Verdict |
| --- | --- |
| Live fill for `syncTempo`, `recDub`, `autoRecord`, `defaultMultiple`, `recordTiming` | Right; master held them globally (verified above). |
| Live fill for `trackRecordTimingOverrides` | Wrong for a master v7 file (finding 3). Master had no per-track record timing, so "live" carries the previously loaded session's per-track choices into a session that never had any. |
| `masterChain` → `allTracksChain` (v7) | Right for master v7 files. Wrong for slice-era v7 files written from slice 3b on (finding 6). |
| `masterChain` → bus 0 (v8/v9) | Right (verified above). |
| Monitor clamp to 1, noted | The right call over refusing. It changes the sound by up to 6 dB (150% → 100% is −3.5 dB), and the player is told only through the log (finding 5). |
| Backup is the manifest only | Valid only until the first save into the bundle (finding 1). |
| `inputSetup`/`outputSetup` empty, not live | Acceptable: empty reproduces how master recorded and played. The cost is that opening a converted session resets the player's current trims, stereo pairs and destination levels. Trunk sessions already own these, so that matches the trunk model. |
| Pedal binding on the Master stage left unresolved | Avoidable silent dead pedal (finding 2). |

## Findings

### 1. The backup is only valid until the bundle is next saved — Medium

- **Where.** `packages/session_repository/lib/src/session_repository.dart`.
  - `commitConversion` (`:634-646`) keeps only `session.v<N>.json`.
  - `save` overwrites every `track{c}_lane{l}_L{n}.wav` in place (`:483`) and then deletes every layer file the new manifest does not name (`_pruneOrphanLayers`, `:528`).
  - The notice says "The original file was kept beside it." (`app_en.arb:163`).
- **Scenario (probe A, reproduced).**
  1. Open `v7_master_full` and write the conversion back.
  2. Record a new take on track 0 and save.
  3. Afterwards the bundle holds `{session.v7.json, session.json, mixdown.wav, track0_lane0_L0.wav}`. `track0_lane0_L0.wav` holds the new take, and the other 11 layer files the backup names are gone.
  4. Put `session.v7.json` back as `session.json` and open it: `PathNotFoundException ... track0_lane0_L1.wav`.

  If the new save had kept the same layer count, the restored backup would open and silently play the new audio under the old mix and chains.
- **Impact.** The owner asked for the original to be kept as a backup, the recovery path under rule 2. After one save that path is broken, and nothing says so.
  - The common flow is open old session, play, save, so most backups will be in this state.
  - "Keep the original" holds for the manifest bytes only.
  - The plan justifies manifest-only by size ("would double a bundle's size"). That holds for the conversion itself but not for the first save, when the original audio is destroyed anyway.
- **Fix.** Pick one and state it in the plan:
  - (a) On the first `save` into a bundle that holds `session.v<N>.json`, move the layer WAVs it names into a `session.v<N>/` folder with the backup manifest before writing new audio.
    - A rename costs no copy, so the backup stays complete. Only files the new save rewrites need moving.
    - The extra space is the original audio, once, and only for converted sessions.
  - (b) On that first save, rename the backup to something that says it is incomplete, or delete it, and say so in the save outcome.
  - (c) At minimum, change the notice and the plan to say the original manifest is kept until the session is saved again.
- **Test.** Open, commit and save with different audio, then require that restoring the backup opens with the original audio, or that the backup is gone and the outcome says so.

### 2. A pedal bound to master's Master insert goes dead, though the conversion knows where that chain went — Medium

- **Where.** `session_migration.dart` leaves `pedalBindings` untouched. The plan's "Defaults" row says such a binding stays unresolved and "the assignment screen offers rebind (existing R25 behaviour), so it is not silent". `session_conversion_test.dart` asserts that `[FxStage.loop, null]` decodes.
- **Scenario.**
  1. On master, a player bound a footswitch to the Master chain: `{"stage":"master","index":0}`, as in the v7 fixture.
  2. After conversion the same chain sits in `allTracksChain`, but the binding's stage `master` no longer parses (`FxStage` has `input, loop, track, allTracks, output`).
  3. Stomping it does nothing, and its LED is dark (`control_cubit.dart:3036-3048`, "stale — no-op").
  4. The only explanation is on the pedal assignment page (`pedalAssignStaleDetail`). The load notice and the conversion notes do not mention it.
- **Impact.** At a gig this is a silent behaviour change (rule 3), and an avoidable one: the step moves the chain verbatim, slot ids included, so the target is known exactly. Rule 4 (consolidate) also favours carrying the binding with its chain.
- **Fix.**
  - In `_v7ToV8`, after moving `masterChain`, decode `pedalBindings` (a JSON list of `{button, bank, target, behavior}`) and rewrite each `target` whose stage is `master`:
    - to `{"stage":"allTracks","index":0, ...}`, keeping a `slot` key if present;
    - note it in the conversion notes.
  - In `_settleBusChains`, rewrite it to `{"stage":"output","index":0, ...}` for bus 0, for the same reason. Schemas 8 and 9 wrote the `master` stage too.
  - If the owner wants the blob to stay opaque to `session_repository`, do the rewrite in the app layer, which already decodes `PedalBindingSet`, keyed on `convertedFrom`.
  - Add the binding to the v7 fixture test as resolving to `FxStage.allTracks`.

### 3. A master v7 session inherits the previous session's per-track record timing — Low

- **Where.** `session_migration.dart:230-233`: `_fill(m, c, 'trackRecordTimingOverrides', {live overrides}, live: true)`. `session_migration_test.dart` pins it (`{3: RecordTiming.bar}` from `_live`).
- **Scenario.**
  1. The player has a trunk session open whose track 3 records on the next bar.
  2. They open a master v7 session.
  3. Its track 3 now records on the next bar, a choice from an unrelated session.

  Master had no per-track record timing (it arrived in slice 2b, 7a8c7c3bd). On master every track followed the global `looper.quantize`.
- **Impact.** The plan's reason for live values, "master kept these global, and opening never changed them", applies to the session-wide `recordTiming`. It does not apply to per-track overrides, which on the trunk are session-owned state of the outgoing session. The result is a cross-session bleed that nothing reports.
- **Fix.** Fill `trackRecordTimingOverrides` with `{}` when the manifest has none. A slice-era v7 file still keeps its own: `_adoptSliceSpellings` builds the map from per-track `recordTiming` first. Update the test expectation.

### 4. `save` overwrites the audio before it keeps the backup, so a failed backup tears the bundle — Low

- **Where.** `session_repository.dart`: the layer WAVs are written at `:483`, and `_keepOriginal` runs later at `:502-508`.
- **Scenario (probe B, reproduced).** The trigger is a v7 bundle whose `commitConversion` failed. This is the logged-and-continue path at `session_cubit.dart:403-416`, for example on a full or read-only disk.
  1. The player saves.
  2. The new WAVs are written.
  3. `_keepOriginal` throws.
  4. `session.json` is still the v7 manifest, but `track0_lane0_L0.wav` now holds the new take, and pruning never ran.
  5. The bundle now pairs the old manifest with partly new audio.
- **Impact.** This is the window that the save-time backup was added to protect: "the original survives even when the write-back after loading failed". The PR adds a deterministic throw point inside it. The older window, a manifest write failing after the WAVs, already existed.
- **Fix.** Take the backup at the top of `save`, before any audio is written. Better still, write the WAVs and manifest through temporary names and rename them, though that is a wider change.

### 5. The conversion's audible changes reach only the log, and the notice can claim a backup that was not written — Low

- **Where.**
  - `session_cubit.dart:403-416`: notes go to `AppLog.info`, and a write-back failure goes to `AppLog.warn`.
  - `tracks_commands.dart:391-394` and `app_en.arb:163`: one generic sentence that always says "The original file was kept beside it."
- **Scenario.**
  - The v7 fixture's auto monitor drops from 150% to 100%: "monitors[0].volume: 1.5 lowered ...", a 3.5 dB drop.
  - Its Master chain moves to All tracks.
  - The session's own tempo, click and count-in replace the player's.

  The player sees only "converted". The cubit test "that cannot be written back still loads, converted" shows the same sentence when no backup exists: the original is still `session.json`, not beside it.
- **Impact.** Rule 3 asks for no silent behaviour changes, and rule 5 asks for a notice when state is dropped. A log line on an appliance is not a notice. The false backup claim matters because of finding 1.
- **Fix.**
  - Carry a `committed` flag and only claim the backup when it was written.
  - Put the audible notes in the notice, for example "A live input was lowered to 100%" and "The Master effects now run on All tracks", or offer them as a details line.
  - The plan's design write-back says no new surface. One extra line in the existing snackbar keeps that.

### 6. Slice-era v7 files from slice 3b onward map their bus-0 chain to All tracks — Low

- **Where.** `session_migration.dart:169-175` treats every v7 `masterChain` as master's pre-monitor insert.
- **Trace.**
  - From f628c7412 (slice 3b) to 7a29dda18, the slices still wrote `formatVersion = 7`, but `LE_CMD_SET_MASTER_FX` already wrote output bus 0.
  - The slices' own v7→v8 bump (919e337d2) only added `allTracksChain` and kept `masterChain` as bus 0.
  - So for those files the step moves a post-monitor output chain onto a pre-monitor stage: live monitoring loses the effect.
- **Impact.** It only affects dev-host or dev-appliance saves from that two-week slice window. The owner's decision covers master and the field appliances. The plan's schema table says this range is the "same number, extra optional keys", which is not quite true.
- **Fix.** Either detect it (`outputSetup` exists only from 3b, but it is omitted when empty, so detection is partial), or record the limitation in the plan's table and the notes. Documenting it is enough.

### 7. The crash-safety order and the corrupt-layers pass-through are untested — Low

- **Where.** Mutations on the package suite (150 tests):
  - Ma: in `commitConversion`, replace the manifest before keeping the backup. **Survived.**
  - Mb: `_replaceManifest` writes `session.json` directly, with no temporary file and rename. **Survived.**
  - Mi: `decodeSessionManifest` drops `on SessionCorruptLayers { rethrow; }`, so corrupt layers in an old bundle are reported as "can't convert". **Survived.**
  - Mk: the monitor `mode` is always overwritten from `enabled`. Caught.
  - Ml: `defaultOneShot` defaults to true. Caught.
- **Impact.** The plan's "a crash leaves either the old or the new manifest" and "keep the original first" are not protected. A failed `_replaceManifest` also leaves its `session.json.<µs>.tmp` behind for good. `duplicateSession` copies it, and nothing removes it.
- **Fix.**
  - Add a test that makes `_keepOriginal` fail (for example, a directory named `session.v7.json`) and requires `session.json` unchanged. That catches Ma.
  - Add a test that a converted bundle with a mismatched layer count raises `SessionCorruptLayers`. That catches Mi.
  - Delete the temporary file when the write or rename throws.

## Notes

- **Open question for the owner: schemas older than 7.**
  - Master's decoder accepted every schema from v1 to v7 leniently. The pre-7 bumps:

    | Schema | Date | Commit or PR |
    | --- | --- | --- |
    | v1 | 2026-06-08 | 8547affe7 |
    | v2 | 2026-07-05 | #112 |
    | v3 | 2026-07-12 | #151 |
    | v4 | 2026-07-23 | #280 |
    | v5 | 2026-07-30 | #388 |
    | v6 | 2026-07-31 | #412 |

    v7 arrived on 2026-08-10 (#611). Appliance OTA was validated on 2026-07-25, so pre-7 bundles that were never re-saved may exist on appliances.
  - Pre-7 bundles are refused here with `SessionUnconvertible`.
  - Cost of converting them:
    - **6→7** is a no-op: the only change was `monitors[].mode`, and `_fillSessionSettings` already derives it from `enabled`.
    - **5→6** only fills `pedalBindings: ''`.
    - **4→5** fills `trackChains: []` and `masterChain: ''`. Bare-array chains still decode (`fx_chain_envelope.dart:103`).
    - **v3 and older** need master's tempo/grid-off defaults, and **v1/v2** need master's single-lane `stem` synthesis.
  - My recommendation is to add 5→6 and 6→7 now, since they are trivial, and to let the owner decide on v4 and older.
- **The bundle-format doc goes stale on landing.** Peel P2's `docs/design/session-bundle-format.md` says "any other `version` fails with `SessionUnsupportedVersion`". Once both PRs land, it should say that v7 to v(current−1) are converted on open with a backup. Neither PR changes it.
- **The Library branches** (`readPreview`, rename) call `Session.fromJson` directly, as the plan notes. They must switch to `decodeSessionManifest` when they land on the trunk.
- **Design.** The PR adds no new surface: one string in the existing snackbar and the existing version banner reused. I did not open the pen for this review.
- **Peel's 11→12 step** (verified on a local merge with 531addc0d). The two branches conflict in `session_exception.dart`, `test/app/application/app_runtime_test.dart` and `test/session/cubit/session_cubit_test.dart`.
  - The exception file needs both sides: `SessionUnconvertible` and Peel's `SessionCorruptLayers` doc comment.
  - In the test files, take this PR's `open` stubs and add `history: TrackHistory.none` to every `SessionLane` (Peel made it required).
  - After resolving, without the step, 20 of the 28 `session_migration_test` cases fail: every conversion ends at strict v12 decode with "no step 11".
  - With this step, the v7–v10 conversions and the native apply of converted v7 pass on Peel's stricter `finalize_history`:

    ```dart
    // sessionMigrationSteps: 11: _v11ToV12,
    void _v11ToV12(Map<String, dynamic> m, SessionMigrationContext c) {
      for (final track in _list(m, 'tracks').cast<Map<String, dynamic>>()) {
        for (final lane in _list(track, 'lanes').cast<Map<String, dynamic>>()) {
          if (lane.containsKey('history')) continue;
          final entries = (lane['undoCount'] as int) + (lane['redoCount'] as int);
          lane['history'] = [
            for (var i = 0; i < entries; i++) {'kind': 'layer', 'skipped': 0},
          ];
          c.note('tracks[${track['channel']}].lanes[${lane['lane']}].history',
              '$entries layer entries');
        }
      }
    }
    ```

    This is exactly what v11 recall did (`finalize_layers` filed every entry as `LE_HIST_LAYER`, and v11 capture dropped any track with a redo marker). `undoCount`, `redoCount` and `layers` stay unchanged, and the shape passes `TrackHistory.malformation`.
  - Test-data changes that go with it:
    - Move `v11_trunk_5c163d11f` into the intermediate list. Its fade default is 6000, not 4000.
    - Generate a `v12_peel_<sha>` fixture with Peel's own `save` for "the current schema opens with no conversion" and the refusal "newer" case.
    - In `session_conversion_test.dart`, change `name.startsWith('v11') ? isNull` to v12.
    - Add the generator under `fixtures/generators/`.

## Verdict

**Request changes.** The core design is sound:

- an unchanged strict decoder;
- one step per bump;
- in-memory conversion with write-back only after apply;
- byte-identical refusals;
- genuine fixtures;
- correctly traced chain stages for schemas 8 and 9.

Findings 1 and 2 break owner rules, and each fix is small. The backup does not survive the first save (rule 2), and a master pedal binding goes dead without notice (rule 3). Fix 3 and 4 in the same pass. Findings 5–7 can follow.

## Delta review (bfd6afae7)

Model: Claude Opus (subagent), in-session.

### Scope

bfd6afae7 is a merge of trunk 097e1ef68 (Peel P2 and Library p1–p3) into 579b1ed9a. The review fixes and the schema 1–6 conversions are folded into that merge commit, so I reviewed `git diff 097e1ef68 bfd6afae7` (the PR's whole contribution over the trunk) and re-traced the changed paths.

### Runs

| Check | Result |
| --- | --- |
| `packages/session_repository` tests, `SEGNO_ENGINE_LIB` exported | 232 passed |
| Root `test/session`, `test/library`, `session_outcome_notice_test`, `app_runtime_test`, `app_test` | 378 passed, 6 skipped (author-only goldens) |
| `dart analyze` | No issues. Every package needs `pub get` first; `storage_repository` was new to this worktree. |
| `bloc lint lib test packages` | 0 issues, 884 files |
| Fixture `v3_loopy_319a7dc9d`, regenerated in a fresh worktree at 319a7dc9d with its own generator | all 5 files byte-identical |
| Fixture `v12_peel_097e1ef68`, regenerated at 097e1ef68 | all 11 files byte-identical |
| Probe C: a power cut after the swap, before the originals move; then a catalog read | recovery finishes the move, and `session.v7/` opens with the original audio |
| Probe D: a power cut in the middle of the move (folder created, one layer moved); then a catalog read | the backup is split in two (new finding A) |
| Mutations Ma, Mb, Mi from the first round | all 3 now caught |
| New mutations: no `.tmp` cleanup; recovery deletes `<id>.old` without moving; originals copied by `_carryForeignFiles` | 1 of 3 caught (new finding B) |

### Earlier findings

1. **The backup did not survive the first save: fixed.**
   - A save is now a staged bundle that is swapped in.
   - After the swap, `_retire` → `_keepOriginals` moves the kept `session.v<N>.json` and every layer file it names out of the retired bundle. They go into `<new>/session.v<N>/`, which opens as a bundle. A bundle whose write-back failed has its own older `session.json` moved the same way.
   - Later saves move the folder along unchanged.
   - Schema-1 stems such as `track1.wav` are not layer files, so they are excluded from `_carryForeignFiles` by name.
   - My probe A scenario is now the test "after the conversion was written back", which checks the original bytes after two saves.
   - Library's staged save made the old save-ordering issue (finding 4) disappear: the previous bundle is never touched until the swap.
2. **The Master binding goes dead: fixed.**
   - `_retargetMasterBindings` rewrites a `{"stage":"master"}` target:
     - to `allTracks` index 0 for schemas 5–7 (`_v7ToV8`);
     - to `output` index 0 for schemas 8–9 (`_settleBusChains`).
   - It keeps a `slot` key, drops `lane`, and leaves an unparseable blob alone.
   - Schemas 10–11 are left alone, because the binding was already inert as written. I agree: making it live would change those sessions.
   - Tests pin both targets, and the native apply test resolves it to `FxStage.allTracks`.
3. **The `{}` default: fixed.** `trackRecordTimingOverrides` fills with `{}` (`session_migration.dart:408`), and the test expects it to be empty against a live `{3: bar}`.
4. **Back up before writing: resolved by the staged save.** A failed save leaves the previous bundle byte-identical. The test "a failed save leaves the original bundle as it was" throws at the manifest write.
5. **The notice text: fixed.**
   - `SessionConversionNotice(written, changes)` drives the message:
     - "...The original was kept beside it." when written;
     - "...couldn't be saved converted, so the original file is unchanged." when not;
     - plus one sentence each for `masterEffectsMoved` and `monitorLevelLowered`.
   - Residual (Low): `commitConversion` returns silently, without writing, when `session.json` changed after the open (`session_repository.dart`, the early `return`). The cubit then reports `written: true`. Return a bool and use it.
6. **The slice limitation: documented** in the plan's schema table and its "Known limitation" paragraph.
7. **The three mutations: now caught.**
   - Ma (order): "a backup that cannot be kept leaves the manifest unchanged".
   - Mb (temp file and rename): "the manifest is replaced by a rename". A read-only manifest can only be replaced, not rewritten.
   - Mi: "a converted bundle with a broken layer stack reports it".
   - A failed write now deletes `session.json.tmp`.

### Library staged saves: the crash cases

- **Before the swap:** a crash leaves the staged `<id>.saving`, which recovery deletes. The previous bundle is whole.
- **Between the two renames:** `<id>.old` without `<id>` is renamed back.
- **After the swap, before the move (probe C):** `<id>.old` beside `<id>` → `_retire` → `_keepOriginals`, then delete. Verified: the backup folder is complete and opens.
- **A non-crash failure during the move:** `FileSystemException` is caught, and `<id>.old` stays for the next catalog read. A non-UTF-8 manifest also surfaces as `FileSystemException` (checked).
- **A power cut during the move (probe D):** see new finding A.

### Schemas 1–6 (owner decision: convert all, with conservative defaults)

- **Coverage.** The steps 1→2 … 6→7 are present, and the coverage test runs from schema 1. Every fixture v1–v6 opens. Converted v1, v2 and v4 apply to the native engine.
- **v1.**
  - The transport keys map to `syncTempo`.
  - Record timing and grid: `beat` → `quarter`/`quarter` and `bar` → `bar`/`bar`. `quarter` is a valid `RecordTiming`.
  - The metronome → `playRec`; count-in → 1 bar; the tempo stays manual in 4/4 when it is between 30 and 300.
- **Stems.** v1/v2 stems become lane 0 with the track's level and mute, outputs 0x3 and no input. That is master's own fallback.
- **Derived tempo (v2/v3, or v1 out of range).** `_deriveTempo` mirrors `le_grid_derive_bpm`: the same bar window and nearest-120 search, ties going to fewer bars, and a float32 result. It sets `derived` plus `loopBars`. This is the owner's decision.
  - It differs from how master read these files (grid-free, `a_loop_bars = 0` on import), so a derived tempo locks the tempo while content exists.
  - The notice says "converted" but not "tempo derived". A one-line notice sentence would complete rule 3 here, as was done for the Master move. Optional.
- **Chains.** Chains saved as bare arrays in v2–v4 are kept (the current decoder reads them). Missing stages fill empty.
- **The v3 fixture** is genuine (byte-identical regeneration at 319a7dc9d).

### The 11→12 step and the v12 fixture

- `_v11ToV12` is the step I proposed: one `layer` entry per undo and redo entry, with counts and layers unchanged.
- `v12_peel_097e1ef68` regenerates byte-identically at 097e1ef68. It includes an undo-side `peel` entry (track 3), so the "current schema opens with no conversion" test exercises real Peel history.
- `v11_trunk_5c163d11f` is now an intermediate fixture.

### New findings

**A. A power cut in the middle of moving the originals splits the backup — Low (Medium if the backup is the only copy).**
- **Where.** `_keepOriginals` (`session_repository.dart`, the manifest loop):
  1. It creates `<live>/session.v<N>/`.
  2. It renames the layer files in one at a time.
  3. It moves the manifest last.
- **Scenario (probe D, reproduced).** A cut after one layer file moved leaves `<id>.old` beside `<id>`. Recovery runs `_keepOriginals` again:
  1. `_freeBackupStem` sees the partial `session.v7/` and picks `session.v7.2/`.
  2. It moves the remaining layers and the manifest there.
  3. It deletes `<id>.old`.
- **Result.**
  - `session.v7/` holds only `track0_lane0_L0.wav` and no manifest.
  - `session.v7.2/` holds the manifest and every other layer, and opening it fails with `PathNotFoundException ... track0_lane0_L0.wav`.
  - No audio is lost, but the backup does not open without a manual merge, and nothing says so.
- **Fix.** Make the move resumable.
  - Either build the folder inside the retired bundle (manifest first, then layers) and rename the finished folder into the live bundle in one step. On recovery, finish any folder in the retired bundle whose manifest names layers still at its root before renaming it.
  - Or, on recovery, reuse a manifest-less `session.v<N>*` folder in the live bundle instead of choosing a new stem.

**B. The recovery path that finishes the move is untested — Low.**
- Mutation Mr changes the recovery's `_retire(entity, live: …)` into a plain `entity.deleteSync(recursive: true)`. It passes all 232 package tests. Under that mutation, a power cut after the swap deletes the original. Probe C shows that today's code is right, but nothing pins it.
- The `.tmp` cleanup on a failed write is also unpinned (mutation Mt survives).
- **Fix.** Add a catalog test that builds `<id>` plus `<id>.old`, as in probe C, and requires `session.v<N>/` to open after a catalog read. Add a probe-D variant once A is fixed.

### Notes

- Library previews, the stems export and the Library refusal banner decode through the conversion. The catalog's effect count includes `masterChain`, and a `session_catalog_test` case covers a v7 preview without writing.
- Rename edits only `name` in an older manifest. The extra key is harmless to master's lenient decoder and to the conversion.
- Running `pub get` in packages new to my worktree rewrote some `analysis_options.yaml` files locally. This is unrelated to the PR, and the worktree has been removed.

### Verdict (delta)

**Approve.**
- All seven earlier findings are fixed, documented or tested.
- The 11→12 step and the v12 fixture are correct and genuine.
- The schema 1–6 conversions follow the owner's decision and pass on fixtures that I confirmed are genuine.

New findings A (making the move resumable) and B (a recovery test) are small and can be fixed before merge or right after. Neither loses audio.
