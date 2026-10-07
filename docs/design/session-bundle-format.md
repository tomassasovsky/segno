# Session bundle format (`.segno`)

<!-- cspell:ignore retime retimed retimes -->

A saved session is a directory (a `.segno` **bundle**) holding a JSON manifest,
one WAV per audio layer, and a flattened mixdown. This document describes the
current **v14** schema. Decode accepts the current schema only (see
[Versioning](#versioning)).

Related: the performance-capture path stores retiring layers with its own
numbered files + sidecar (see [performance-manifest-format](performance-manifest-format.md)
and [performance-event-log-format](performance-event-log-format.md)); the session
bundle reuses the *shape* (numbered per-lane layer WAVs) but is written
synchronously on the control thread, not streamed from a live capture.

## Layout

```
sessions/
  <id>/                   # an Unfiled bundle; the directory name is the session's identity
    session.json          # the manifest (source of truth)
    mixdown.wav           # flattened preview: every unmuted lane's live buffer summed
    track0_lane0_L0.wav   # per (track, lane, layer-ordinal) mono 32-bit-float WAV
    track0_lane0_L1.wav
    track0_lane0_L2.wav
    track0_lane1_L0.wav
    track1_lane0_L0.wav
    ...
  <folder>/               # a directory with no manifest: one level of folders
    <id>/                 # a filed bundle, same shape
```

The **manifest is the only source of truth** inside a bundle. WAV files are
opaque and named purely by index (`track{channel}_lane{lane}_L{ordinal}.wav`);
a file the manifest does not reference is ignored on load and pruned on the
next save.

**Identity and name.** A bundle's directory name is its id for its whole life
(`s-YYYYMMDD-HHMMSS` for bundles the Library creates; older bundles keep the
slug they were saved under). The display name is the manifest's optional
`name`; absent, the catalog shows the id. Rename rewrites `name` and nothing
else, through `session.json.tmp` renamed over `session.json`, so the manifest
is never half-written. Display names collide case-sensitively, as directory
names always did on the appliance. A new id is reserved by creating its
directory, and is skipped while any directory at the root or one level down
has that name. The schema version did not change for `name`: a bundle
without it reads exactly as before, and a bundle with it reads on older
builds, which ignore unknown keys.

**Folders.** A directory under `sessions/` with no manifest is a folder, one
level deep; bundles directly under the root are "Unfiled". Moving a bundle is
a directory rename. A manifest-less directory that holds layer WAVs or a
`mixdown.wav` is an interrupted save, not a folder: the catalog lists it
nowhere and leaves it alone, and a folder holding one cannot be deleted.

**Saving over a bundle.** A save never edits an existing bundle in place.
It writes the whole new bundle beside it as `<id>.saving`, then renames the
old one to `<id>.old`, the new one to `<id>`, and deletes `<id>.old`. A
failure before the renames leaves the previous save untouched. The catalog
lists neither suffix, and on its next read it undoes a swap a power cut
interrupted (`<id>.old` without `<id>` is put back) and removes leftovers.
The stage is registered before it is created, so a catalog read during a
save never takes it for a leftover. A failed second rename puts `<id>.old`
back at once. The parent directory is flushed (`fsync`) after the renames,
so a save is durable when it reports success. The swap relies on a
journaling filesystem that commits renames in order (ext4, the appliance's
`/data`): keep the sessions root off FAT, where a cut between the two
directory entries of a rename can leave `<id>` and `<id>.old` sharing their
files.

**Mixdown.** `mixdown.wav` is written when the saved mix has any audible
content and deleted when it has none (every track empty or muted), so a
re-save of an emptied rig never leaves audio the session no longer holds.

## Layers, ordinals, and undo/redo

A track's undo history is not a set of deltas — each overdub pass snapshots the
**whole loop** before it writes, so a lane's complete state is an ordered list of
full-length buffers. A save persists every one:

```
ordinal:   0 .. undoCount-1     undoCount        undoCount+1 ..
buffer:    undo snapshots       live (playing)   redo snapshots (newest last)
```

- Since schema 12 (#1164) each lane also stores `history`: the track's
  `undoCount + redoCount` entries in the same order (undo oldest first, then
  redo newest-adjacent first), each `{ "kind": …, "skipped": n }`. Kinds are
  `layer` (an overdub pass), `processed` (a loop-close restoration's raw take),
  `peel` and `clear` (a Clear restore point, redo side only; Redo re-clears).
  `skipped` is nonzero only on a `peel` entry.
- A `peel` entry on the undo side holds the image the Peel removed; on the redo
  side it is a **marker without an image**. So
  `layers.length == undoCount + 1 + (redo entries that are not peel)`, and
  `liveIndex == undoCount`.
- The ordering is the linear timeline oldest→newest, matching the engine's
  `le_engine_export_history` / `le_engine_export_layer` walk
  (`undo_stack[0..) → a_live → redo stack`, newest-adjacent first, markers
  skipped). On load, `le_engine_import_layer` + `le_engine_finalize_history`
  rebuild the pool and both stacks with their kinds, so Undo, Redo and Peel
  behave exactly as they did before the save.
- Decode is strict and mirrors `le_engine_finalize_history`
  (`TrackHistory.malformation`). The read fails with `SessionCorruptLayers`
  before any audio is decoded when:
  - `redoCount` disagrees with the entries and `undoCount`, or `undoCount` lies
    outside them;
  - lanes of one track carry different histories;
  - a `clear` is anywhere but the last (deepest redo) entry;
  - `skipped` is negative, 256 or more, or set on a kind other than `peel`;
  - an undo-side `peel` skipped more `peel` entries than sit directly beneath
    it, unless that run reaches the bottom of the stack (pool eviction removes
    the oldest entries, and Undo clamps its re-insertion there);
  - a redo-side `peel` marker would find no `layer` to peel when Redo reaches
    it (the check walks the redo side as Redo would);
  - the layer count does not match the history, or exceeds 256.
- The history is **track-wide** (the stacks are shared across lanes in
  lockstep), so every lane of a track carries the same layer count.
- Capacity: a track cannot exceed `LE_POOL_SLOTS` (256) images; the engine
  rejects an over-cap import.

## The FX stages

The manifest persists every stage of the FX signal path (#351, slices 3e and
3f), in signal order:

| Stage | Manifest field | Keyed by | Notes |
|---|---|---|---|
| **Input** | `monitors[].encoded` | hardware input | The live-monitor chain, pre-record. Rides the monitor record that also carries its routing/mix. |
| **Loop** | `laneChains[]` | `(channel, lane)` | A lane's record-route chain. |
| **Track** | `trackChains[]` | track channel | The per-track stereo-bus insert, downstream of that track's lanes. |
| **All tracks** | `allTracksChain` | — | The recorded-mix chain after every track's own chain (v8). A bare string; `""` when the session defines none. |
| **Output** | `outputChains[]` | output destination (`bus`) | One chain per destination after its own sum (v9, replacing v5's single `masterChain`). |

The Input and Loop fields keep the key names v2 gave them (`monitors`,
`laneChains`); renaming them to match the stage vocabulary would be churn with
no compatibility payoff.

Every chain, at every stage, is stored as **one opaque encoded string**, so
this data package never depends on the effect model. It is the same string
settings persist, which is what makes a chain round-trip byte-for-byte between
the two.

## Chain envelope

The string's content is the looper domain's chain **envelope** (`encodeFxChain`
in `looper_repository`, decoded by `decodeFxChain`). Only the app-side mapper
(`lib/session/session_mapping.dart`) and `looper_repository` ever look inside
it; `session_repository` treats it as an opaque blob.

```jsonc
{
  "chainEnabled": true,          // the whole chain engaged? (R15)
  "meta": { "inheritedFrom": [0, 1] },   // Loop stage only; omitted when never inherited
  "entries": [
    { "type": 3, "params": [0.35, 0.35, 0.35, 0.0], "slotId": "3f2a91c7-4" },
    { "type": 3, "params": [0.5, 0.2, 0.1, 0.0], "enabled": false, "slotId": "3f2a91c7-5" }
  ]
}
```

- `chainEnabled` — the per-chain bypass. A disabled chain renders dry while
  every per-entry flag stays intact.
- `meta.inheritedFrom` — the hardware inputs whose monitor chains were
  snapshot-copied onto this lane at record time, in input order (A8). Present
  on Loop-stage chains only; omitted entirely when a chain was never inherited.
- `entries[]` — the engine's own entries array, embedded verbatim, so the entry
  wire format has exactly one definition. Per entry:
  - `enabled` — written **only when `false`** (absent = audible).
  - `slotId` — the entry's stable per-slot identity (A9), minted once by the
    repository's chain write boundary and never reused within a session. Pedal
    bindings and expression mappings address slots by this id.

Both omissions matter for migration: a pre-FX-v3 chain string is a **bare
entries array** (no envelope object at all), and `decodeFxChain` accepts it as
`chainEnabled: true`, no meta, every entry `enabled: true`, every `slotId`
null — "migration defaults every level to enabled" (R15).

Note what is *not* here: there are no per-flag manifest fields, and no per-flag
settings keys either. Every enable bit and every slot id lives inside the one
string per chain.

## Manifest schema (v14)

```jsonc
{
  "version": 14,
  "sampleRate": 48000,
  "channels": 1,
  "baseLengthFrames": 96000,
  "tracks": [
    {
      "channel": 0,
      "multiple": 1,
      "lengthFrames": 96000,
      "fadeAmount": 1.0,            // v11: the stationary Fade level, 0..1
      "reversed": false,            // v13: plays reversed (#1162)
      "spanFrames": 0,              // v14: see "Recorded tempo" below
      "lanes": [
        {
          "lane": 0,
          "volume": 0.8,
          "muted": false,
          "outputMask": 3,
          "inputChannel": 0,
          "layers": [
            { "file": "track0_lane0_L0.wav" },
            { "file": "track0_lane0_L1.wav" },
            { "file": "track0_lane0_L2.wav" }
          ],
          // "pan" and "balance" are written only off their defaults (0, 1).
          "history": [                // v12: one entry per undo/redo step
            { "kind": "layer", "skipped": 0 },
            { "kind": "layer", "skipped": 0 }
          ],
          "undoCount": 1,
          "redoCount": 1
        }
      ]
    }
  ],

  // --- FX: each chain an opaque envelope string ---
  "laneChains": [                   // Loop stage
    { "channel": 0, "lane": 0, "encoded": "{…}" }
  ],
  "monitors": [                     // Input stage (+ routing/mix)
    { "input": 0, "mode": "auto", "outputMask": 3, "volume": 1.0, "muted": false, "encoded": "{…}" }
  ],
  "trackChains": [                  // Track stage
    { "channel": 0, "encoded": "{…}" }
  ],
  "outputChains": [                 // v9: one chain per output destination
    { "bus": 0, "encoded": "{…}" }
  ],
  "allTracksChain": "{…}",          // v8: the recorded-mix chain; "" = none

  // --- tempo grid, timing, click, count-in ---
  "tempoBpm": 0.0,
  "tempoSource": "none",
  "tsNum": 4,
  "tsDen": 4,
  "quantizeDiv": "off",
  "loopBars": 0,
  "recordTiming": "immediately",
  "overdubDecay": 0,
  "clickMode": "off",
  "clickOutputMask": 0,
  "clickVolume": 1.0,
  "countInBars": 0,

  // --- looper mode, crown, per-track settings ---
  "looperMode": "multi",
  "primaryTrack": -1,
  "defaultOneShot": false,
  "defaultLengthPresetBars": 0,
  "defaultFadeDurationMs": 4000,    // v10
  "trackFadeDurationOverrides": {}, // v10
  "trackRecordTimingOverrides": {},
  "trackOverdubDecayOverrides": {},
  "trackOneShotOverrides": {},
  "trackLengthPresetOverrides": {},
  // "trackPans", "trackLevels", "laneInputs", "laneOutputs", "laneCounts",
  // "inputSetup" and "outputSetup" are written only when non-empty.
  "syncTempo": false,
  "recDub": false,
  "autoRecord": false,
  "defaultMultiple": 1,
  "pedalBindings": "{…}",           // opaque, app-side model; "" = the global remap

  // --- v14: Audio & tempo (#1179) ---
  "recordedTempoBpm": 0.0,          // 0 with recordedLengthFrames 0: no retime
  "recordedLengthFrames": 0,
  "defaultFollowTempo": true,
  "trackFollowTempoOverrides": {},  // channel -> bool
  "defaultPitchMode": "unchanged",  // or "followsSpeed"
  "trackPitchModeOverrides": {}     // channel -> mode name
}
```

### Recorded tempo and spans (v14)

With Follow tempo on, a song-tempo change retimes the recorded takes: the
master moves to the bar count at the new tempo while every take keeps its
audio, read at its length over the span it plays across. A saved rig whose
master was retimed records the tempo the takes were laid down at and the
master length it measured (`recordedTempoBpm`, `recordedLengthFrames`; both 0
otherwise). A take laid down against another master (after a retime) saves
that master's length as its `spanFrames`; a take on the recorded master saves
0. Recall restores the recorded tempo, imports each take with its span
(`le_engine_import_span`), commits on the recorded master, and then sets the
session tempo, which retimes from the recorded pair to exactly
`baseLengthFrames` with every take at the ratio it had. `baseLengthFrames` is
always the master as saved, so readers that ignore these fields still see the
song's own length.

Audio never appears in the manifest; it lives in the referenced WAVs.

Chains exist **independently of audio**: a `laneChains`/`trackChains` entry may
name a channel or lane with no `tracks` entry at all, and it still loads. The
same holds in reverse for state that has no audio to hang on —
`oneShotChannels` is session-level precisely so a flag armed on an empty
channel survives a save.

## Versioning

Writing is always the current version (v14). `Session.fromJson` accepts the
current version only: any other `version` fails with
`SessionUnsupportedVersion`, and a non-integer `version` with a
`FormatException`. Inside the current schema, fields that `toJson` omits at
their defaults (`pan`, `balance`, the optional maps) read as those defaults.

Opening a bundle goes through `decodeSessionManifest` (#1196,
`session_migration.dart`). A manifest from v1 to v13 is converted in memory,
one step per schema bump, and must then pass the strict decoder; a newer one
fails with `SessionUnsupportedVersion` and one that cannot be converted with
`SessionUnconvertible`, leaving the bundle untouched. Once the converted
session has loaded, the original manifest is kept byte for byte as
`session.v<N>.json` beside the converted `session.json`, sharing the audio.
The next save moves it, with the layer files it names, into a `session.v<N>/`
folder inside the bundle, which opens as a bundle of its own. The plan
(`docs/plan/2026-10-06-fix-session-schema-migration-plan.md`) lists what each
step fills in.

### Historical: presence-keyed decode (v1 to v9)

Until v10, `Session.fromJson` was **presence-keyed**: it branched on which
fields existed, not on a version `switch`. That decoder is gone; the table
records what each rung added, and the conversion steps read them.

| Bundle | Detected by | Loaded as |
|--------|-------------|-----------|
| **v1** | no `laneChains` / `monitors`, `stem` per track | one lane-0 live layer, empty chains |
| **v2** | `laneChains` / `monitors` present, `stem` per track | one lane-0 live layer + chains |
| **v3** | `lanes` per track | full multi-lane, multi-layer |
| **v4** | tempo-grid / click / count-in / B5c fields present | + tempo grid, mode, crown, One Shot |
| **v5** | `trackChains` / `masterChain` present, envelope chain strings | + the two bus stages, per-chain + per-slot enable, slot ids, inheritance provenance |
| **v6** | `pedalBindings` present | + this session's pedal remap |
| **v7** | `monitors[].mode` present | + the monitor gate's third state (`auto`) survives a reload |

A legacy `stem` migrated to a single `SessionLane`(lane 0) holding one live
`SessionLayer`, with the old track-level `volume`/`muted` mapped onto lane 0 and
`inputChannel = -1` (unbound). Every field a newer rung added defaulted to the
value that reproduced the older behavior exactly: grid-off for the tempo
fields, `multi`/no-crown for B5c, for v5 **both bus stages empty and every
enable flag true**, for v6 an empty remap (the global one applies), and for v7
the gate the boolean already said — `on` when it was true, never `auto`, since
`on` is what the bundle was heard as.

### Chain invariants

Three properties are pinned by tests, because a regression in any of them is
silent (1 and 2 date from the v5 chain migration and still hold for the chain
envelope):

1. **A v4 load is fingerprint-identical.** `fxChainFingerprint` folds params
   plus the real enable bits and deliberately excludes `slotId`, so a v4
   chain — whose entries decode `enabled: true` and whose ids are minted fresh
   — produces the same fingerprint as it did before the migration. The engine's
   published fingerprint and the repository cache still agree after a load.
2. **Save → load → save is byte-idempotent.** Slot ids are minted **exactly
   once**, at the repository write boundary that first sees an id-less entry,
   and then persisted. A build that re-minted per load would keep the
   fingerprint identical (see 1) while quietly dangling every stored pedal
   binding — only the idempotence test catches that.
3. **A stage the manifest does not define is reset, never inherited.** Loading
   a session resets every remembered chain and chain-enabled flag of all four
   stages that the loaded rig leaves undefined, in the engine *and* the
   repository caches, so a previous session's leftovers can never sound under
   the loaded one (R17). Since v9 the output stage is one chain per
   destination (`outputChains`), and a destination the manifest does not name
   is reset the same way.

## History

- **v1** — transport + one mono stem per track.
- **v2** — added per-lane and per-monitor effect chains.
- **v3** — per-lane audio (multi-lane) and per-lane overdub-layer stacks with
  undo/redo restore. Shipped as the session overdub-fidelity initiative
  (parts 1–4).
- **v4** — the Phase-A tempo grid (`tempoBpm`, `tempoSource`, `tsNum`, `tsDen`,
  `quantizeDiv`), the click (`clickMode`, `clickOutputMask`, `clickVolume`),
  count-in (`countInBars`), and B5c's looper mode / crowned primary track /
  One Shot (`looperMode`, `primaryTrack`, `oneShotChannels`, per-track
  `oneShot`, per-track `lengthPresetBars`). Shipped as the tempo-aware
  looper-modes initiative; every field defaults to the tempo-free, grid-off
  value, so a v3 bundle loads as "Multi, grid off".
- **v5** — the four-stage FX model (#351): the Track-stage (`trackChains`) and
  Master (`masterChain`) inserts, and the chain envelope for every stage —
  per-chain `chainEnabled`, per-entry `enabled`, stable `slotId`s, and Loop-stage
  inheritance provenance. A v4 bundle loads with both bus stages empty and
  everything enabled.
- **v6** — this session's pedal remap (`pedalBindings`), one opaque string on
  the same rule as the chains: the model lives app-side, the manifest only
  carries the blob. A v5 bundle loads with `""`, and the global remap applies.
- **v7** — the monitor gate by name (`monitors[].mode`), beside the boolean
  every rung has carried. The gate has three states — `off`, `auto` (follow
  the record arm) and `on` — and a boolean cannot tell the last two apart, so
  a session saved with an input on `auto` used to reload monitoring
  unconditionally. A v6 bundle loads with what its boolean said: `on` when it
  was true, never `auto`, since `on` is what that bundle was heard as.
- **v8** — the All tracks recorded-mix chain (`allTracksChain`, slice 3e).
- **v9** — one output chain per destination (`outputChains`, slice 3f),
  replacing the single `masterChain`, which v9 no longer reads.
- **v10** — Fade durations (`defaultFadeDurationMs`,
  `trackFadeDurationOverrides`). From here decode accepts the current schema
  only.
- **v11** — each track's stationary Fade level (`tracks[].fadeAmount`).
- **v12** — the audio history's kinds (`lanes[].history`, #1164), so a Peel, a
  loop-close restoration and a Clear restore point survive save and recall
  with the same Undo, Redo and Peel behavior. `undoCount` and `redoCount`
  count entries, and `layers` holds one image per entry except a redo-side
  Peel marker, plus the live image.
- **v13** — each track's playback direction (`tracks[].reversed`, #1162). A
  v12 bundle loads forward, as it always recalled.
- **v14** — Audio & tempo (#1179): the recorded tempo and master length,
  each take's span, and the Follow tempo and Pitch defaults and track
  overrides. A v13 bundle could not have been retimed, so it loads with no
  recorded pair and no spans; Follow tempo and Pitch were the player's global
  preferences until then, so the conversion takes the live ones (rule 1, the
  schema-8 precedent). The number is this branch's next free one: on the
  trunk after Multiply/Divide and the backing player it lands as v16, its
  conversion step keyed by 15.
