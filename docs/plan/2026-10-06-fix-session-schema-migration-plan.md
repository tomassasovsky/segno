# Convert saved sessions from older schemas on open

Tracking: #1196, `autonomy:merge-gate`. Owner decision, 2026-10-06: sessions
saved by the shipped app (schema 7, on master and on the appliances) must keep
opening after the trunk lands. This is a deliberate, owner-made exception to
the AGENTS.md rule against migrations. It is kept to one module
(`packages/session_repository/lib/src/session_migration.dart`), and the strict
current-schema decoder (`Session.fromJson`) is unchanged.

## Schema history

Reconstructed with `git log -G'formatVersion = '` on
`packages/session_repository/lib/src/models/session.dart`. Schemas 8 and 9
were each written by two histories that the trunk later merged: the September
slices (#1016) and the October 1 reconstruction (#1061), whose merge commits
are the trunk's first parents. Their key sets differ, so the steps for 7, 8
and 9 accept both spellings.

| Schema | Written by | What changed |
| --- | --- | --- |
| 7 | master `990a60f5b` (#611), every appliance | Monitor gate by name (`mode`) beside `enabled`. Tracks carry `lengthPresetBars` and `oneShot`; the session carries `oneShotChannels` and one `masterChain`. Tempo, signature, grid, click and count-in are saved but master never re-applied them on load. Rec dub, auto record, sync, default length and record timing are global settings, not in the file. |
| 7 (slices) | `7a8c7c3bd`..`f628c7412` | Same number, extra optional keys: session `recordTiming`, `overdubDecay`, `defaultOnce`, `onceOverrides`, `lengthPresetOverrides`, `defaultLengthPresetBars`; track `pan`, `recordTiming`, `overdubDecay`; lane `pan`, `balance`; `inputSetup`, `outputSetup`. |
| 8 (slices) | `919e337d2` (slice 3e) | Adds `allTracksChain`. `masterChain` is now output bus 0's chain. |
| 9 (slices) | `30b38ea69` (slice 3f) | `outputChains` (one per destination) replaces `masterChain`, which it drops. |
| 8 | `9264ccd9f`..`a0a54e57e` | Track settings become session maps (`trackRecordTimingOverrides`, `trackOverdubDecayOverrides`, `trackOneShotOverrides`, `trackLengthPresetOverrides`, `defaultOneShot`, `defaultLengthPresetBars`, `loopBars`); `syncTempo`, `recDub`, `autoRecord`, `defaultMultiple` become session settings; `oneShotChannels` and the per-track keys go. Monitors keep only `mode`; `undoCount`/`redoCount` become required. Adds `trackPans`, lane `pan`/`balance`, `inputSetup`, `outputSetup`, `laneInputs`/`laneOutputs`/`laneCounts`. `masterChain` is output bus 0's chain. |
| 9 | `a52fe34d4`..`623a5a7ba` | `allTracksChain` (required), `trackLevels`; `0d601db8e` replaces `masterChain` with `outputChains`; `623a5a7ba` caps monitor `volume` at 1. |
| 10 | `a921bd9a9` | `defaultFadeDurationMs`, `trackFadeDurationOverrides`. |
| 11 | `19a6faa8d` | Required per-track `fadeAmount`. |
| 12 (in flight) | Peel P2, #1164, PR #1194 | Per-lane `history` entries with kinds. |
| 13 (in flight) | Reverse P2, #1162 | Required per-track `reversed`. |

## Design

- `sessionMigrationSteps` maps each schema to one step, `vN → vN+1`, over the
  decoded manifest. `decodeSessionManifest` runs the steps from the bundle's
  schema up to `Session.formatVersion`, then the strict decoder. A test fails
  when any schema from 7 to the current one lacks its step.
- `SessionRepository.open` reads, converts in memory and validates; it writes
  nothing. `read` is `open` without the player's settings.
- `SessionCubit.loadNamed` opens with the player's current settings
  (`SessionSettingsCoordinator.current`). After the rig applies, it calls
  `commitConversion`: the original manifest is kept byte for byte as
  `session.v<N>.json` (no bundle file uses that name; an existing backup with
  other bytes moves the new one to `session.v<N>.2.json`, and a backup with the
  same bytes is reused), then the converted manifest replaces `session.json`
  through a temporary file and a rename. The conversion notes go to the log.
- The load succeeds with `SessionState.convertedFrom` set, and the existing
  session notice says the session was converted and the original kept.
- A newer schema is refused as before (`SessionUnsupportedVersion`). A schema
  older than 7, or one a step or the strict decoder refuses, is refused with
  `SessionUnconvertible` and its own message. Every refusal happens before
  anything is written.
- `save` keeps an older-schema manifest as its backup before overwriting it,
  so the original survives even when the write-back after loading failed.
- The backup holds the manifest only. Audio files are shared with the
  converted session rather than copied, which would double a bundle's size on
  the appliance.

## Defaults and decisions

Rule numbers are the owner rules (1 preserve existing behaviour, 2 fail safe,
3 no silent change, 4 consolidate, 5 drop uncertain state with a notice).

| Field (first schema) | Value for an older session | Why |
| --- | --- | --- |
| `syncTempo`, `recDub`, `autoRecord`, `defaultMultiple`, `recordTiming`, `trackRecordTimingOverrides` (8) | The player's live value at open | Master kept these as global settings and opening a session never changed them (rule 1). A file that saved them (slices, trunk) keeps its value. |
| Tempo, signature, `quantizeDiv`, click, count-in, looper mode, crown (≤7) | As saved | The file's own data. Master saved them without re-applying them; the trunk applies them, and the notice tells the player the session was converted (rule 3). |
| `trackOneShotOverrides` (8) | `oneShotChannels` and per-track `oneShot` as `true` entries | Master reset every other track to Loop on load, which `defaultOneShot: false` reproduces. |
| `trackLengthPresetOverrides` (8) | Per-track `lengthPresetBars` above 0 | Master reset every other track to Auto (`defaultLengthPresetBars: 0`). |
| `loopBars` (8) | 0 | Master committed loops with no bar count. |
| `overdubDecay`, `trackOverdubDecayOverrides` (8) | 0, none | Decay did not exist; 0 keeps every layer whole. |
| Monitor `mode` (7) | `mode`, else `enabled ? on : off` | Master's own fallback for pre-7 monitors. |
| `masterChain` in a 7 file | `allTracksChain` | Master's insert ran on the summed tracks before live monitoring joined, which is the All tracks stage. An output chain would also colour live monitoring. Difference: master processed only the first enabled output pair; All tracks processes each destination's recorded mix. Identical for a rig whose tracks use one pair. |
| `masterChain` in an 8 or 9 file | Output bus 0's chain | From slice 3b on, the Master insert was bus 0's chain. The slice-9 author dropped it; keeping it on bus 0 preserves the sound (rule 1). A file that also has a bus 0 chain cannot be converted (rule 2). |
| `allTracksChain` (8/9), `outputChains` (9) | Empty | No such stage before. |
| `trackLevels`, `trackPans`, `inputSetup`, `outputSetup`, lane `pan`/`balance`, lane routing maps | Unity, centre, empty | Did not exist on master; the empty values reproduce how the takes were recorded and heard. They are not taken from the live device, because they describe the recording, not a preference. |
| Monitor `volume` above 1 (cap from 9) | 1, noted | The live-input ceiling is unity by accepted design (#1124). Lowering one live monitor is safer than refusing the session (rule 2), and it is noted. |
| `defaultFadeDurationMs`, `trackFadeDurationOverrides` (10) | 4000, none | Fade did not exist; the current default. |
| `fadeAmount` (11) | 1 | An unfaded track. |
| `pedalBindings` | Unchanged | The blob format did not change. A binding on the retired Master stage stays in the set, unresolved, and the assignment screen offers rebind (existing R25 behaviour), so it is not silent. |
| Undo/redo layers | Unchanged | Same layout through schema 11. |
| Schema 6 and older | Refused (`SessionUnconvertible`) | Out of the owner's decision; see open question. |

Every filled, moved or changed field is recorded in the conversion notes.

## Fixtures

`packages/session_repository/test/fixtures/sessions/` holds bundles written by
each schema's own code; `fixtures/generators/` holds the generator each one
ran, with the commit in its name.

- `v7_master_full`, `v7_master_empty`: master `bedcecf27`, its native engine,
  `LooperRepository`, `chainsFromLooper`, `SessionRepository.save` and
  `PedalBindingSet.encode`. Three tracks, two lanes, undo and redo layers, a
  muted and a turned-down lane, lane, track, Master and monitor chains, an
  auto monitor at 150%, tempo 100 in 3/4, bar grid, click, count-in, Sync
  mode, Once channels, two pedal bindings (one on the Master stage).
- `v8_slices_be987759d`, `v9_slices_95dcea0d8`, `v8_trunk_a0a54e57e`,
  `v9_trunk_623a5a7ba`, `v10_trunk_a921bd9a9`, `v11_trunk_5c163d11f`: each
  commit's `SessionRepository.save` over its own fake engine, with the chain
  and binding strings master encoded.

Tests open every fixture and check its values, apply the converted schema-7
bundle to the native engine, check backup, write-back and byte-identical
refusals, and check the notice and banners.

## Adding a schema bump

Add the step to `sessionMigrationSteps` and a fixture from the bumping commit
to the lists in `session_migration_test.dart` and `session_conversion_test.dart`.
The coverage test fails until the step exists.

- Peel P2 (12): history kinds default to `layer`, the kind the schema-11
  rebuild gave every entry (`le_hist_layer`).
- Reverse P2 (13): `reversed: false`.

## Library (#1178)

The Library branches are not on the trunk yet. Their lenient summary lists a
schema-7 bundle normally (name, tracks, tempo, signature), though its effect
count misses `masterChain`. `readPreview` and the rename path call
`Session.fromJson` directly and would refuse a schema-7 bundle; they should
call `decodeSessionManifest` instead.

## Open question for the owner

Bundles saved before master reached schema 7 (before #611, 2026-08-10) opened
on master and are refused here. Convert them too, or leave them refused?

## Design write-back

No new surface. The unconvertible refusal reuses the `session-version-error`
banner and the session notice with new text.
