# Performance event log format

<!-- cspell:ignore numer -->

Part 3 of the performance-recording / DAW-export umbrella
(`docs/plan/2026-07-05-feat-performance-recording-daw-export-plan.md`). This
pins the on-disk format for `events.log`, the sample-accurate record of every
audibility-affecting change made during an armed performance-recording
session — the backbone the offline renderer (parts 7-8) and the `.als`
generator (parts 9-10) build on. It is written so a reader can parse the file
without importing engine code.

## Where it lives

`events.log` sits alongside `master.pcm`, `input-<N>.pcm`, and
`performance.json` under the capture directory passed to `le_perf_arm`
(`packages/segno_engine/src/core/perf_drain.c`). It is opened once at arm,
appended to every ~250ms drain cycle, and never truncated or rewritten —
unlike `performance.json`, which is atomically replaced each cycle.

## File layout

```
[header: 12 bytes]
[entry 0: 28 bytes]
[entry 1: 28 bytes]
...
```

### Header (12 bytes, written once)

| Offset | Size | Field         | Notes                                   |
|--------|------|---------------|------------------------------------------|
| 0      | 4    | magic         | ASCII `"PLEV"` (Perf Log EVents)          |
| 4      | 4    | version       | `uint32`, little/native-endian; `6` today — see below |
| 8      | 4    | sample_rate   | `int32`, the session's sample rate        |

#### What `version` means

The version covers the **code vocabulary** as well as the record layout, so it
moves whenever a reader's interpretation of an existing code changes — not only
when the 28-byte record does.

