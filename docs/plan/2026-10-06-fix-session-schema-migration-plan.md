# Convert saved sessions from older schemas on open

Tracking: #1196, `autonomy:merge-gate`. Owner decisions, 2026-10-06:

- Sessions saved by the shipped app (schema 7, on master and on the
  appliances) must keep opening after the trunk lands.
- The oldest sessions convert too, back to schema 1. Use conservative
  defaults: no FX chains, and a tempo derived from the loop length where none
  was saved. Keep the original as a backup and show the same notice.

This is a deliberate, owner-made exception to the AGENTS.md rule against
migrations. It is kept to one module
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
| 1 | `8547affe7` | Tracks with one `stem` WAV, `volume`, `muted`. Saved and re-applied `tempoBpm`, `syncLoopToTempo`, `quantizeMode` (`off`/`beat`/`bar`), `metronomeOn`, `countInEnabled` (one bar). |
| 2 | `93f2f0cb5` (#112) | Drops the transport keys; adds `laneChains` and `monitors` (with `enabled`), chains as bare arrays. |
| 3 | `319a7dc9d` (#151) | `lanes` with ordered `layers` and undo/redo counts replace `stem`. |
| 4 | `7e2515802`, `fb8d7cc2b` (#280, #295) | Tempo grid, click, count-in; per-track `lengthPresetBars` and `oneShot`; `looperMode`, `primaryTrack`, `oneShotChannels`. |
| 5 | `b52c3d276` (#388) | `trackChains`, `masterChain`; chains become envelopes. |
| 6 | `4dc33ac10` (#412) | `pedalBindings`. |
| 7 | master `990a60f5b` (#611), every appliance | Monitor gate by name (`mode`) beside `enabled`. Master saved tempo, grid, click and count-in but never re-applied them on load. Rec dub, auto record, sync, default length and record timing were global settings, not in the file. |
| 7 (slices) | `7a8c7c3bd`..`7a29dda18` | Same number with extra optional keys: `recordTiming`, `overdubDecay`, `defaultOnce`, `onceOverrides`, `lengthPresetOverrides`, `defaultLengthPresetBars`; track `pan`, `recordTiming`, `overdubDecay`; lane `pan`/`balance`; `inputSetup`, `outputSetup`. From slice 3b (`f628c7412`) `masterChain` already meant output bus 0's chain; see the limitation below. |
| 8 (slices) | `919e337d2` | Adds `allTracksChain`. `masterChain` is output bus 0's chain. |
| 9 (slices) | `30b38ea69` | `outputChains` replaces `masterChain`, which it drops. |
| 8 | `9264ccd9f`..`a0a54e57e` | Track settings become session maps; `syncTempo`, `recDub`, `autoRecord`, `defaultMultiple` become session settings; monitors keep only `mode`; undo/redo counts required; track pans, lane routing, input and output setup. `masterChain` is output bus 0's chain. |
| 9 | `a52fe34d4`..`623a5a7ba` | `allTracksChain` required, `trackLevels`; `0d601db8e` replaces `masterChain` with `outputChains`; `623a5a7ba` caps monitor volume at 1. |
| 10 | `a921bd9a9` | Fade durations. |
| 11 | `19a6faa8d` | Required per-track `fadeAmount`. |
| 12 | Peel P2 (#1164, PR #1194) | Per-lane `history` entries with kinds. |
| 13 (in flight) | Reverse P2, #1162 | Required per-track `reversed`. |

## Design

- `sessionMigrationSteps` maps each schema from 1 to one step, `vN → vN+1`,
  over the decoded manifest. `decodeSessionManifest` runs the steps from the
  bundle's schema up to `Session.formatVersion`, then the strict decoder. A
  test fails when any schema lacks its step.
- `SessionRepository.open` reads, converts in memory and validates; it writes
  nothing. `read`, the Library preview and the stems export decode through the
  same conversion without the player's settings.
- `SessionCubit.open` opens with the player's current settings
  (`SessionSettingsCoordinator.current`). After the rig applies it calls
  `commitConversion`: the original manifest is kept byte for byte as
  `session.v<N>.json` (an existing backup with other bytes moves the new one
  to `session.v<N>.2.json`, one with the same bytes is reused), then the
  converted manifest replaces `session.json` through `session.json.tmp` and a
  rename. A failed write deletes the temporary file.
- Until the next save the backup shares the audio with the converted session,
  so putting it back as `session.json` restores the original. The next save
  (which writes a whole new bundle and swaps it in) moves the backup manifest
  and the layer files it names out of the previous bundle into a
  `session.v<N>/` folder in the new one, which opens as a bundle of its own.
  Later saves move that folder along. The move happens after the swap; until
  it finishes the previous bundle is kept as `<id>.old`, and the catalog's
  recovery finishes the move before deleting it. The folder is assembled
  inside `<id>.old` (layer files first, the manifest last) and then renamed
  into the new bundle in one step, so a power cut never splits a backup: a
  folder without its manifest is an unfinished assembly, and the next run
  reuses it. A save over a bundle whose
  write-back failed does the same with its own older manifest. A failed save
  leaves the previous bundle, original included, as it was.
- The notice says the session was converted and the original kept, or, when
  the write-back failed, that the original file is unchanged. It adds a
  sentence for each audible change: the Master effects (and their pedals) now
  on All tracks, a live input lowered to 100%, and a tempo set from the loop
  length for a session that saved none. The notice only claims the backup
  when `commitConversion` reports that it wrote it. The conversion notes go to
  the log.
- A newer schema is refused as before (`SessionUnsupportedVersion`). A
  manifest older than schema 1, or one a step or the strict decoder refuses,
  is refused with `SessionUnconvertible` and its own message, in the session
  notice, the Library preview and the Library's refusal banner. Every refusal
  happens before anything is written.

## Defaults and decisions

Rule numbers are the owner rules (1 preserve existing behaviour, 2 fail safe,
3 no silent change, 4 consolidate, 5 drop uncertain state with a notice).

| Field (first schema) | Value for an older session | Why |
| --- | --- | --- |
| Schema 1 `tempoBpm`, `syncLoopToTempo`, `quantizeMode`, `metronomeOn`, `countInEnabled` | Manual tempo in 4/4 (when 30–300), `syncTempo`, record timing and grid `off`→immediately/off, `beat`→quarter, `bar`→bar, click while playing or recording, one-bar count-in | Schema 1 saved and re-applied them. |
| Stem (1–2) | Lane 0: the track's level and mute, both outputs, no input, one live layer | Master's own reading of these tracks. |
| Lane and monitor chains (2), Track and Master chains (5) | Empty | No FX chains where none were saved. Bare-array chains of 2–4 are kept; the current decoder reads them. |
| Tempo (4) where none was saved (2, 3, or 1 out of range) | Derived from the base loop as the engine does with loop sync: whole 4/4 bars, the tempo nearest 120 within 30–300 (`le_grid_derive_bpm`), `derived`, `loopBars` = those bars; none without a loop | Owner decision. |
| Grid, click, count-in, looper mode, crown (4) | Off, multi, no crown | Master's reading of pre-4 bundles. |
| `pedalBindings` (6) | Empty | The global remap applies, as on master. |
| `syncTempo`, `recDub`, `autoRecord`, `defaultMultiple`, `recordTiming` (8) | The player's live value at open | Master kept these as global settings and opening a session never changed them (rule 1). A file that saved them keeps its value. |
| `trackRecordTimingOverrides` (8) | Empty | Per-track timing did not exist before (slices aside); every track followed the global setting. Live values would carry the previous session's choices across. |
| Tempo, signature, grid, click, count-in, looper mode, crown (4–7) | As saved | The file's own data. Master saved them without re-applying them; the trunk applies them, and the notice says the session was converted (rule 3). |
| `trackOneShotOverrides`, `trackLengthPresetOverrides` (8) | From `oneShotChannels` and per-track `oneShot`, and presets above 0 | Master reset every other track to Loop and Auto. |
| `loopBars` (8) | 0 unless derived above | Master committed loops with no bar count. |
| `overdubDecay` (8) | 0, none | Decay did not exist. |
| Monitor `mode` (7) | `mode`, else `enabled ? on : off` | Master's own fallback. |
| `masterChain` in a schema 5–7 file | `allTracksChain`, and Master-stage pedal bindings retargeted to All tracks (slot kept); told in the notice | Master's insert ran on the summed tracks before live monitoring joined. Difference: master processed only the first enabled output pair, All tracks every destination's recorded mix. Identical when tracks use one pair. |
| `masterChain` in a schema 8 or 9 file | Output bus 0's chain, and its pedal bindings to output 0 | From slice 3b the Master insert was bus 0's chain. A file that also has a bus 0 chain cannot be converted (rule 2). |
| `allTracksChain` (8/9), `outputChains` (9) | Empty | No such stage before. |
| `trackLevels`, `trackPans`, `inputSetup`, `outputSetup`, lane `pan`/`balance`, lane routing maps | Unity, centre, empty | They reproduce how the takes were recorded and heard. |
| Monitor `volume` above 1 (cap from 9) | 1, noted, told in the notice | Unity is the live-input ceiling (#1124); lowering is safer than refusing (rule 2). |
| Fade durations (10), `fadeAmount` (11) | 4000 ms and none; 1 | Fade did not exist. |
| Lane `history` (12) | One `layer` entry per undo and redo entry | Schema 11's recall filed every entry as `LE_HIST_LAYER`; images and counts are unchanged. |
| A Master binding in a schema 10 or 11 file | Unchanged | It was already inert as written; making it live would change the session. |

Every filled, moved or changed field is recorded in the conversion notes.

**Known limitation.** A slice-era schema-7 file written between slice 3b
(`f628c7412`) and the slices' own bump (`919e337d2`) stored output bus 0's
chain as `masterChain`. The conversion cannot tell it from master's and moves
it to All tracks, where live monitoring no longer passes through it. Such files
exist only on development machines from those two weeks.

## Fixtures

`packages/session_repository/test/fixtures/sessions/` holds bundles written by
each schema's own code; `fixtures/generators/` holds each generator, with the
commit in its name.

- `v7_master_full`, `v7_master_empty`: master `bedcecf27`, its native engine,
  `LooperRepository`, `chainsFromLooper`, `SessionRepository.save` and
  `PedalBindingSet.encode`.
- `v1_loopy_8547affe7` to `v6_loopy_4dc33ac10`, `v8_*`, `v9_*`, `v10_*`,
  `v11_*`, `v12_peel_097e1ef68`: each commit's `SessionRepository.save` over
  its own fake engine. Schemas 2–4 encode their chains with their own
  `encodeTrackEffects`; later ones carry the strings master encoded.

Tests open every fixture and check its values, apply converted 1, 2, 4 and 7
bundles to the native engine, check backup, write-back order, the backup
folder after a save, byte-identical refusals and failed saves, and the notice
and Library messages.

## Adding a schema bump

Add the step to `sessionMigrationSteps` and a fixture from the bumping commit
to the lists in `session_migration_test.dart` and `session_conversion_test.dart`.
The coverage test fails until the step exists. Reverse P2 (13) adds
`12: _v12ToV13`, setting every track's `reversed` to `false`.

## Library (#1178)

The lenient catalog row lists an older bundle normally and counts a
`masterChain` in its effects. The preview and the stems export decode through
the conversion; rename only edits `name` in the manifest and leaves the schema
as it was.

## Design write-back

No new surface. The notice adds sentences to the existing session toast; an
unconvertible session uses the existing version refusal places with its own
text.