| Version | Meaning |
|---------|---------|
| `1`      | The original vocabulary. An **aborted** take — armed, then stopped having captured nothing — was logged as `LE_PLOG_RECORD_END`, so a version-1 capture is subject to #264: a reader that anchors on the first `RECORD_END` can place a track's settled image at the abort frame instead of at the finalize that produced it. |
| `2`      | An aborted take logs `LE_PLOG_RECORD_ABORT` (314). A `RECORD_END` in a version-2 file always means content was captured. |
| `3`      | A `RECORD_ABORT` may appear **unpaired**: a count-in cancelled by the immediate-finalize primitive (#405, `LE_CMD_FINALIZE_TAKE`) logs 314 for the counting channel even though no `RECORD_START` ever preceded it (the count-in's commit is what logs the start). In a version-2 file every 314 closes an open `START`; from 3 on, a reader must treat an ABORT with no open `START` as a no-op, not a malformed file. |
| `4`      | Two new transport facts (#262) — `LE_PLOG_PERF_ARMED` (315) recording the master loop phase at arm, and `LE_PLOG_TRANSPORT_HELD` (316) marking a mid-capture transport hold — and `LE_PLOG_RECORD_END` (301) now carries the `take` arm `{channel, take_id}` instead of a bare channel (#819). The offline renderer **requires** these: the two inferences it used before — the race-stale `armSnapshot.clockFrame` phase anchor and the "first `RECORD_END` while the channel is content-free" disarm-image proxy — were **deleted with no fallback** (AGENTS.md). A pre-4 file has neither fact, so it has no supported phase anchor and no take identity; it still parses (below), but renders correctly only if re-captured. |
| `5`      | Applied Clear restoration (322) and restored source state, phase and retirement (323), with exact capture-local image identity. |
| `6`      | Every callback-applied history image logs 322 (#1143): Clear Undo, layer Undo and Redo, and recovery from empty each stage an immutable image at admission and the callback names it at the exact frame it first mixes the slot, so a channel may carry several 322 facts per capture and a reader switches images on each (in version 5 a channel carried at most one, for Clear Undo). 323 keeps its meaning; `image_id` 0 with state EMPTY now also follows any slot that became live without a staged image (staging refused, loop-close restoration, session import), whatever the previous source was. `LE_CMD_UNDO_TO_EMPTY` (39) is logged raw at its exact apply frame next to the semantic 304: emptying is exact silence, not lost provenance. `LE_PLOG_LAYER_RETIRED`'s fourth payload field (`frames`) is reserved for the staging-gap follow-up under this same version; until it lands the writer does not define those four bytes and a reader must not interpret them. |
| `7`      | Reverse (#1162): `LE_PLOG_REVERSE` (324) carries a track's read direction as a callback fact — every accepted toggle or install logs the exact dry index the callback continues from and the equal-gain turn window it mixes the old head over; every material reset (Clear, Undo to empty, a new capture, import) logs forward with `read_index` -1; a track already reversed at `PERF_ARM` logs its direction and index at capture frame 0. The offline renderer steps a reversed segment's phase -1 per frame from the logged index and reproduces the turn; a version-6 reader has no direction and renders a reversed track forward. Peel (#1164): `LE_PLOG_PEEL` (325) is a control-side admission record for each accepted peel; the callback's 322 names the staged image it mixes. A version-7 file may contain either fact or both; a reader that does not consume them skips them as unknown codes. |
| `8`      | Speed (#1179): `LE_PLOG_SPEED` (327) carries a track's read rate as a callback fact, with the exact index the callback reads in Q32.32 — every accepted change of the global Speed logs one per track (an equal request is receipt-only and logs nothing), and a track not at 1x at `PERF_ARM` logs its rate and index at capture frame 0. The offline renderer steps a segment's index by the rate and reads it as the callback does (interpolated off whole samples, a box of `floor(rate)` samples in the head's direction at 2x and up); a 324 or a 322/323 phase that logs an integral index keeps the renderer's own exact fraction when the integral parts agree. A version-7 reader has no rate and renders a track at 1x. 326 is held by Multiply/Divide's `LE_PLOG_LENGTH` (#1168 plan) and is not written. |
| `9`      | Transpose (#1179 Part 3a): `LE_PLOG_TRANSPOSE` (328) carries what a track SOUNDS — its stored and its sounding pitch — at every change of the sounding one (the cache worker's render engaged, a dry fallback, bypass), with the exact index in Q32.32 and the equal-power window the old source is mixed out over, and at `PERF_ARM` for a track sounding transposed. The offline renderer renders the image through the same function, preset, seed and loop fold as the cache worker and reads it through the head from the logged index. A version-8 reader has no pitch and renders a transposed track dry. |

Neither reader in this repo (`perf_render.c`'s `le_pr_load_log`, the Dart
`EventLogReader`) gates on the field — both check the magic and skip these four
bytes — and that is deliberate: a capture already on disk still parses rather
than being refused, and the version-4 facts are simply absent (not misread) in
an older file. The field exists so a reader *can* tell the vocabularies apart,
because the absence of a code in a file is otherwise indistinguishable from a
writer that never knew about it.

### Entry (28 bytes each, one per logged event)

| Offset | Size | Field   | Notes                                              |
|--------|------|---------|------------------------------------------------------|
| 0      | 8    | frame   | `uint64`, frames elapsed since arm (same epoch as `performance.json`'s `capture_frames` and the PCM files) |
| 8      | 4    | code    | `int32`, one of the codes in the table below          |
| 12     | 16   | payload | raw union bytes; interpretation keyed on `code`, see below |

Every field is written via explicit fixed-width `fwrite` calls
(`perf_drain.c`'s `le_pd_write_events_header` / `le_pd_write_log_entry`)
rather than one `fwrite` of `sizeof(le_perf_log_entry)` — that in-memory
struct is actually 32 bytes (its `uint64_t frame` gives it 8-byte alignment,
padding 4 trailing bytes onto the 28 bytes of real content), so a naive dump
would write 4 bytes of uninitialised garbage per entry. Writing exactly 28
bytes across three `memcpy`s sidesteps that trailing pad; a portable reader
only needs to know the two fixed record sizes above.

### Two independent streams, not one global timeline

Every entry is produced by one of two single-producer rings:

- **`log_ring`** (audio thread producer): the audited `LE_CMD_*` commands
  below, plus the four transport facts, tagged at the exact frame they were
  applied.
- **`log_ctrl_ring`** (control thread producer): the handful of direct-atomic
  setters that bypass the command ring entirely (FX/monitor params, the
  limiter, overdub feedback) plus the common in-track undo/redo swap, tagged
  with a snapshot of the elapsed-frame counter at the moment the setter ran
  (accurate within one buffer).

Each drain cycle appends `log_ring`'s backlog, then `log_ctrl_ring`'s. Within
a single stream, `frame` is monotonically non-decreasing. **Across the two
streams, entries are not globally frame-sorted** — a control-side param
change and an audio-thread command from the same ~250ms interval can appear
in either order in the file. A reader that needs one merged, time-ordered
timeline must sort all entries by `frame` before use (a stable sort keeps
same-frame entries in file order, which is the best tie-break available
without finer-grained timestamps). Splitting into two rings by producer
thread is what keeps each one single-producer/single-consumer with no new
synchronization primitive — see `perf_log_ring.h`.

## The audited command table

Every `LE_CMD_*` the audio thread applies (`engine_process.c`'s
`apply_command`) was audited for whether it affects audibility. The logged
subset reuses `le_command`'s own code and union arm verbatim — the `payload`
bytes are that command's union, unchanged, so a reader already familiar with
`segno_engine_api.h`'s command-arm documentation can interpret them directly.

| Code (from `segno_engine_api.h`)   | Value | Arm         | Logged? | Why |
|--------------------------------------|-------|-------------|---------|-----|
| `LE_CMD_MEASURE_LATENCY`              | 1     | —           | No      | Device-calibration workflow, not a performance action |
| `LE_CMD_RECORD`                       | 2     | generic     | Yes     | Explicitly required (record/play/stop) |
| `LE_CMD_STOP`                         | 3     | generic     | Yes     | ” |
| `LE_CMD_PLAY`                         | 4     | generic     | Yes     | ” |
| `LE_CMD_CLEAR`                        | 5     | generic     | Yes     | Erases a track: audible |
| `LE_CMD_UNDO`                         | 6     | —           | No*     | Never posted to the ring (control-thread swap) — see `LE_PLOG_UNDO` below |
| `LE_CMD_SET_VOLUME`                   | 7     | generic     | Yes     | Track volume |
| `LE_CMD_SET_MUTE`                     | 8     | generic     | Yes     | Track mute |
| `LE_CMD_SET_RECORD_OFFSET`            | 13    | generic     | No      | Calibration/config value, not changed mid-performance |
| `LE_CMD_SET_INPUT_MASK`               | 14    | trackmask   | Yes     | Track record-source routing |
| `LE_CMD_SET_OUTPUT_MASK`              | 15    | trackmask   | Yes     | Track playback routing |
| `LE_CMD_ARM`                          | 16    | —           | No      | Scheduling intent only — the eventual fire is `LE_PLOG_RECORD_START` |
| `LE_CMD_DISARM`                       | 17    | —           | No      | Cancels an intent that was never logged |
| `LE_CMD_SET_LANE_FX`                  | 20    | fx          | Yes     | FX type change |
| `LE_CMD_SET_LANE_FX_COUNT`            | 21    | fxcount     | Yes     | FX chain length |
| `LE_CMD_COMMIT_SESSION`               | 23    | —           | No*     | Logged as `LE_PLOG_LOOP_LENGTH_LOCKED` (the semantic fact, not a raw copy) |
| `LE_CMD_SET_LANE_INPUT`               | 26    | lanei       | Yes     | Lane record-source routing |
| `LE_CMD_SET_LANE_OUTPUT`              | 27    | lanei       | Yes     | Lane playback routing |
| `LE_CMD_SET_LANE_VOLUME`              | 28    | lanef       | Yes     | Lane volume |
| `LE_CMD_SET_LANE_MUTE`                | 29    | lanef       | Yes     | Lane mute |
| `LE_CMD_SET_MONITOR_INPUT`            | 30    | generic     | Yes     | Monitor enable |
| `LE_CMD_SET_MONITOR_INPUT_FX`         | 31    | fx          | Yes     | Monitor FX type change |
| `LE_CMD_SET_MONITOR_INPUT_FX_COUNT`   | 32    | fxcount     | Yes     | Monitor FX chain length |
| `LE_CMD_SET_MONITOR_INPUT_OUTPUT`     | 33    | trackmask   | Yes     | Monitor playback routing |
| `LE_CMD_SET_MONITOR_INPUT_VOLUME`     | 34    | generic     | Yes     | Monitor volume |
| `LE_CMD_SET_MONITOR_INPUT_MUTE`       | 35    | generic     | Yes     | Monitor mute |
| `LE_CMD_SET_MASTER_GAIN`              | 36    | generic     | Yes     | Explicitly required |
| `LE_CMD_SET_OUTPUT_ENABLED`           | 37    | generic     | Yes     | Structural output gate |
| `LE_CMD_DUB_SHADOW`                   | 38    | —           | No      | Internal shadow-pool bookkeeping, not itself an audible change |
| `LE_CMD_UNDO_TO_EMPTY`                | 39    | generic     | Yes     | From version 6 (#1143): logged raw at its exact apply frame (`arg_i` = channel), in addition to the semantic `LE_PLOG_UNDO`, following the raw-command-plus-transport-fact convention below. The offline renderer appends silence from this frame, as it does for `LE_CMD_CLEAR`. Also logged for the cancelled take of `LE_CMD_CANCEL_TAKE`, which empties the track through the same body |
| `LE_CMD_REDO_FROM_EMPTY`              | 40    | —           | No*     | Logged as `LE_PLOG_REDO` (the from-EMPTY edge case) |
| `LE_CMD_PERF_ARM` / `LE_CMD_PERF_DISARM` | 41/42 | —        | No      | Meta — arming/disarming the session isn't part of what it captures |
| `LE_CMD_SET_ONE_SHOT`                 | 47    | —           | No      | The setter changes no output at the moment it applies. Its audible consequence — the auto-stop at the track's own loop wrap (Free/Song, `advance_track_clock_frame`) — logs a **synthetic `LE_CMD_STOP`** (`arg_i` = channel) at the exact wrap frame (#420), so a replay stops the track where a listener heard it stop. No `LE_PLOG_RECORD_END` accompanies a wrap mid-overdub, matching a manual Stop on an OVERDUBBING track — `RECORD_END` means "left RECORDING", and the dub pass's end is logged by its `LE_PLOG_LAYER_RETIRED`. |
| `LE_CMD_SET_TRACK_FX`                 | 49    | fx          | No      | No replay — manifest-only; stems stay per-stage dry-of-downstream (part 9), arm manifest carries track/master chains (part 3) |
| `LE_CMD_SET_TRACK_FX_COUNT`           | 50    | fxcount     | No      | ” (same manifest-only verdict) |
| 51, 52 — *retired*                    | 51/52 | —           | —       | The Master insert family; slice 3b made the Master insert output bus 0's chain, so these were deleted and the codes left unallocated |
| `LE_CMD_FINALIZE_TAKE`                | 56    | —           | No      | The `ARM`/`DISARM` rationale from the other side: finalize *intent*, and the transport fact it causes is what's logged — `LE_PLOG_RECORD_END` from the finalize it triggers, or `LE_PLOG_RECORD_ABORT` (unpaired, header version 3) when it cancels a count-in. A refused/no-op apply logs nothing: nothing audible happened. |
| `LE_CMD_RESTORE_TEMPO`               | 58    | generic     | No      | Restores the tempo/grid owner; no direct change to the recorded sample stream |
| `LE_CMD_SET_ONE_SHOT_MASK`           | 59    | generic     | No      | Sets Once for a complete track mask; the actual end logs the same synthetic Stop as single-track Once |
| `LE_CMD_SET_AUTO_RECORD`             | 60    | generic     | No      | Selects sound-triggered start and cancels incompatible count-in; the actual capture start remains a transport fact |
| `LE_CMD_SET_LENGTH_PRESETS`          | 61    | presets     | No      | Atomic future length settings; subsequent capture facts describe the result |
| `LE_CMD_SET_LANE_PAN`                 | 62    | lanef       | Yes     | Lane pan (slice 3): the lane's recorded image plus the track's pan, as the engine holds it |
| `LE_CMD_SET_TRACK_SOLO`               | 63    | generic     | Yes     | Track solo: an audibility gate, like mute — the offline render and the DAW export honour it |
| `LE_CMD_SET_MONITOR_INPUT_PAN`        | 64    | lanef       | Yes     | Monitor pan (slice 3); the monitor tap is already post-pan, so the logged value is what was heard |
| `LE_CMD_SET_OUTPUT_LEVEL`             | 67    | lanef       | Yes     | Output destination level (slice 3b). The capture tap is BEFORE it by default, so it changes nothing a default take contains; a Follow output take is captured after it, and `le_pr_render_master` replays it (filtered on the take's captured destination) so the render matches |
| `LE_CMD_SET_OUTPUT_MUTE`              | 68    | lanef       | Yes     | Output destination mute — same rule as 67 |
| `LE_CMD_SET_OUTPUT_MONO`              | 69    | lanef       | Yes     | Output destination Stereo/Mono. Hardware output format; excluded from the performance capture policies |
| `LE_CMD_SET_OUTPUT_BALANCE`           | 70    | lanef       | Yes     | Output destination balance — same as 69 |
| `LE_CMD_SET_OUTPUT_FX`                | 71    | fx          | Yes     | Captured destination output-chain entry type; replay filters on the frozen destination |
| `LE_CMD_SET_OUTPUT_FX_COUNT`          | 72    | fxcount     | Yes     | Captured destination output-chain length |
| `LE_CMD_CUT_SOUND`                    | 73    | —           | Yes     | Stop recorded sources and clear existing effect tails and the current click pulse. Every stopped track also logs a synthetic `LE_CMD_STOP`. Replay handles Cut itself to clear delay memory and keep sources silent until explicit Play or a new recording start; a finalizing `RECORD_END` does not restart them. Live monitoring and future click preferences remain unchanged |

Atomic mix transactions (`LE_CMD_SET_MIX`, 65) are not stored as raw
commands in this format: their bounded payload exceeds the sixteen-byte event
payload. Successful application emits the addressed volume, pan, Solo and output-control
primitive events at the same frame. Refused transactions emit none of them.
The recording-image wrapper (`LE_CMD_RECORD_IMAGE`, 66) likewise uses existing
recording transport facts and applied lane-image events rather than serializing
its larger command payload. The checked per-track requests with a callback
receipt — `LE_CMD_FADE` (81), `LE_CMD_RESET_TRANSFORMS` (82),
`LE_CMD_REVERSE` (83), `LE_CMD_SET_SPEED` (85), `LE_CMD_TRANSPOSE` (86) and
`LE_CMD_TRANSPOSE_BYPASS` (87) — are not stored raw either
(`le_log_extract` refuses them): a refused request changed nothing, and an
accepted one logs the primitive fact the callback applied (`LE_PLOG_FADE` 321,
`LE_PLOG_REVERSE` 324, `LE_PLOG_SPEED` 327, `LE_PLOG_TRANSPOSE` 328). Command 84 is held by
Multiply/Divide's `LE_CMD_SET_LENGTH` (#1168 plan). Input capture trim is already present in captured
PCM and is not applied a second time by replay.

The tuner's commands are not logged at all: `LE_CMD_SET_TUNER_INPUT` (53)
changes no output, and `LE_CMD_SET_TUNER_MUTE` (132, #1229) silences the
live monitors of the inputs being tuned without touching any recorded
material. A captured monitor stem already holds that silence, exactly as
heard, through the same path a monitor mute takes, so replay has nothing to
apply.

Recording images retain source balance and position separately from live
lane level and track pan. The volume/pan events contain their effective
composition at application time, so replay does not apply the image twice.
Arming freezes the source image, not the player's live fader controls.

Track FX parameter/enabled state remains in the arm manifest. Output FX
changes are logged separately: the selected chain is seeded at actual arm,
then output type/count and parameter/enabled events update its reconstruction.
Each output event is filtered by the take's frozen destination. Already captured
master PCM is not sent through that reconstruction a second time.

\* Logged under a different, semantically unified code — see below.

A command that changes output but isn't in this table is a standing
review-checklist item for every future part that touches `apply_command`
(umbrella-plan note).

## Perf-log-only codes (`le_perf_log_code`, `perf_log_ring.h`)

Values below 300 above are audited `LE_CMD_*` codes reused verbatim. These
are new codes with no `LE_CMD_*` equivalent — either transport facts (fired
from inside the audio thread's per-frame loop, so they carry the *exact*
sample-accurate frame rather than a buffer-start approximation) or
control-side-only concepts:

| Code                            | Value | Arm     | Payload                                                   |
|----------------------------------|-------|---------|------------------------------------------------------------|
| `LE_PLOG_RECORD_START`            | 300   | generic | `arg_i` = channel. A track actually began recording — immediate press or a deferred quantized/sound-triggered fire, both logged at the frame it actually happened. |
| `LE_PLOG_RECORD_END`              | 301   | take    | `{channel, take_id}` — a track left RECORDING **having captured something** (stop, punch-out, or the record/dub toggle into overdub), and `take_id` is the monotonic per-track id of the take that just finalized (from header version 4; before that the arm was generic and carried only the channel). `channel` aliases the generic arm's `arg_i`. The offline renderer matches `take_id` against the disarm manifest's `takeId` to anchor the settled image by identity (#819). A take that captured nothing logs `LE_PLOG_RECORD_ABORT` instead — see 314. In a version-1 file this code carries both meanings. |
| `LE_PLOG_LOOP_LENGTH_LOCKED`      | 302   | generic | `arg_i` = length in frames. The master loop length was (re-)established — the live-record finalize path or `LE_CMD_COMMIT_SESSION`'s session-import path. |
| `LE_PLOG_LAYER_RETIRED`           | 303   | evt     | `{channel, slot, generation}`, mirroring `LE_EVT_LAYER_RETIRED`'s payload. A completed overdub pass retired. |
| `LE_PLOG_UNDO`                    | 304   | generic | `arg_i` = channel. Every undo path — the common in-track swap or the to-EMPTY edge case — logs this one code. |
| `LE_PLOG_REDO`                    | 305   | generic | `arg_i` = channel. Same unification for redo. |
| `LE_PLOG_SET_LANE_FX_PARAM`       | 306   | fx      | `channel`, `lane`, `index` = `(fx_index << 8) \| param`, `type` = the float value bit-cast to `int32` (`f32_to_bits`). Control-side emission — params bypass the command ring. |
| `LE_PLOG_SET_MONITOR_FX_PARAM`    | 307   | fx      | Same packing; `channel` = input index, `lane` = -1. |
| `LE_PLOG_SET_LIMITER`             | 308   | generic | `arg_i` = enabled (0/1), `arg_f` = ceiling. |
| `LE_PLOG_SET_OVERDUB_FEEDBACK`    | 309   | generic | `arg_f` = feedback (0..1). |
| `LE_PLOG_SET_LANE_FX_ENABLED`     | 310   | fx      | `channel`, `lane`, `index` = fx slot, `type` = enabled (0/1). Control-side emission (direct-atomic setter, no ring). **Replayed in the lane wet pass** (`perf_render`, channel + lane-0 filter). |
| `LE_PLOG_SET_LANE_FX_CHAIN_ENABLED` | 311 | lanef   | `channel`, `lane`, `value` = enabled (0.0/1.0) — `LE_CMD_SET_LANE_MUTE`'s shape. Control-side emission. **Replayed in the lane wet pass.** |
| `LE_PLOG_SET_MONITOR_FX_ENABLED`  | 312   | fx      | `channel` = input index, `lane` = -1, `index` = fx slot, `type` = enabled (0/1) — 307's addressing convention. Logged for the manifest/reader, **not replayed in the lane pass** (mirrors `LE_PLOG_SET_MONITOR_FX_PARAM`'s treatment). |
| `LE_PLOG_SET_MONITOR_FX_CHAIN_ENABLED` | 313 | generic | `arg_i` = input index, `arg_f` = enabled (0.0/1.0) — the monitor volume/mute shape. Logged for the manifest/reader, **not replayed in the lane pass**. |
| `LE_PLOG_PERF_ARMED`              | 315   | perf_arm | `{position, master_len, iteration}` — the master loop phase at the exact audio-thread frame `LE_CMD_PERF_ARM` applied (capture frame 0). `master_len` == 0 means the capture armed with no master loop (Free/Song, or from silence), and `position`/`iteration` are then both 0. Exactly one per capture, from header version 4. The offline renderer's arm-image anchor and its no-lock `RECORD_END` phase math read this instead of the race-stale `armSnapshot.clockFrame` the control thread sampled BEFORE lane capture (#262); `iteration` also resolves a multi-loop arm image's sub-cycle (#260). |
| `LE_PLOG_TRANSPORT_HELD`          | 316   | generic | `arg_i` = the clock position the loop clock was pinned FROM. The shared transport became HELD mid-capture — nothing playing/recording/overdubbing, so `advance_transport_frame` pins the clock to position 0 (its all-idle branch). Edge-triggered: logged once when the hold begins, not every held frame. From header version 4. Lets the renderer's phase math see a clock the engine froze rather than running it forward. |
| `LE_PLOG_SET_TRACK_OVERDUB_FEEDBACK` | 317 | generic | `arg_i` = channel, `arg_f` = that track's own overdub feedback (0..1), or a negative value meaning the track follows the global coefficient (309). One per write, from events.log version 4. Written as 317 rather than the next line's number because 315 and 316 were already taken further down the enum. |
| `LE_PLOG_SET_OUTPUT_FX_PARAM` | 318 | fx | `fx.track` = output bus, `fx.lane` = 0, `fx.index` = `(slot << 8) | parameter`, `fx.type` = float32 value bits. Replays only the captured destination. |
| `LE_PLOG_SET_OUTPUT_FX_ENABLED` | 319 | fx | `fx.track` = output bus, `fx.index` = slot, `fx.type` = enabled flag. |
| `LE_PLOG_SET_OUTPUT_FX_CHAIN_ENABLED` | 320 | generic | `arg_i` = output bus, `arg_f` = chain enabled flag. |
| `LE_PLOG_REVERSE`                 | 324   | reverse_log | `{channel, reversed, read_index, turn_frames}` — the track's read direction (#1162), from header version 7. An accepted `le_engine_toggle_reverse` / `le_engine_install_reverse` logs `reversed` as it now stands, `read_index` = the exact dry index the callback reads at this frame (continuous across the turn: the same sample a forward read would have produced) and `turn_frames` = the window over which the pre-turn head is still mixed in with the seam's equal-gain law (0 on a loop too short to host it, or on a STOPPED track). Every material reset logs `reversed` 0 with `read_index` -1 (no anchor). A track reversed at `LE_CMD_PERF_ARM` logs its direction and index at capture frame 0; forward is the reader's default. **Replayed in the dry pass**: `perf_render.c` steps a reversed segment's phase -1 per frame from the logged index and mixes the turn. Written as 324 because 321-323 were taken; 325 is reserved for Peel. From header version 8, at a Speed other than 1x the logged `read_index` is the integral part of the callback's index; the renderer keeps its own exact fraction when the integral parts agree (see 327). |
| `LE_PLOG_PEEL`                    | 325   | peel_log | `{channel, slot, previous, generation}` — a Peel succeeded (#1164): `slot` is the pre-pass image now live, `previous` the image filed as the PEEL history entry, `generation` the track's `dub_generation` at the peel. The control-side admission record, like 304/305. The image the callback actually mixes is named by its own 322, which the Peel stages at admission exactly as a layer Undo does; **322 is the authoritative image name**. `generation` is informational only: the engine keeps no per-entry retire generation, so after a Clear/restore cycle it differs from the generation the peeled layer was staged with and does not bind to the staged layer key. Undo and Redo of a peel log 304/305. From header version 7. |
| (reserved)                        | 326   | —           | Held by Multiply/Divide's `LE_PLOG_LENGTH` (#1168 plan); not written. A reader skips it as an unknown code. |
| `LE_PLOG_SPEED`                   | 327   | speed_log   | `{channel; uint8 numer, denom; uint16 turn_frames; uint32 index_lo, index_hi}` — a track's read rate (#1179), from header version 8. `numer/denom` is the global Speed (1/2, 1/1, 2/1, 4/1 or 8/1), the track's rate in source frames per song frame; `index_lo \| index_hi << 32` is the exact index the callback reads at this frame in Q32.32; `turn_frames` the window over which the pre-change head is still mixed in with the seam's equal-gain law (0 when the track is not PLAYING or its loop is shorter than two windows). Logged for every track at each accepted change (an empty track has index 0 and only carries the rate forward), and at `LE_CMD_PERF_ARM` for each track not at 1x with `turn_frames` 0. **Replayed in the dry pass**: `perf_render.c` re-anchors the material at the logged index, steps it by the rate, reads it through `engine_read_head.h` as the callback does and mixes the turn. A material reset leaves the rate unchanged (Speed is global) and, for a track not at 1x, logs 327 with the reset index after its 324. After every 322 or 323 a PLAYING track logs while its head reads off whole samples, a 327 at the same frame carries the exact index the integral phase lost, so the renderer re-anchors exactly when material returns (Clear Undo) or resumes. A change inside a turn window still mixing keeps that window and the head it fades out (the logged `turn_frames` is the window's), and the renderer carries it over; at an integral rate (Normal, 2x, 4x, 8x) the new head lands on a whole sample, which is the index logged. When the last track becomes empty Speed returns to 1x and every track logs 327 at 1/1. |
| `LE_PLOG_TRANSPOSE`               | 328   | transpose_log | `{channel; int8 stored, effective; uint16 turn_frames; uint32 index_lo, index_hi}` — what a track sounds (#1179 Part 3a), from header version 9. `stored` is the track's Transpose pitch (-12..12), `effective` the pitch actually sounding: 0 while its render is pending, refused for the cache budget, or bypassed. `index_lo \| index_hi << 32` is the exact index at the swap in Q32.32, `turn_frames` the equal-power window over which the previous source keeps sounding (0 when the track is not PLAYING or its loop is shorter than two windows). **Replayed in the dry pass**: `perf_render.c` renders lane 0's image with `le_stretch_render_loop` at the logged pitch (the cache worker's preset, seed and 20 ms loop fold, `engine_cache.h`) and reads it from the logged index; `effective` 0 reads the image itself. Pitch dies with the material (a Clear Undo returns the take at 0). |
| `LE_PLOG_RECORD_ABORT`            | 314   | generic | `arg_i` = channel. A take died having captured **nothing**: it left RECORDING void (armed and stopped on the loop top, so the track goes back to EMPTY) — or, from header version 3, a count-in was cancelled by `LE_CMD_FINALIZE_TAKE` (#405), in which case `arg_i` is the counting channel and no `RECORD_START` ever preceded it (the ABORT is unpaired). An aborted take is not a take: it produced no content and has no settled image of its own, and a reader must not treat it as a finalize. Its own code rather than a `RECORD_END` (301) because the offline renderer anchors its disarm image off `RECORD_END` (#264); an abort never bumps a track's settled take id, so from header version 4 it also could never match a `takeId` even if it were a 301 — but keeping it a distinct code is the load-bearing guarantee. Present from header version 2 on. |

The replayed lane chain seeds all enable bits to 1 at arm: the arm manifest
carries no arm-time enabled state until part 3 of the FX-v3 epic adds it (a
pre-arm disable is invisible to the offline render until then).

Ordering caveat (same accepted tolerance class as the control-side param
events): enable flips are stamped with the control thread's buffer-base
`a_perf_frames` snapshot, while `LE_CMD_SET_LANE_FX`/`_FX_COUNT` are stamped
at audio-thread apply time — so an enable flip and a type/count change issued
within the same buffer can sort into the opposite order from the live engine,
and the replay's D-ENSEED re-seed then lands on the other side of the flip.
Bounded by one buffer, like the documented `LE_PLOG_SET_LANE_FX_PARAM` skew.

### Why record start/end are separate from the raw `LE_CMD_RECORD`/`LE_CMD_STOP` entries

Both the raw command *and* the transport fact are logged, deliberately: the
raw command captures "the user pressed record/stop this buffer"; the
transport fact captures "a track's RECORDING state actually changed, at this
exact frame." These usually coincide, but not always — a quantized
(loop-top) or sound-activated arm logs `LE_CMD_ARM` as *intent* (not logged;
see the table), and the actual `LE_PLOG_RECORD_START` fires later, at the
loop boundary or the input-level crossing, sample-accurately from inside the
per-frame loop. Likewise a deferred seam-crossfade finalize
(`request_master_finalize`) can push `LE_PLOG_RECORD_END` several frames
after the `LE_CMD_STOP` that requested it. A downstream consumer that only
needs "when did recording actually start/stop" should read the transport
facts, not try to infer them from the raw commands.

A consumer pairing those facts into takes must not assume every
`RECORD_START` is terminated by a `RECORD_END`: an aborted take — armed,
then stopped having captured nothing — terminates with `LE_PLOG_RECORD_ABORT`
(314) instead. A `START`↔`ABORT` pair is not a take and delimits no region —
it produced no content and has no settled image — so pair it only to close
the `START` and then discard it; never render it, and never let it consume
the audio belonging to a later real take on the same channel.
(In a version-1 file the abort was logged as `RECORD_END`, so this pairing
rule is only available from header version 2 on — see the version table.)
From header version 3, an `ABORT` may also arrive with **no open `START` at
all** — a count-in cancelled before its downbeat (`LE_CMD_FINALIZE_TAKE`,
#405). An unpaired `ABORT` closes nothing and must simply be skipped.

## Frame-tagging semantics

- Entries from `log_ring` (audio-thread-applied commands) are tagged with the
  elapsed-frame count at the **start of the buffer** the command was applied
  in (`apply_command` runs once per `le_engine_process` call, before the
  per-frame loop) — this is as fine-grained as a ring-applied command can be,
  since the engine only ever applies commands at buffer boundaries.
- Transport facts fired from *inside* the per-frame loop (record start/end,
  loop length locked via the live-record path, layer retired) carry the
  exact sample index within that buffer — genuinely sample-accurate.
- Entries from `log_ctrl_ring` (control-thread direct-atomic setters) are
  tagged with a plain `atomic_load` snapshot of the elapsed-frame counter at
  the moment the setter ran — accurate within one buffer, the documented
  tolerance for parameter changes (`docs/plan/.../part-3-plan.md`).

## Crash / abrupt-stop consistency

`events.log` is append-only and flushed every drain cycle (~250ms), the same
cadence as the PCM files. A crash or kill mid-capture leaves every entry
written before the last flush intact and parseable — there is no
finalization step for this file (unlike `performance.json`'s `finalized`
flag), since an append-only log has no "torn" state to guard against beyond
a possibly-incomplete final entry, which a reader detects by simply running
out of bytes mid-record (fewer than 28 bytes remaining) and discarding it.

### Callback-applied source images (codes 322–323)

`322` (`LE_PLOG_SOURCE_APPLIED`) names the immutable image that became a
channel's live source at this exact mixer frame; `323`
(`LE_PLOG_SOURCE_TRANSPORT`) updates only that image's playback state or
discontinuous phase. Both carry four 32-bit fields: signed channel, unsigned
image ID, signed `LE_TRACK_PLAYING`/`LE_TRACK_STOPPED` state, and signed
first-sample image index. From version 6 every callback-applied history
transition is admitted the same way (#1143): the control thread stages a copy
of the target slot and records its id for that slot BEFORE publishing the slot
live, and the callback logs the entry for whichever slot it first mixes
PLAYING or STOPPED. A Clear Undo, a layer Undo, a layer Redo and a Redo from
empty therefore each produce one `322`; a channel may carry several per
capture, and a reader switches images on each. Several admissions before one
callback (Undo, Undo, Redo in one block) produce exactly one `322`, for the
slot actually mixed, with that slot's latest id; the intermediate images are
listed but unreferenced, and a swap back to the slot already mixed produces no
fact. The callback publishes these at the existing mixer coordinate boundary;
generic Undo `304`/Redo `305` remain the control-side admission records. Fade
`321` supplies the independent stationary coefficient. The fixed event payload
is unchanged.

Native `layers` entries distinguish ordinary overdub (`kind: 0`, `restore_id: 0`)
from callback-applied source images (`kind: 1`, nonzero `restore_id`),
whichever history operation admitted them. Image files are named
`restore-<channel>-<restore_id>.pcm`, interleaved across their declared active
lanes. IDs never repeat within a capture; exhaustion marks capture incomplete.
Each admission copies `len × lanes × 4` bytes on the control thread and writes
the same to disk (a 30 s stereo-lane loop is about 11.5 MB per press); disk
growth, not capacity, is the ordinary-use cost.
The manifest is bounded (`LE_LAYER_STAGING_RING_CAPACITY` entries per capture).
Once it is full the drain drops later retired images instead of writing them,
reports the count as `"layers_dropped": N` (omitted while zero) and keeps
capturing master and monitors. A retired image the callback could not hand to
the staging ring is reported the same way, as `"layer_overruns": N`. In a
capture with either count any stem whose logged retire
(`LAYER_RETIRED`) has no manifest entry fails to render instead of replaying the
previous image; a restoration without its entry always fails. Without drops, an
unlisted retire keeps the existing edge tolerance (a retire handled after a
disarm or Clear may be unstaged) and the previous image continues.
Existing joined disarm/rearm starts a new namespace. The control thread stages
the retained image before posting Undo, including while a successful arm is
awaiting its callback. The existing drain owns file writing and cleanup.

Rendering resolves exact kind/channel/ID and validates complete PCM before
claiming success. Missing material, invalid bounds, duplicate identity and
segment-capacity exhaustion fail the affected stem. STOPPED restored material
is held silent until a callback-applied state/phase event permits playback.
This extends the existing lane-0 renderer for applied images; it does not
implement multi-lane offline rendering. The `322` frame is exact for lane 0:
the callback names the slot that lane 0 mixes in that very frame. The control
thread publishes lanes `n..1` before lane 0, so no lane can still mix the
previous slot in the fact's frame, but a lane `k >= 1` may mix the new slot up
to one frame before it (the live pool slot is published per lane, not per
track). A future multi-lane renderer must treat lanes `1..n` as switching
within one frame of the fact.

Code `323` with image ID zero and state EMPTY means provenance was lost: a
slot became live without a staged image (staging refused or the id space
exhausted, a loop-close restoration commit, a session import during capture),
or an image-sourced slot started being written by a new recording or overdub.
It is logged unconditionally on such a slot change, whether the previous
source was an image or the arm snapshot, so the affected stem fails rather
than replaying the arm image or a stale image as new; master capture remains
usable. This is a material-coverage limit, not a queue or storage overrun.
Undo-to-empty is not provenance loss: it logs the raw `39` and the renderer
appends exact silence, so a Clear Undo followed by an Undo-to-empty in the same
block renders silence and succeeds. New recording and captured retired-layer
events retain their existing image transitions.
