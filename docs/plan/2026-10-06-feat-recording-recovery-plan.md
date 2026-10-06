# Recording to USB, long recordings, atomic publication and recovery

<!-- cspell:ignore dpwx vjohm Xcpyh dged UXKN yzmt headerless repointing Repointing statvfs vfat EROFS sgno RDONLY abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq xyzabcdef CLOEXEC namei exfat FIPS fabsf inotify NTFS ntfs -->

Tracking: #1198 (gap inventory E7-11, E7-12, E7-19, E7-16, E7-17, E7-18),
`autonomy:merge-gate`, `stage:plan`. Builds on the USB storage service
(#1177) and the Library (#1178). Related open issues this plan closes or
absorbs: #1078 (bounded-memory recovery of large captures) and #727 (crash
durability of the capture bundle).

Revised 2026-10-06 after the plan review on PR #1205 and the owner's
decisions on it; §10 maps every finding to its change. Parts 1 and 11 are
built (PRs #1220, #1221).

Base: `origin/claude/segno-integration` at `5c163d11f`. Every `file:line`
below is on that head unless a branch is named. Engine paths written as bare
file names are under `packages/segno_engine/src/core/`. Branch citations:
USB plan and Part 4 on `origin/claude/usb-storage-1177-p4` (`79d37ea97`);
Library plan on `origin/claude/library-1178-p3` (`2d88d96ce`; the save-back
swap of #1203 at `9c646c2de`).

Accepted behaviour implemented here: `docs/handoff/segno-app/accepted-behavior.md`
(AB) §6.6, §6.7, §6.10, §6.11, §6.12 and §7.7 (lines 445–486, 535–539), with
§7.1, §7.2 and §7.8 for the guards. The design record behind §6.7 and §6.10
is untracked in the main checkout (`docs/design/2026-09-08-audio-ports-and-long-recording.md`,
`2026-09-08-recorded-audio-recovery.md`, `performance-recording-model.js`,
`2026-09-09-recovery-expansion-delivery.md`); where this plan cites it, it
cites the main-checkout path.

## Design source

`segno-ui.pen` (the 107 MB main-checkout file), group `01 CURRENT UX`
(`p0dpwx`), read through the pencil MCP. The work must match these screens:

| Section | Screens (id) | Used by |
|---|---|---|
| **20 Record performance & USB export** (`G2Cj8g`) | `01 / Ready to record` (`D9QbI2`), `02 / Recording` (`vjohm`), `03 / Recording by foot` (`E7kQV`), `04 / Saved recording` (`Xcpyh`), `05 / Interrupted recording` (`dgedL`), `06 / Save failure` (`owAnd`) | Part 9 |
| **47 Long recordings · Accepted** (`ut4fa`) | `Long take · Ordered parts` (`X4UXKN`), `Storage reserve · Recording kept` (`yzmtU`), `Capacity unavailable` (`T8ACW`) | Parts 8, 9 |
| **48 Recording destinations · Accepted** (`w70bn`) | `Choose Internal or USB` (`cH9UX`), `Record directly to USB` (`FwjUV`), `USB interruption · Take held` (`HWH3p`), `Recovered recording in Library` (`Z3V6Z`) | Parts 9, 10 |
| **36 Session recovery · Accepted** (`kmWoI`) | `1 / session-recovery` (`b28GI1`), `2 / session-recovery-files` (`HfLgr`), `3 / session-recovery-ready` (`w9WB8`), `4 / session-recovery-error` (`sra8u`), `5 / session-recovery-device` (`LaqVi`) | Part 15 |
| **42 Recover recorded audio · Accepted** (`cpcEc`) | `Missing or damaged layer` (`DEY0v`), `Find an intact original` (`KNzYO`), `Ready to open` (`l3bgeK`) | Part 15 |
| **43 Repair audio connections · Accepted** (`Wti9c`) | `Missing interface ports` (`K48Hse`), `Choose replacement ports` (`v7zSCN`), `Review routes` (`gtG0I`) | Part 17 |
| **40 Session connection repair · Accepted** (`vs4lB`) | `1 / Missing pedal connection` (`TNFh0`), `2 / Choose a compatible pedal` (`I8foz`), `3 / Review and apply` (`UOyKO`), `4 / Replace a MIDI controller` (`D3Rij`) | Parts 17, 18 |
| **41 Session control repair · Accepted** (`Fne3m`) | `1 / Missing control` (`WZvK8`), `2 / Choose a destination` (`GwDUd`), `3 / Choose a replacement control` (`v5FPjK`), `4 / Review affected assignments` (`qLXt5`), `5 / Review and open` (`iEuYw`) | Parts 19, 20 |

Copy the screens fix (quoted verbatim in the parts; the format line and
part durations follow D3, see below): `52:45:49 remaining`, `Remaining time unavailable`, `5 file
parts · One take`, `Playback and export use these parts in order.`, `Storage
is nearly full. Recording stops before reserved space is used.`, `The saved
checkpoint can be recovered. Audio after it may be unavailable.`, `Storage
reserve reached. The recorded part of this take is kept.`, `USB recording
stopped. Reconnect SEGNO USB to save the recorded parts. Your loops keep
playing.`, `Reconnect SEGNO USB. Saved parts stay on that drive.`, `Save
recovered audio`, `Discard recording`, `Could not save the recording. It is
kept here for another try.`, `The available recording can be saved. It may
be incomplete.`, `Your current session stays open until everything is
ready.`, `Choose an intact copy of this recording. Loop length stays the
same.`, `These ports already belong to another saved audio connection.`,
`Range positions are kept. These are the replacement values.`

The pen draws 24-bit parts; this plan writes 32-bit float parts (D3, owner
decision on review finding H1). The format line and the part durations
therefore differ from the pen, and are recorded in the write-back list (§9):
`48 kHz · 2 channels · 24-bit PCM` reads `48 kHz · 2 channels · 32-bit
float`, and a full part at 48 kHz stereo lasts 1:26:48, not 1:55:44. The
part size itself is unchanged: 2,000,000,000 bytes per file, header
included. The prototype model computes parts the same way with a 44-byte
header (main checkout `docs/design/performance-recording-model.js:5-8`).

## 1. Current state (verified)

**Capture path.** `le_perf_arm` (`engine_commands.c:4588-4712`) picks the
first enabled output pair (`:4549`, `:4606`), allocates a master ring and one
stereo ring per monitored input sized `next_pow2(channels × rate ×
LE_PERF_CAPTURE_SECONDS)` (`:4540`, `:4640`; `LE_PERF_CAPTURE_SECONDS 2`,
`engine_private.h:163`), freezes `follow_output` and the input mask
(`:4614-4649`), zeroes the counters (`:4651-4659`), starts the drain
(`:4692`) and pushes `LE_CMD_PERF_ARM` (`:4703`). On a full ring the audio
thread drops the frame and counts it (`engine_process.c:4134-4138`,
`:4288-4293`); it publishes elapsed frames with a release add
(`engine_process.c:6875-6879`). `le_perf_disarm` (`engine_commands.c:4772-4846`)
waits two buffer boundaries for quiescence, joins the drain with
`LE_PERF_STOP_DISARM` (`:4834`) and frees the rings. A reconfigure or reopen
stops the drain with `LE_PERF_STOP_DEVICE_CHANGED` (`engine.c:384-387`,
reached from `le_engine_configure` `:885-891` and `le_engine_reopen_configured`
`:932-960`).

**Drain.** `perf_drain.c` writes headerless native-endian float32 interleaved
PCM: `master.pcm` (1 or 2 channels, `:1536`), `input-<n>.pcm` (always 2
channels, `:1545`), `events.log` (`:1557`), and retired layers as
`layer-*.pcm` / `restore-*.pcm` (`:865-871`). Each 250 ms cycle
(`le_pd_drain_cycle`, `:1314-1442`) samples `elapsed` first (`:1358`), drains
the rings, zero-fills any shortfall up to `elapsed` (`le_pd_catch_up`
`:1069`, counted in `a_perf_zero_filled_frames` `:1100-1105`), appends the
logs and staged layers, `fflush`es (`:1426-1431`) and atomically replaces
`performance.json` (`:1171-1304`; keys `slug`, `sample_rate`,
`channel_layout`, `capture_frames`, `overrun_count`, `zero_filled_frames`,
`overrun_gaps`, `layers`, `layers_dropped`, `layer_overruns`,
`stopped_early`, `finalized: false`). Any write failure self-stops the thread
(`:1508-1510`) and is published as `perf_stopped`
(`engine_snapshot.c:393-394`, `segno_engine_api.h:1190-1210`). **Nothing is
ever synced to the device**: the comment at `perf_drain.c:479-506` states
it and points at #727, which explains why syncing the sidecar alone made the
bundle inconsistent and manufactured #710's zero-fill.

**Finalize.** `PerformanceRepository._finalize`
(`packages/performance_repository/lib/src/performance_repository.dart:941-1046`)
reads `master.pcm` and each `input-<n>.pcm` **whole** (`_readRawPcm`,
`:1163-1170`), writes `master.wav` / `live-input-<n>.wav` as 32-bit float
WAV beside them (`:979-1000`, `WavCodec.encodeFloat32`,
`packages/wav_codec/lib/src/wav.dart:56`), keeps the `.pcm`, and stamps the
manifest `finalized: true`. On the appliance that whole-file read asked for
38,381,030,944 bytes and failed (#1078). The second full copy is also why
the recorder's stop floor is "everything written so far plus 64 MB"
(`lib/performance/cubit/performance_recorder_cubit.dart:97-123`). The offline
renderer never reads the master or input PCM (`perf_render.c` reads
`performance.json` `:340-409`, `events.log` `:552`, `loops/` and layer files
`:928-933`, `:1085-1094`), and `daw_export` references only `stems/`
(`packages/daw_export/lib/src/manifest_reader.dart:181-203`). The only
readers of the captured master are `_finalize` and Library Part 7's planned
listing and export.

**Recorder app layer.** `PerformanceRecorderCubit` samples free space every
20 ticks (`performance_recorder_cubit.dart:131`, `:359-392`), refuses to arm
below 500 MB (`:97`, `:400-409`), and stops at the duplicate-copy floor
(`:411-437`, `:452-463`), always finalizing. Stop reasons are `diskFull` and
`deviceChanged` only (`performance_recorder_state.dart:5-18`). No state holds
an interrupted take for a Save/Discard choice; the completion sheet has a
saved face and a stopped-early banner only
(`lib/performance/view/performance_completion_sheet.dart:229-370`). A device
change while armed leaves the cubit showing Armed: the engine stopped the
drain (`engine.c:384-387`), `perfStopped` reads 0 because the drain is gone
(`engine_snapshot.c:393-394`), and nothing reads `isPerfArmed` after arm;
the reconnect supervisor knows nothing of the capture
(`packages/looper_repository/lib/src/looper_repository.dart:2164-2192`).
`PerfRecordButton` and `ArmedIndicator` are mounted nowhere in `lib/`; the
indicator on screen is the private `_RecordLight` in `StageTopBar`
(`lib/looper/view/stage_top_bar.dart:62`, `:344-412`), which only the Tracks
body shows (`lib/looper/view/tracks_view.dart:209-216`). Boot salvage is
silent and moves bundles into `recovered/`, pruned after 30 days
(`performance_repository.dart:674-899`).

**Session bundles.** `SessionRepository.save`
(`packages/session_repository/lib/src/session_repository.dart:451-511`)
rewrites every layer WAV **in place** under index names
(`track{c}_lane{l}_L{n}.wav`, `:468-484`), then the manifest with a plain
`writeAsString` (`:491-493`), then the mixdown, then prunes unreferenced
layers (`:509`, `:521-532`). A crash between those steps leaves new layer bytes under an
old manifest, or a torn manifest. `read` decodes every layer and throws on
the first missing file (`:543-590`). A layer is `{file}` only
(`models/session.dart:13-25`); nothing records its identity, integrity or
format. `Session.fromJson` accepts exactly `formatVersion` 11
(`models/session.dart:752-760`, `:847`); #1196 adds the migration chain
(Peel takes 12, Reverse 13).

**Connections and controls.** A session stores physical routing as raw
indices and masks: lane `inputChannel`/`outputMask` (`models/session.dart:95-99`),
`laneInputs`/`laneOutputs` (`:1008-1015`), monitor input index (`:451-455`),
input and output setup keyed by index (`:518-655`), `clickOutputMask`
(`:920-923`). No interface identity is stored. Port aliases are
appliance-owned, keyed per device name
(`packages/settings_repository/lib/src/settings_repository.dart:1804-1867`,
`lib/audio_setup/application/port_aliases.dart:25`, `:69-75`).
`applySession` validates only fixed caps (`looper_repository.dart:3767`,
`:3814-3820`; `models/mix_settings_snapshot.dart:112-117`), so a route past
the device's channel count is stored and inert (`engine_process.c:2669-2682`).
CTRL jack types and calibration are global (`lib/control/binding/external_pedal.dart:13-352`,
`pedal_setup.dart:275`, settings key `pedal.setup`), MIDI mappings are global
(`settings_repository.dart:535-560`), and the session's own pedal remap
binds built-in pedals only (`lib/control/binding/pedal_binding.dart:24-50`).
FX targets are `FxAddress` plus a stable `slotId`
(`lib/control/binding/fx_binding_target.dart:83-112`, param index
`control_value_target.dart:165-196`). Per-editor repair exists:
`ControlAvailability.resolves` (`lib/control/binding/control_availability.dart:33-63`),
`ExternalControls.repointActivation`/`repointParameter`
(`external_controls.dart:294-345`), `MidiMappingDraft.repointing`
(`midi_mapping_draft.dart:145-180`). At session load a missing target is
kept and inert (`control_cubit.dart:3036-3050`, `control_midi.dart:449`,
`:748`). There is no candidate or pending Library transaction in code;
`SessionCubit.loadNamed` (`lib/session/cubit/session_cubit.dart:231-384`)
reads, builds the rig, validates the mix candidate (`:252-253`) and then
starts side effects at `disarmAndFinalize` (`:254`).

**Guards.** The only app guard that looks at the recorder is the power-off
gate (`lib/appliance/power_off/power_off_gate.dart:48-73`), re-checked at each
commit (`power_off_cubit.dart:104-111`); it refuses rather than finishing
the take. `AppRuntime.takeLocked` (`lib/app/application/app_runtime.dart:156-157`)
stops a take from starting during power UI or a session transition. Audio
apply (`lib/audio_setup/cubit/audio_setup_cubit.dart:229-345`), latency
measurement (`:415-419`, `:478`, `lib/app/audio_bootstrap.dart:301`), update
restart (`lib/system/view/updates_system_tab.dart:262-271`,
`appliance_platform_backend.dart:116`) and storage actions check nothing.
Session load disarms and finalizes a running take (`session_cubit.dart:254`).
The USB plan adds write leases and eject refusal
(`storage_repository.dart:168`, `:174-207`, `:249-280` on the P4 branch).
No touch calibration exists yet.

## 2. Decisions

The owner's standing rules (1 preserve installs, 2 fail safe, 3 no silent
change, 4 consolidate, 5 drop uncertain native state with a notice) decide
everything below except the two questions in §8.

### D1. The drain writes directly to the chosen volume

The capture directory passed to `le_perf_arm` is the destination itself:
`{exportsRoot}/<slug>/` for Internal, `<mount>/Segno/Performances/<slug>/`
for a USB volume (the Library's drive layout, Library plan §4.3). The native
drain does not know which kind it is; it receives a target struct (Part 2)
whose `ring_seconds`, `reserve_bytes` and `live_sidecar_dir` differ by
destination.

Rejected: spooling to Internal and copying to USB afterwards. AB §7.7 says
direct USB recording "owns its removable target explicitly and has
same-drive/exact-part recovery", pen `HWH3p` says "Saved parts stay on that
drive", and a spool would consume the Internal space that recording to USB
exists to avoid. Field recorders write straight to their card for the same
reason.

What Internal still holds for a USB take, in `{exportsRoot}/.takes/<takeId>/`:

- the **mirror**: the arm snapshot, the volume fingerprint
  (`RemovableVolume.fingerprint`, ID_SERIAL + filesystem UUID, USB plan
  §2.1) and generation, and a copy of every checkpoint (D4). For a USB take
  the mirror is the **authoritative** checkpoint (ext4, where tmp + fsync +
  rename + directory fsync is sound); the slots on the stick are the
  fallback when the mirror is lost (review M1).
- the **live sidecar** (`performance.json`, rewritten every 250 ms). On a
  removable target the drain never writes a per-cycle file on the stick
  (review M6: `fat_file_release` on a `flush` mount sleeps `HZ/10` on every
  close of a written file, `fs/fat/file.c`). The stick receives only the
  part files, the staged layer files and the two checkpoint slots.

The mirror lets the console show `Reconnect SEGNO USB` after the drive is
pulled or the power is cut, and is what "same drive" is checked against.

### D2. Slow writes and full disks stop at complete frames

Two native stop rules, both in the drain, both ending every stream at the
same frame:

- **Reserve.** At arm the drain receives `reserve_bytes`: 1 GiB on Internal
  (`StorageRepository.internalReserveBytes`, P4 `storage_repository.dart:56`),
  16 MiB on a removable volume (room for the final checkpoint slots, the
  finalized manifest and the layer files still staged). Every 5 s, on the
  checkpoint cadence, the drain re-reads the volume's free bytes (the
  existing statvfs, `perf_drain.c:126`); between samples it subtracts every
  byte it writes (part headers and samples, `events.log`, layer files).
  Before each write it computes how many whole frames all continuous
  streams can still take together (`remainingFramesTogether`, the same
  function Dart uses, M2); when that reaches zero it writes exactly those
  frames, seals the parts and stops with `stopped_early: "reserve_reached"`.
  The JSON files rewritten in place (checkpoint slots, and on Internal the
  sidecar) are covered by a fixed 1 MiB allowance inside the reserve. A
  volume whose free space cannot be read records no budget (pen `T8ACW`:
  Start stays enabled, the line reads `Remaining time unavailable`, rule 1:
  the unanswerable-volume case arms today), and stops only on a write
  failure.
- **Slow storage.** The audio thread records the first frame it had to drop
  (`perf.first_drop_frame`, set once per take). Both drop sites already
  know the block's frame base (`perf_frame_base`, `engine_process.c:6353-6354`;
  drop sites `:4133-4139`, `:4288-4293`), and the store is sequenced before
  the release add of `a_perf_frames` (`:6875-6879`), so a drain that sees the
  drop also sees every frame before it. The drain writes each stream up to
  that frame, never past it and never pads after it, seals and stops with
  `stopped_early: "slow_storage"`. Frames the rings accepted after the drop
  are discarded, so the take never contains a hole followed by more audio.
  AB §6.7 requires this ("slow writes stop at complete recorded frames").
  The other zero-fill cause, frames counted but never tapped (#710,
  `perf_drain.c:1024-1068`), is not a storage fault and keeps today's
  behaviour: silence, the glitch flag, the take continues.
- **Ring size.** `ring_seconds` stays 2 on Internal (rule 1: today's value,
  `engine_private.h:163`) and is 8 on a removable volume, where flash erase
  stalls of 1–4 s are normal and the vfat `flush` mount option makes writes
  near-synchronous (USB plan §8 point 4). Ring capacity rounds up to a power
  of two (`engine_commands.c:4540`): 8 MiB per float stereo stream at 96 kHz.
  `LE_MAX_MONITORED_INPUTS` allows up to 32 captured inputs
  (`segno_engine_api.h:670`), so the arm caps the total ring memory at
  64 MiB by lowering `ring_seconds` (never below 2) as the stream count
  grows, and the snapshot reports the seconds actually granted (review L5).
- **Write failure** (ENOSPC from another writer, EIO, EROFS, a pulled
  drive) keeps today's self-stop and `stopped_early: "disk_full"` string
  (`perf_drain.c:1269-1271`), which every existing bundle on disk uses; the
  app labels it by the lease outcome (`volumeLost` when the volume record
  vanished, USB plan Part 6) or as a write failure.
- **Remaining time and the warning (review M2).** One function computes
  remaining time for every caller: `RecordingFormat.remainingFramesTogether`
  (Part 5) over the frozen set of streams (master plus every captured input,
  each with its bytes per frame and one header per part), from the
  destination's free bytes minus its reserve (1 GiB Internal, 16 MiB
  removable) minus the 1 MiB allowance. The page's `52:45:49 remaining`,
  the 60-second warning (pen `yzmtU`'s `Storage is nearly full. Recording
  stops before reserved space is used.`), the native budget and the USB
  picker's `requiredBytesPerSecond` (all streams' byte rate × 2, replacing
  USB P6's master-only rate) use it. USB P4's single-rate
  `recordingTimeRemaining(destination, bytesPerSecond)` without a removable
  reserve is replaced by it (a follow-up recorded for USB Part 6).
- **Arm refusal (review L3).** Arming is refused when the destination
  cannot hold at least 10 s of every stream above its reserve, the
  allowance and one header per stream (pen 31 `No recording space`). This
  replaces the 500 MB constant (`performance_recorder_cubit.dart:97`) and the
  duplicate-copy stop floor (`:112-123`, `:411-437`); both exist only
  because finalize copied the take, and after D3 it copies nothing.

### D3. Part format: ordered 32-bit float WAV parts written once

Owner decision on review H1: the parts are 32-bit IEEE float, not 24-bit.

- **Why not 24-bit.** The capture tap is in `output_bus_frame`
  (`engine_process.c:4175-4206`), before the master gain and the limiter
  (`master_bus_frame`, `:4233-4251`, run after the bus loop, `:6771-6777`).
  The captured master is an unbounded float sum of tracks, live inputs and
  the click; captured inputs are post-FX monitor signals, also unbounded.
  24-bit would hard-clip every over that the listener heard limited, with no
  flag. Float keeps today's float capture (rule 1) and puts no limiter on
  the capture path.
- **Encoding.** Little-endian IEEE float32, `WAVE_FORMAT_IEEE_FLOAT` (tag 3),
  at the device rate, with the channel count frozen at arm: 1 or 2 for the
  master (`engine_commands.c:4614-4616`), 2 for each captured input. Samples
  are written as captured, never clamped.
- **Overs are counted, not altered.** Per part the drain counts samples
  whose magnitude exceeds 1.0 (`overs`). The count is in every checkpoint
  and in the finalized manifest per part and per take, so the Library and
  the Record page can say the take holds samples above full scale (rule 3)
  without changing them. The count does not stop or alter the take.
- **Size.** At most 2,000,000,000 bytes per file, header included: under
  FAT32's 4 GiB − 1 file limit, under RIFF's 32-bit size fields, and under
  2^31 for readers that hold RIFF sizes in a signed int. At 48 kHz stereo a
  part holds 249,999,989 frames (1:26:48); mono 499,999,979.
- **Layout.** `RIFF`/`WAVE`, `fmt ` (16 bytes: tag 3, channels, rate, byte
  rate, block align `4 × channels`, 32 bits), a 32-byte `sgno` chunk
  (`take_id` 16 bytes, `stream` u16: 0 master, 1 + n input n, `part_index`
  u16 from 1, 12 reserved zero bytes), then `data`. Header total 84 bytes,
  so a part holds `floor((2,000,000,000 − 84) / (4 × channels))` frames. The
  16-byte float `fmt ` without a `fact` chunk is what `WavCodec.encodeFloat32`
  already writes (`packages/wav_codec/lib/src/wav.dart:56-87`) and what every
  DAW and dr_wav read. RIFF readers skip the unknown `sgno` chunk; it makes a
  copied or renamed part identifiable.
- **Names.** `master-001.wav`, `master-002.wav`, … and `input-<n>-001.wav`,
  in the bundle root. The user-facing name of a part is `<take name> · Part
  001.wav` (prototype `performance-recording-model.js:38`), applied at
  export only.
- **Lifecycle.** The drain writes the header with zero sizes, appends data,
  and on rollover or stop **seals** the part: patches the RIFF and `data`
  sizes, flushes, and records the part's SHA-256 over its `data` payload
  (computed incrementally while writing, D6) and its `overs`. Finalize
  copies nothing: the parts are the take. This removes the second copy, the
  2× space requirement and #1078's whole-file read for every new take.
- **One Library item, and the contracts it changes (review M7).** The
  finalized manifest lists `parts` per stream in order with `index`, `file`,
  `frames`, `bytes`, `sha256`, `overs`; the take's frame count is the
  master's sum. For the Library plan this means:
  - `listCaptures` reads duration from `parts`;
  - `dawPackageFiles` is the ordered `master-NNN.wav` and `input-<n>-NNN.wav`
    parts (plus `project.als` and `fx-chains.txt`), not `master.wav` and
    `live-input-N.wav`;
  - the audition voice (Library D10) plays part 1 of the master stream
    through the bounded reader, never `master.wav`;
  - a single-WAV export of a multi-part take writes the parts as
    consecutive `<name> · Part NNN.wav` files (each fits FAT32).
- **One Dart WAV reader (review M7, rule 4).** `wav_codec` is the one Dart
  reader: Part 5 adds the bounded part reader and the `maxFrames` bound on
  `decodeFloat32`; the Library's Part 6b peaks and audition decode, and this
  plan's recovery, all use it. #1200's backing player decodes natively
  (miniaudio's dr_wav on the audio side), which is a separate concern (a
  native voice), not a second Dart reader.
- **Legacy bundles** (raw `master.pcm`, including the 38 GB capture on the
  appliance) are recovered by re-chunking each float stream into float parts
  (header + the same sample bytes) **one stream at a time**: each `.pcm` is
  removed once its parts and an interim manifest naming them are durable,
  so the conversion needs only the largest stream's size free (review L4),
  and no sample changes.

### D4. Durability: checkpoints off the drain cycle (answers #727)

- A **checkpoint thread**, owned by the drain session, runs every 5 s (the
  prototype's interval, `2026-09-08-audio-ports-and-long-recording.md:73`).
  After each cycle's `fflush` the drain publishes, under a mutex it holds
  only to copy a few integers, the progress it has made visible to the OS:
  per stream the part count, frames and overs in the open part, sealed
  parts' digests and overs, `events.log` bytes, layer files written. The
  checkpoint thread copies that snapshot, opens each touched file read-only
  and `fdatasync`s it (Linux syncs the inode, whichever descriptor wrote
  it; fsync persists FAT's directory entry and FAT table and exFAT's whole
  device, review "verified correct"), then writes the checkpoint. The drain
  cycle never waits on the device.
- **Two checkpoint slots, never a rename over a file (review M1).** vfat
  renames over an existing file by repointing the target's directory entry
  and freeing the old clusters, which the drain can be handed before the
  new entry reaches the device; exFAT writes the new entry and deletes the
  old one as separate steps (`fs/fat/namei_vfat.c`, `fs/exfat/namei.c`). So
  every checkpoint location uses two fixed files, `checkpoint-a.json` and
  `checkpoint-b.json`, rewritten in place alternately. Each holds a
  `sequence` number and ends with a `checksum`: the SHA-256 of every byte
  before it, through Part 1's implementation (one hash in the engine and in
  Dart, rule 4; it serves the purpose a CRC would). The writer truncates,
  writes, `fsync`s; the reader takes the valid slot with the highest
  sequence. A torn slot fails its checksum and the other slot stands. The
  same two-slot format is used on Internal and in the mirror, so there is
  one checkpoint reader.
- **Where each copy lives.** Internal take: slots in the bundle. USB take:
  slots in the bundle on the stick and in the Internal mirror; the mirror
  wins when both are valid and disagree (it is on ext4 and is written
  second, after the stick's fsync).
- **What recovery trusts (review H2).** Recovery trusts the files as written
  (every whole frame present in every stream, floored to the shortest
  stream) only when all three hold: the checkpoint's `boot_id`
  (`/proc/sys/kernel/random/boot_id`) is the current boot, the destination
  stayed mounted for the whole take (Internal, or a removable volume whose
  `generation` is unchanged since arm), and recovery is not driven by the
  mirror alone. Otherwise it trusts only the checkpoint: a pulled stick is
  the same boot, but FAT and exFAT order neither data nor metadata
  writeback, so a size on the stick can cover clusters that never received
  the audio. This is the pen's promise: `The saved checkpoint can be
  recovered. Audio after it may be unavailable.`
- **Rollover after the last checkpoint (review L2).** Recovery drops parts
  the checkpoint does not list, truncates a part sealed after the checkpoint
  to the checkpoint's frames, re-patches its sizes and recomputes its digest
  and overs.
- **Transient errors** are not fatal: `EINTR` is retried as today
  (`perf_drain.c:511-529`); a failed `fdatasync` or slot write keeps the
  other slot, sets `checkpoint_failures` in the snapshot and retries next
  interval; it never stops the take. Only drain write failures stop a take
  (D2).
- The guarantee (at most the last 5 s lost after a power cut, nothing lost
  after an app crash on a volume that stayed mounted) and the file set are
  written into `docs/design/performance-manifest-format.md` beside the
  `.boot-recovery` contract, as #727 asks.

### D5. One recoverable publication per Library operation

Owner decision on review M3: Part 7 extends the Library's save-back swap
(#1203, `origin/claude/library-1178-p3` `9c646c2de`,
`packages/session_repository/lib/src/session_repository.dart:1047-1209`)
rather than adding a second mechanism. That swap writes the bundle into a
sibling `<id>.saving/`, renames `<id>` to `<id>.old`, renames `<id>.saving`
to `<id>`, deletes `<id>.old` (`_swapIn`, `:1153-1175`), and
`_recoverInterruptedSwaps` (`:1177-1209`) runs on every catalog read: an
`<id>.old` without `<id>` is put back, one beside `<id>` is deleted, and a
stale `<id>.saving` is deleted.

What Part 7 adds to that one mechanism:

- **Audio is immutable and named by identity.** A session layer lives in
  the bundle as `audio/<sha256-hex>.wav` (D6). The staged `<id>.saving/`
  receives each layer the previous bundle already holds as a **hard link**
  to `<id>/audio/<hex>.wav` (sessions live on Internal ext4), and writes only
  layers it does not hold (`.part`, `fsync`, rename within the staging
  directory). A re-save therefore costs the bytes of new layers only, not
  twice the session (review M3's space note).
- **The commit point is the swap.** Before the first rename the staged
  manifest and every file it references are durable (each file flushed,
  then `le_fs_sync_dir` on `<id>.saving/` and `<id>.saving/audio/`); the
  second rename is followed by `le_fs_sync_dir` on the parent.
- **The recovery rule rolls forward when it can.** Extended
  `_recoverInterruptedSwaps`: `<id>` absent and `<id>.old` present → if
  `<id>.saving/` holds a manifest that parses and every file it references
  is present with its recorded size, rename `<id>.saving` to `<id>` and
  delete `<id>.old` (the new save was complete; review M3's rule); otherwise
  delete `<id>.saving` and put `<id>.old` back. A `.part` file inside a
  bundle is deleted. The rule still runs on catalog read, so there is one
  recovery path for both the Library's swap and this plan.
- **Allocation is accounted before writing.** The save sums the bytes of
  the layers it must add and refuses with `StorageFailure.full` before
  writing anything when they exceed free space. Saves may use the 1 GiB
  reserve (that is what the reserve is for: a take stops before it, so the
  session can still be saved).
- **Garbage needs no sweep.** Unreferenced audio is simply not linked into
  the staged bundle, so the swap leaves it behind in `<id>.old`, which is
  deleted. Legacy index-named layer WAVs (`track*_lane*_L*.wav`) disappear
  the same way at the first save after this part.
- **Other Library mutations use the same names.** Save as and Duplicate
  build into `<new-id>.saving/` and rename it to `<new-id>` (no `.old`
  step); Restore from USB copies into `<new-id>.saving/` and renames; Delete
  renames `<id>` to `<id>.deleting` and then removes it (next point); Move
  to folder is a rename.
- **Delete versus an interrupted save.** An `<id>.old` with neither `<id>`
  nor `<id>.saving` is ambiguous between "delete interrupted" and "save
  interrupted after staging was removed". The recovery rule restores it
  (rule 2: keep the material); Delete therefore renames to `<id>.deleting`
  instead, which recovery finishes by removing. The recovery rule
  recognises exactly `.saving`, `.old` and `.deleting`.
- **Performance takes publish the same way.** On Internal, finalize writes
  `performance.json` through tmp + flush + rename + directory sync (ext4).
  On a removable volume there is no live sidecar on the stick (D1), so
  finalize writes `performance.json` fresh, never over an existing file,
  with a trailing `checksum` (SHA-256 of the bytes before it); a manifest
  whose checksum fails reads as unfinalized and recovery runs from the
  checkpoint slots. Discard renames the bundle to `.discarding-<slug>` and
  deletes it; the allocation is released only after that rename succeeded
  (prototype model, design doc `:75-77`), and boot salvage finishes it.
- **Native role.** Dart has no directory `fsync`. Part 1 exports
  `le_fs_sync_dir(path)`. Everything else is ordinary file I/O in the owning
  repository; the capture side is native because the drain is.

### D6. Identity of recorded audio

- **Session layers: content identity.** `audioId` is `sha256:` plus the
  SHA-256 of the layer's sample payload (the WAV `data` bytes: mono
  little-endian float32, exactly what `le_engine_export_layer` returns). The
  manifest records per layer `{file, audioId, frames, sampleRate, channels:
  1, encoding: "f32"}`. A layer image is immutable once settled and the
  same image appears in several history positions and in duplicates, so
  content identity makes every intact copy acceptable and nothing else:
  a file is accepted for a reference only when it decodes with that
  encoding, rate and channel count, has exactly `frames` frames, and its
  payload digest equals `audioId`. The file name is never consulted (AB
  §6.10 "Same name is not enough"). Two candidates with the same digest
  hold the same bytes, so a duplicate is not ambiguous.
- **Performance takes: minted identity plus sealed digests.** `takeId` is a
  random 128-bit id minted at arm (`Random.secure`), before any audio
  exists, because the mirror, the `sgno` chunks and same-drive recovery
  need it while the take is still being written. Each part is identified by
  `(takeId, stream, part_index)` and verified by its sealed SHA-256 and
  frame count (D3). An unsealed last part found at recovery is verified by
  its `sgno` chunk and its size against the checkpoint, then sealed by
  recovery.
- **One hash implementation.** SHA-256 in C (Part 1), used by the drain,
  by a new engine-free `le_digest_file(path, offset, length, out)` for
  verification, and by `le_digest_bytes` for layers already in memory.
  Verification runs in `Isolate.run`, never on the UI isolate.
- **Legacy references.** A layer saved before this plan has no `audioId`.
  The schema migration step marks it `unverified`. While its file is
  present it opens as today; the next save computes its digest from the
  engine's PCM, so the identity exists from then on. A missing unverified
  layer cannot be matched to anything and the session is refused with
  `This recording was saved before Segno could identify it, so a copy can't
  be checked.` (AB §6.10 and the design record: "missing or malformed
  manifests stay explicitly unverified").

### D7. The pending Library transaction (the Open candidate)

`Open` in the Library (Library Part 4) becomes a two-phase operation:

1. **Inspect** (no side effects): read the manifest, check every audio
   reference (exists, decodes, frames, digest), check prepared backing
   references by #1200's asset identity, check physical connections against
   the current interface (Part 16), check control targets against the
   candidate's target universe (Part 19). The result is an `OpenCandidate`:
   the parsed session plus a list of `RepairItem`s (`missingAudio`,
   `damagedAudio`, `unverifiedAudio`, `missingBacking`, `missingPort`,
   `missingCtrl`, `missingMidiDevice`, `missingTarget`), each with its
   affected references (track/layer including undo/redo positions, prepared
   list rows, routes, assignments).
2. **Choose** (candidate only): each repair choice replaces a value in the
   candidate. Nothing on disk or in the rig changes. Cancel discards the
   candidate (AB §6.11).
3. **Apply and open** (one guarded commit): recheck everything against the
   current media and hardware (a drive pulled since the choice invalidates
   it), copy each chosen recorded file into the bundle under its
   content-addressed name (no manifest edit: the manifest already references
   that identity), publish a repaired manifest through D5's swap when
   connections, targets or backing references changed, save the outgoing
   rig (Library D7), then apply. A failure before the swap leaves the bundle
   as it was (copied files are already referenced by it and only make it
   more complete); a failure after it reports that the session was repaired
   but not opened, with Retry. Global settings changes (global MIDI and
   external assignments, Part 20) are written after the swap; if that write
   fails the state reads "repaired, assignments not saved" with Retry, never
   "unchanged" (AB §6.11 "must not claim unchanged state if rollback itself
   failed").

Pen 36 `HfLgr` shows a recorded track (`Guitar phrase.wav`) accepting a
different file with "Same duration and format". AB §6.10 and section 42
(accepted on the same day, the later record) allow only the exact original or
an intact backup for recorded audio. This plan follows AB: section 36 is the
shell (list, `Find audio`, `Ready`, save failure, device unavailable) and
section 42 is the rule for recorded layers. The departure is in the pen
write-back list (§9, review L7).

**Backing rows (review M8).** Pen 36 also draws a prepared backing row
(`Evening lights.wav · Prepared audio · Backing track · Find audio`, on
`b28GI1`, `w9WB8`, `sra8u` and `LaqVi`). This plan builds it: Part 14
inspects backing references and Part 15 draws the row, matching a candidate
by #1200's backing asset identity (exact identity, the same rule as
recorded layers), once #1200's Part 5 (its asset identity) has landed. #1200
D9 defers backing repair to E7-16, which is this plan; the #1200 plan is told
the row lives here.

### D8. Guards: one registry, checked at commit

A pure-Dart package `packages/operation_guards` holds
`GuardRegistry.enter(kind, scope) → OperationGuard` (throws
`GuardRefused(blockers)`), `blockers(kind, scope)` for disabling buttons,
and a release handle. Dart runs these owners on one isolate, so the check
and the registration are one synchronous step; each owner calls `enter` at
its **commit point**, not when its dialog opens (AB §6.12). Scope is
`Internal` or a removable volume generation, optionally narrowed to one item
(a bundle). Owners that track their own operations report them through
`ActiveOperationSource` (the USB leases and eject), so there is one table.

A guard is held only while the operation runs. **A held take holds no
guard and no lease** (review M4): it is a finished capture waiting for the
player's Save or Discard, its durable state is on disk (and in the Internal
mirror for USB), and it must not block Open, New loop, power off, update or
eject. Save recovered audio takes its own `transfer` lease while it writes.

| Wants to commit ↓ / active → | capture | sessionApply | sessionWrite | transfer | eject | deviceChange | calibration | restart |
|---|---|---|---|---|---|---|---|---|
| **capture** (arm) | – | refuse | allow | refuse (same volume) | refuse (same volume) | refuse | refuse | refuse |
| **sessionApply** (Open, New loop) | allow (a running take is finished first: today's `disarmAndFinalize`, rule 1) | refuse | refuse | allow | allow | refuse | refuse | refuse |
| **sessionWrite** (save, Save as, rename, duplicate, delete, restore into Internal) | allow | allow (its own preservation save) | refuse (same bundle) | allow | allow | allow | allow | refuse |
| **transfer** (export, backup, import, restore read, Save recovered audio) | refuse (same volume) | allow | allow | allow | refuse (same volume) | allow | allow | refuse |
| **eject** | refuse (same volume) | allow | allow | refuse (same volume) | refuse | allow | allow | refuse |
| **deviceChange** (audio apply, rate change) | refuse | refuse | allow | allow | allow | refuse | refuse | refuse |
| **calibration** (latency measurement; touch calibration when it exists) | refuse | refuse | allow | allow | allow | refuse | refuse | refuse |
| **restart** (power off, restart, update install) | refuse (a running take is finished first) | refuse | refuse | refuse | refuse | refuse | allow (it is cancelled and keeps the old profile, AB §7.6) | – |

Capture and a writing transfer on the same volume refuse each other
(review L6): an export or backup to the stick a take is recorded on competes
for its bandwidth and would end the take as `slow_storage`. On Internal the
same rule refuses an import into Internal while a take records there; that is
the conservative reading, since NVMe has the bandwidth, and an import waits
seconds at most.

Wiring (Parts 11 and 12): `PerformanceRepository.arm` before `le_perf_arm`
(the pedal reaches the repository directly, `performance_repository.dart:278-283`);
`SessionCubit` at the step after preservation and before
`disarmAndFinalize` (`session_cubit.dart:254`); `SessionRepository`'s commit;
`StorageRepository.acquire` and `eject` (P4), which consult the registry and
report their leases and eject as `ActiveOperationSource` (a follow-up for USB
Part 6, §8); `AudioSetupCubit` before `stopEngine`
(`audio_setup_cubit.dart:296`); latency measurement (`:415-419`, `:478`);
the power-off commit (`power_off_cubit.dart:104-111`) and the update
restart (`updates_system_tab.dart:262-271`). Involuntary events are not
guarded, they end the guarded operation: a device loss ends the take with
`device_changed` (now surfaced, Part 9), a pulled drive ends leases with
`volumeLost` (USB P4). AB §7.8: power off finishes the performance take
(finalize), saves the session, then enters `restart` (it saves before
entering, since the table refuses a session write once restart is active);
a loop still capturing keeps today's refusal (`power_off_gate.dart:54-62`),
because closing a loop is a musical act the console should not take for the
player. A held take does not block power off (review M4).

### D9. Held takes

A take that stops for any reason other than the player's Stop (reserve,
slow storage, write failure, volume lost, device changed) is **held**: the
repository disarms (the final checkpoint is written), releases its capture
guard and lease, does not finalize, and the Record performance page shows
pen `yzmtU`/`HWH3p`/`dgedL` with `Save recovered audio` and `Discard
recording`. Save runs the recovery finalize (D4); Discard publishes the
discard (D5). `Save` failing shows `owAnd` and keeps the take.

A held take survives Open, New loop and restart. **Every unfinalized take is
found the same way (review M5):** at start and on every volume event the
repository lists Internal bundles without a finalized manifest and every
mirror in `{exportsRoot}/.takes/` without a finalized bundle. Each becomes a
held take:

- Internal, or USB with its bundle present on a mounted volume with the
  mirror's fingerprint: `Save recovered audio` enabled.
- USB with the drive absent: `Save recovered audio` disabled with
  `Reconnect SEGNO USB. Saved parts stay on that drive.`; Discard removes
  only the mirror after the confirm, stating that the parts stay on the
  drive.

This replaces the silent boot salvage for new takes: a recovered take is
offered, not moved into `recovered/`. Bundles already under `recovered/` stay
there and are listed in the Library as recordings (owner decision on
retention: kept, no automatic deletion; the 30-day prune is removed). The
Library's Delete for recordings (Library Part 7, Library > Audio, confirmed
and guard-checked; review M9) is how the player frees that space.

A normal Stop finalizes at once and shows `04 / Saved recording`.

## 3. Fault matrix

| Fault | Detected by | Result | Pen |
|---|---|---|---|
| Internal reaches the reserve | drain budget (D2) | stops at a whole frame, held, `Storage reserve reached. The recorded part of this take is kept.` | 47 `yzmtU` |
| USB reaches its 16 MiB floor | drain budget (D2) | same, on the stick | 47 `yzmtU` |
| Fewer than 60 s left | `remainingFramesTogether` over every stream and the reserve (D2) | warning line, take continues | 47 `yzmtU` (warning line) |
| Capacity unreadable | statvfs fails | `Remaining time unavailable`; no budget; Start enabled | 47 `T8ACW` |
| Samples above full scale | drain `overs` count (D3) | kept as captured; counted per part and shown | – (new line, §9) |
| Writes slower than capture | first dropped frame (D2) | stops at the frame before the drop, held, slow-storage copy | 20 `dgedL` |
| USB pulled mid-take | lease `volumeLost` + drain write failure | held; loops keep playing; Save disabled until the same drive returns; power off and Open not blocked | 48 `HWH3p` |
| Same drive reconnected | fingerprint match on attach | Save recovered audio enabled; recovery on the drive **to the checkpoint** (D4, H2) | 48 `HWH3p` → `Z3V6Z` |
| Different drive connected | fingerprint differs | nothing offered; take stays held | 48 `HWH3p` |
| Power cut mid-take, Internal | next start: unfinalized bundle | held, Save recovers to the last checkpoint | 48 `Z3V6Z` |
| Power cut mid-take, USB still attached | next start or the volume's attach: mirror + bundle present | held, Save enabled, recovery to the checkpoint | 48 `HWH3p` → `Z3V6Z` |
| App crash mid-take, volume stayed mounted | next start, same boot id, same generation | held, Save recovers everything written | 48 `Z3V6Z` |
| Torn checkpoint slot | checksum fails | the other slot stands | – |
| Audio device lost mid-take | `isPerfArmed` false while repository armed | held with device-changed copy | 20 `dgedL` |
| Save recovered audio fails | finalize throws | `Could not save the recording. It is kept here for another try.` | 20 `owAnd` |
| Crash during a session save | catalog read (D5) | the old save, or the new one when it was complete; never neither | – |
| Session layer missing or damaged | Open inspection | repair list, `Find audio`, exact identity only | 36, 42 |
| Prepared backing missing | Open inspection | backing row, `Find audio`, exact asset identity | 36 |
| Saved interface absent | Open inspection | `Replace` ports, stereo roles kept, occupied ports refused | 43 |
| Eject during a USB take, export or backup | guard registry | refused naming the purpose | 31 `BQc2H` |
| Export or backup to the stick being recorded on | guard registry | refused naming the take | – |
| Audio apply or latency measurement while recording | guard registry | refused: `Stop recording first.` | – |
| Power off while recording | power flow | take finalized, session saved, then shutdown | 32 |

## 4. Splitting

Twenty parts, each independently mergeable, each about 700 production lines
or fewer. Native parts carry native tests with literal oracles. Review L10:
the four areas (capture: Parts 1–5, 8–10, 13; publication: 6, 7, 14, 15;
connection and control repair: 16–20; guards: 11, 12) should be tracked as
sub-issues of #1198 so the board shows progress; the main session creates
them.

```
Part 1 sha256 + fs sync ──► Part 2 part writer ──► Part 3 stop rules
                                   │                     │
                                   └──► Part 4 checkpoints ─┐
Part 5 part format (Dart) ─────────────────────────────────┼─► Part 8 finalize/recover/held ─► Part 9 recorder state ─► Part 10 USB recovery
Part 6 schema step + identity ─► Part 7 bundle publication ┘           │                      (+ USB P6)
Part 11 guard registry ─► Part 12 power/restart/device/latency        Part 13 Record page (+ Library P7)
Part 7 ─► Part 14 inspection + candidate ─► Part 15 recovery UI (+ #1200 P5 for the backing row)
Part 14 ─► Part 16 port bindings ─► Part 17 port repair UI ─► Part 18 CTRL/MIDI rows (needs #1206)
Part 14 ─► Part 19 target inspection ─► Part 20 target repair UI
```

## 5. Parts

### Part 1: SHA-256, file digests and directory sync (built: `claude/recording-1198-p1` `616b8b694`, PR #1220; about 260 production lines; native + bindings; depends on nothing)

- `src/core/engine_digest.c` / `engine_digest.h`: SHA-256 written from
  FIPS 180-4 and checked against its vectors (no third-party code fetched);
  named `engine_*.c` so the existing globs in `run_native_tests.sh`,
  `build_test_lib.sh` and the benches pick it up; registered in
  `CMakeLists.txt` and both Apple forwarders. The streaming context is in an
  internal header that `engine_private.h` does not include, so it never
  reaches the VST3 C++ units (PROGRESS "Adding a header to `src/core/`").
- `segno_engine_api.h`: `le_digest_bytes(const void*, uint64_t len, uint8_t out[32])`,
  `le_digest_file(const char* path, uint64_t offset, uint64_t length, uint8_t out[32])`
  (64 KiB reads, `length = UINT64_MAX` means to end of file, `LE_ERR_DEVICE`
  on a short, missing or non-regular file), `le_fs_sync_dir(const char* path)`
  (`open(O_RDONLY|O_DIRECTORY)` + `fsync`; on Windows an existence check).
  All engine-free.
- Dart: a standalone `StorageIo` / `NativeStorageIo` (not an `AudioEngine`
  member: engine-free calls must be constructible inside `Isolate.run`), with
  the library opener shared from `lib/src/engine_library.dart`.

```success-criteria
GOAL: The engine exposes one SHA-256 implementation over memory and over a file range, and a directory fsync, all usable without an engine.
SUCCESS CRITERIA:
- le_digest_bytes("", 0) = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855; "abc" = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad; the 448-bit NIST message "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq" = 248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1; the 896-bit message = cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1; one million 'a' = cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0, also when fed in uneven chunks. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- le_digest_file over bytes [3, 6) of a file holding "xyzabcdef" equals the "abc" digest; over [0, UINT64_MAX) equals le_digest_bytes of the whole content; a range past the end returns LE_ERR_DEVICE; a missing path or a directory returns LE_ERR_DEVICE. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- le_fs_sync_dir returns LE_OK on an existing directory and LE_ERR_DEVICE on a missing one. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- ASan and telemetry-off builds pass; bindings regenerated and formatted; symbol parity holds; the C++ shim repro still compiles. | verify: EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-DLE_CALLBACK_TELEMETRY=0' bash packages/segno_engine/src/test/run_native_tests.sh && dart analyze --fatal-infos && packages/segno_engine/tool/check_ffi_symbols.sh <built lib>
- The Dart wrappers return the same digests through the real library, including from Isolate.run. | verify: (cd packages/segno_engine && SEGNO_ENGINE_LIB=$(bash tool/build_test_lib.sh) /Users/Tomas/development/flutter/bin/flutter test)
NON-GOALS:
- Any caller; ARMv8 SHA instructions.
VERIFICATION COMMAND: bash packages/segno_engine/src/test/run_native_tests.sh && (cd packages/segno_engine && /Users/Tomas/development/flutter/bin/flutter test) && dart analyze --fatal-infos
```

### Part 2: the drain writes ordered float WAV parts (about 640 production lines; native + bindings; depends on Part 1)

- `segno_engine_api.h`: replace `le_perf_arm(engine, const char*)` with
  `le_perf_arm(le_engine*, const le_perf_target*)` (no old form kept,
  AGENTS.md):

  ```c
  typedef struct le_perf_target {
    const char* capture_dir;      /* the bundle directory on the destination */
    const char* live_sidecar_dir; /* where performance.json is rewritten each
                                     cycle: capture_dir on Internal, the
                                     Internal mirror directory for USB (D1) */
    const char* mirror_dir;       /* Internal mirror for checkpoint copies;
                                     NULL = none (Part 4) */
    uint8_t take_id[16];
    int64_t volume_generation;    /* -1 Internal; recorded in checkpoints (D4) */
    uint64_t part_bytes;          /* 2000000000; tests pass small sizes */
    int32_t ring_seconds;         /* 2 Internal, 8 removable, capped (D2) */
    uint64_t reserve_bytes;       /* UINT64_MAX = no budget (Part 3) */
    int32_t checkpoint_ms;        /* 5000; 0 = only on demand (Part 4) */
  } le_perf_target;
  ```

  `ring_seconds` replaces the fixed `LE_PERF_CAPTURE_SECONDS`
  (`engine_private.h:163`, `engine_commands.c:4540`), with the 64 MiB total
  cap of D2 applied at arm; `reserve_bytes`, `mirror_dir` and
  `checkpoint_ms` are stored here and used by Parts 3 and 4. New error codes,
  if any are needed, come from this plan's assigned range (LE_ERR −18, −19;
  numbering ledger).
- `perf_drain.c`: `le_pd_file` becomes a part stream (`stream`, `channels`,
  `part_index`, `frames_in_part`, `frames_total`, `overs_in_part`, an
  `le_sha256_ctx`). The ring drain writes popped float blocks as they are
  (little-endian float32 is the native layout on every target), counts
  samples with `fabsf(x) > 1.0f` into `overs_in_part` in the same pass that
  feeds the digest, splits the write at the part boundary, seals the full
  part (patch sizes at offsets 4 and 80, `fflush`, digest), and opens the
  next with `O_CLOEXEC` descriptors (closing the inheritance window
  `perf_drain.c:456-462` describes). Torn-write flooring
  (`le_pd_whole_frames_landed`, `:972`) and the zero-fill (`:1069`) are
  unchanged in frame bytes (4 × channels). Seal on stop. `events.log` and
  layer files are unchanged. The sidecar is written into `live_sidecar_dir`.
- Sidecar: `parts` (new key): `[{stream, index, file, frames, bytes, overs,
  sha256?}]`, `sha256` present once sealed; `take_id` (hex); `encoding:
  "f32"`; `overs` (the take's total). `channel_layout` keeps its meaning.
- Dart: `perfArm(PerfTarget)` in `EnginePerformanceCapture`
  (`audio_engine.dart:1434`) and `native_audio_engine.dart:2275`; the
  repository passes Internal values (`part_bytes` 2,000,000,000,
  `ring_seconds` 2, `reserve_bytes` UINT64_MAX until Part 3,
  `checkpoint_ms` 0 until Part 4) and a minted `takeId`; `_finalize` reads
  the parts instead of `master.pcm` only far enough to keep crash salvage
  working (it writes no `master.wav`; Part 8 replaces it).

Native tests (in `test_engine_core.c`, beside `test_perf_drain_writes_master_pcm_byte_identical` `:9917`):

```success-criteria
GOAL: A capture is written as ordered, sealed, self-identifying float WAV parts that need no conversion at finalize and keep every sample as captured.
SUCCESS CRITERIA:
- With configure(48000, 1 in, 2 out) and a stereo master, the first 84 bytes of master-001.wav equal Part 5's literal header fixture: "RIFF", u32 size, "WAVE", "fmt ", 16, tag 3, channels 2, rate 80 BB 00 00, byte rate 00 DC 05 00 (384000), block align 8, bits 32, "sgno", 32, the 16 take-id bytes, stream 0, part index 1, 12 zero bytes, "data", u32 size. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- Pumped samples 0.5, -1.0, 1.5, -2.0 are written as 00 00 00 3F, 00 00 80 BF, 00 00 C0 3F, 00 00 00 C0 (unchanged), and the part's sidecar entry reads overs 2. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- part_bytes = 84 + 8 * 1000 and 2500 pumped stereo frames give master-001.wav and master-002.wav of 8084 bytes each and master-003.wav of 4084 bytes after disarm, each with its RIFF size (file size - 8) and data size patched, and part indexes 1, 2, 3 in their sgno chunks. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- Each sealed part's sidecar sha256 equals le_digest_file over its data payload, and equals le_digest_bytes of the float bytes the test builds from the pumped samples. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- The existing short-write, zero-fill, disk-full, crash-consistency and allocation-free drain tests pass; a part boundary inside a zero-fill gap still yields whole frames on both sides. | verify: bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-DLE_CALLBACK_TELEMETRY=0' bash packages/segno_engine/src/test/run_native_tests.sh
- An input captured at arm gets input-<n>-001.wav, stereo, stream 1 + n; 33 captured streams at 96 kHz with ring_seconds 8 arm with total ring memory at most 64 MiB and the granted seconds reported. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- With live_sidecar_dir different from capture_dir, no file other than parts, events.log and layer files is created in capture_dir. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- Bindings regenerated; symbol parity; the repository arms through PerfTarget and its package tests pass. | verify: (cd packages/performance_repository && /Users/Tomas/development/flutter/bin/flutter test) && dart analyze --fatal-infos
NON-GOALS:
- Stop rules, checkpoints, finalize and recovery rewrite, any UI.
VERIFICATION COMMAND: bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-DLE_CALLBACK_TELEMETRY=0' bash packages/segno_engine/src/test/run_native_tests.sh && dart analyze --fatal-infos
```

### Part 3: stop at complete frames on reserve and on slow storage (about 380 production lines; native + bindings; depends on Part 2)

- Audio thread: `perf.first_drop_frame` (`_Atomic uint64_t`, `UINT64_MAX`
  at arm). `perf_push_master` and `perf_tap_monitor_frame`
  (`engine_process.c:4133-4139`, `:4288-4293`) take the frame index; the
  first failure stores `perf_frame_base + f` (`:6353-6354`). The audio thread
  is the only writer; the release add at `:6875-6879` publishes it.
- Drain: before writing, `limit = min(elapsed, first_drop_frame)` and, with a
  budget, `limit = min(limit, frames_written + remaining_frames_together(...))`
  where the budget is `free_at_sample - reserve_bytes - 1 MiB -
  written_since_sample` and `remaining_frames_together` is the C twin of
  Part 5's Dart function (one header per new part per stream). The free
  sample is refreshed on the checkpoint cadence (Part 4; with `checkpoint_ms`
  0 the drain samples on each 20th cycle). Streams stop at `limit` together;
  the drain seals and self-stops with reason `slow_storage` or
  `reserve_reached`. `le_pd_catch_up` pads only to `limit`.
- Test hook `le_perf_drain_set_volume_free_for_test(int64_t)` beside the
  existing write-budget hook (`engine_internal.h:368`).
- `le_perf_stop_reason` enum: `NONE 0`, `DISARM`, `DEVICE_CHANGED`,
  `WRITE_FAILED`, `RESERVE_REACHED`, `SLOW_STORAGE`; snapshot tail fields
  `perf_stop_reason`, `perf_bytes_written`, `perf_first_drop_frame`,
  `perf_overs` (appended at the struct tail, offset-stable). Sidecar strings:
  `reserve_reached`, `slow_storage`; `disk_full` and `device_changed` keep
  their spelling.
- Dart: `PerfStopReason` and `perfOvers` on the snapshot; the repository
  passes the destination's reserve (Internal 1 GiB, removable 16 MiB).

```success-criteria
GOAL: A take ends at the last whole frame every stream can hold when the reserve is reached or the drain falls behind, and says why.
SUCCESS CRITERIA:
- Mono master, part_bytes 2e9, reserve R, volume-free hook = R + 1048576 + E + 84 + 4 * 700, where E is events.log's size after the arm cycle as the test reads it: after pumping 1000 frames the take holds exactly 700 frames, stopped_early is "reserve_reached", perf_stop_reason reads RESERVE_REACHED, zero_filled_frames is 0. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- The same with one captured stereo input: per-frame bytes are 4 + 8, so the free hook R + 1048576 + E + 84 + 84 + 12 * 500 stops both files at exactly 500 frames. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- A budget that runs out one frame after a part boundary (part_bytes 84 + 4 * 300, free for 300 frames + one more header + one frame) stops at 301 frames with two parts. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- With the drain held by the mid-cycle hook and ring_seconds 1, pumping 3 s of audio records a first_drop_frame F with 0 < F < 144000; after release master holds exactly F frames, stopped_early is "slow_storage", zero_filled_frames is 0, and no frame pumped after the drop appears. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- A tap gap without a drop (frames counted but not tapped) still zero-fills and the take continues (the existing #710 test passes unchanged). | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- reserve_bytes = UINT64_MAX never stops on budget; a refused write still stops as "disk_full". | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- ASan, telemetry-off, the allocation-free cycle test, bindings and symbol parity. | verify: EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-DLE_CALLBACK_TELEMETRY=0' bash packages/segno_engine/src/test/run_native_tests.sh && dart analyze --fatal-infos
NON-GOALS:
- Checkpoints, the recorder's reaction, the 60-second warning.
VERIFICATION COMMAND: bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-DLE_CALLBACK_TELEMETRY=0' bash packages/segno_engine/src/test/run_native_tests.sh
```

### Part 4: durable two-slot checkpoints and the Internal mirror (about 480 production lines; native; depends on Part 2)

- `perf_drain.c`: the published-progress block (mutex, a few integers per
  stream including the open part's overs, sealed digests and overs,
  `events.log` bytes, layer files written since the last checkpoint),
  updated after each cycle's `fflush` (`perf_drain.c:1426-1431`).
- `perf_checkpoint.c` (new, `perf_checkpoint.h` included only by
  `perf_drain.c`): the thread started and joined with the drain session; the
  loop of D4; slot files `checkpoint-a.json` / `checkpoint-b.json` with keys
  `version: 1`, `sequence`, `take_id`, `boot_id`, `volume_generation`,
  `sample_rate`, `encoding: "f32"`, `frames`, `overs`, `streams[{stream,
  channels, parts[{index, file, frames, bytes, overs, sha256?}]}]`,
  `events_bytes`, `layers[]`, `written_at_ms`, then `checksum` (SHA-256 hex of
  every byte before the `"checksum"` key); written by truncate, write,
  `fsync`, alternating slots, in `capture_dir` and then in `mirror_dir` when
  set; a final checkpoint after the drain's last cycle on every stop path,
  including self-stops and `DEVICE_CHANGED` (`engine.c:384-387`). Failures
  increment `perf_checkpoint_failures` (snapshot tail) and leave the other
  slot standing.
- `le_perf_checkpoint_now_for_test(engine)` for deterministic tests.
- `docs/design/performance-manifest-format.md`: the slots, the mirror's
  authority for USB takes, the trust rule (boot, continuous mount, mirror)
  and the 5 s guarantee (#727's "decide what durability is owed").

```success-criteria
GOAL: Every few seconds the bundle durably records how much audio it holds, without blocking the drain and without ever renaming over a file, and the same record lands on Internal.
SUCCESS CRITERIA:
- With checkpoint_ms 0: pump 1500 frames, run a drain cycle, checkpoint now → the newest valid slot reads sequence 1, frames 1500, master part 1 frames 1500, bytes 84 + 8 * 1500 (stereo), events_bytes equal to events.log's size; pump 500 more and checkpoint → the other slot reads sequence 2 and frames 2000, and the first still reads 1500. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- Each slot's checksum equals le_digest_bytes of its bytes before the "checksum" key; flipping one byte of the newest slot makes the reader (a test helper sharing the parser) return the older slot. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- The mirror's slots are byte-identical to the bundle's after each checkpoint; with mirror_dir NULL nothing else is written; no rename(2) targets an existing file during a take (a rename interposer counts zero). | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- A checkpoint never names more frames than the drain had flushed when it copied the progress block: with the mid-cycle hook pausing the drain between pop and flush, a concurrent checkpoint reads the previous cycle's count. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- A refused slot write (write-budget hook applied to the slot path) leaves the other slot valid, increments perf_checkpoint_failures, and the take continues. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- Disarm, a self-stop and a reconfigure while armed each leave a final checkpoint whose frames equal the sealed parts' frames. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- The drain cycle stays allocation-free with the checkpoint thread running (the allocator interposer counts only the drain thread). | verify: bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-DLE_CALLBACK_TELEMETRY=0' bash packages/segno_engine/src/test/run_native_tests.sh
- HARDWARE: on the appliance, a 20-minute Internal take, a 20-minute exFAT USB take and a 20-minute FAT32 USB take mounted with `flush` each read perfZeroFilledFrames 0 and perfOverruns 0 with checkpoints running, and the USB bundle receives no per-cycle file (inotify on the stick's take directory counts only part, layer and slot writes); cut power at minute 10 and confirm the next boot recovers at least 9:55. | verify: manual on device
NON-GOALS:
- Dart recovery logic, UI.
VERIFICATION COMMAND: bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-DLE_CALLBACK_TELEMETRY=0' bash packages/segno_engine/src/test/run_native_tests.sh
```

### Part 5: the part format in Dart (about 420 production lines; `wav_codec` + `performance_repository` models; depends on Part 1 for the slot checksum)

- `packages/wav_codec`: `RecordedPartHeader` (read and write the 84-byte
  float header, including `sgno`), `RecordedPartWriter` (a streaming writer
  over a `RandomAccessFile`: header, append float blocks unchanged while
  counting `overs`, seal with sizes and `flush`), `readRecordedPartFrames`
  (bounded range reads), and `WavCodec.decodeFloat32(bytes, {maxFrames})`
  (the bound the Library's audition needs, Library plan D10). `wav_codec` is
  the one Dart WAV reader (D3, review M7).
- `performance_manifest.dart`: `RecordingFormat(sampleRate, channels,
  partBytes)` with `partFrames`, `bytesToAppend`, and
  `remainingFramesTogether(streams, budgetBytes)` (every stream, a header per
  new part, frames ending together; the one function D2 names); `TakePart(stream,
  index, file, frames, bytes, overs, sha256)`; the manifest's `parts`,
  `takeId` and `overs`; `TakeCheckpoint.fromSlots(a, b, verify)` choosing the
  newest slot whose checksum `verify` accepts (the caller passes
  `StorageIo.digestBytes`, Part 1).

```success-criteria
GOAL: Dart can read, write and account for the native float part format and its checkpoint slots without loading a part into memory.
SUCCESS CRITERIA:
- RecordedPartHeader round-trips the literal 84-byte native header of Part 2's first criterion byte for byte (tag 3, byte rate 384000, block align 8, 32 bits). | verify: (cd packages/wav_codec && /Users/Tomas/development/flutter/bin/flutter test)
- RecordingFormat(48000, 2).partFrames == 249999989 (1:26:48), a full part is 1999999996 bytes; mono partFrames == 499999979 and a full part is exactly 2000000000 bytes; remaining frames with 63000000000 bytes and no open part == 7874999664 (31 full parts, then 125000005 frames), and those frames cost exactly 63000000000 bytes. | verify: (cd packages/performance_repository && /Users/Tomas/development/flutter/bin/flutter test)
- remainingFramesTogether of a mono master and one stereo input, no parts open, with 84 + 84 + 12 * 500 bytes, is 500. | verify: (cd packages/performance_repository && /Users/Tomas/development/flutter/bin/flutter test)
- RecordedPartWriter writes 0.5, -1.0, 1.5, -2.0 as 00 00 00 3F, 00 00 80 BF, 00 00 C0 3F, 00 00 00 C0 and seals overs 2; readRecordedPartFrames returns the same floats exactly; decodeFloat32(maxFrames: 10) of a 1000-frame file returns 10 frames. | verify: (cd packages/wav_codec && /Users/Tomas/development/flutter/bin/flutter test)
- TakeCheckpoint.fromSlots picks the higher valid sequence, falls back to the other slot when a checksum fails, and throws FormatException when neither is valid. | verify: (cd packages/performance_repository && /Users/Tomas/development/flutter/bin/flutter test)
- wav_codec and performance_repository coverage floors hold; analyzer clean. | verify: (cd packages/wav_codec && /Users/Tomas/development/flutter/bin/flutter test --coverage) && (cd packages/performance_repository && /Users/Tomas/development/flutter/bin/flutter test --coverage) && dart analyze --fatal-infos
NON-GOALS:
- Repository behaviour, native code.
VERIFICATION COMMAND: (cd packages/wav_codec && /Users/Tomas/development/flutter/bin/flutter test) && (cd packages/performance_repository && /Users/Tomas/development/flutter/bin/flutter test) && dart analyze --fatal-infos
```

### Part 6: session audio identity and the schema step (about 380 production lines; `session_repository`; depends on Part 1 and #1196's chain)

- `SessionLayer` gains `audioId`, `frames`, `sampleRate`, `channels`,
  `encoding`; `unverified` when `audioId` is absent
  (`models/session.dart:13-25`). New schema version: the next free number
  when this part lands (14 if Peel 12 and Reverse 13 are in); its migration
  step in #1196's chain maps each old layer to `{file, unverified: true}`
  and keeps everything else. If #1196 has not landed, this part waits for
  it (every bump must add its step to that chain).
- `_capture` (`session_repository.dart:638`) asks the engine for each
  exported layer's digest through `le_digest_bytes` on the exported buffer
  (one call per layer, off the UI isolate for buffers over 8 MB).
- `docs/design/session-bundle-format.md`: the identity fields and the
  unverified rule.

```success-criteria
GOAL: Every saved layer records its exact identity, format and length; older layers are marked unverified, never guessed.
SUCCESS CRITERIA:
- A save of a known 4-frame layer [0.0, 0.5, -0.5, 1.0] records audioId "sha256:" + the digest of bytes 00000000 0000003F 000000BF 0000803F (computed in the test with le_digest_bytes over that literal), frames 4, sampleRate 48000, channels 1, encoding "f32". | verify: (cd packages/session_repository && /Users/Tomas/development/flutter/bin/flutter test)
- A previous-version fixture migrates with every layer unverified and every other field unchanged; the chain's no-skipped-version test passes with the new step. | verify: (cd packages/session_repository && /Users/Tomas/development/flutter/bin/flutter test)
- Session coverage floor (89%) and analyzer hold. | verify: (cd packages/session_repository && /Users/Tomas/development/flutter/bin/flutter test --coverage) && dart analyze --fatal-infos
NON-GOALS:
- The content-addressed file layout and the commit protocol (Part 7), recovery.
VERIFICATION COMMAND: (cd packages/session_repository && /Users/Tomas/development/flutter/bin/flutter test) && dart analyze --fatal-infos
```

### Part 7: content-addressed audio through the Library's save-back swap (about 520 production lines; `session_repository`; depends on Parts 1 and 6, Library Parts 1 and 3 including #1203)

- Extends the swap that #1203 put in `SessionRepository`
  (`origin/claude/library-1178-p3` `9c646c2de`, `_writeBundle`
  `:1065-1129`, `_swapIn` `:1153-1175`, `_recoverInterruptedSwaps`
  `:1177-1209`); no second mechanism (D5, review M3).
- `_writeBundle` into `<id>.saving/`: layers under `audio/<hex>.wav`; a layer
  already in `<id>/audio/` is hard-linked (`Link` is a symlink in Dart, so
  the hard link is one more engine-free call next to Part 1's, `le_fs_link`,
  in this plan's API space); a new layer is written as `.part`, flushed,
  renamed; then the manifest, flushed; then `le_fs_sync_dir` on `audio/` and
  the staging directory. The bytes of new layers are summed first and
  refused with `StorageFailure.full` before anything is written.
  `_carryForeignFiles` (`:1131-1151`) keeps its job; `_pruneOrphanLayers`
  goes (nothing unreferenced is linked in).
- `_swapIn` ends with `le_fs_sync_dir` on the parent.
- `_recoverInterruptedSwaps` gains the roll-forward rule of D5 (`<id>`
  absent, `<id>.old` present, a complete `<id>.saving` → rename it in),
  `.deleting` (finish the delete), and `*.part` inside a bundle (delete).
  `_isTransient` (`:1056-1057`) recognises `.deleting`.
- Delete (Library Part 3) renames to `<id>.deleting` and then removes it.
- `read` loads layers by `file`, unchanged in shape; digest checks are
  Part 14's.

```success-criteria
GOAL: A session save, Save as, duplicate, delete, move or restore either fully happens or leaves the previous state, through the one swap the Library already uses, without rewriting unchanged audio.
SUCCESS CRITERIA:
- Re-saving an unchanged rig writes no audio bytes (an injected file writer records zero layer writes; the staged audio files are hard links with the same inode as the previous ones); adding one overdub writes exactly one new audio/<hex>.wav. | verify: (cd packages/session_repository && /Users/Tomas/development/flutter/bin/flutter test)
- An injected failure after the second of three new audio files leaves <id> byte-identical, and the next catalog read deletes the stale <id>.saving. | verify: (cd packages/session_repository && /Users/Tomas/development/flutter/bin/flutter test)
- A crash between the swap's two renames: with a complete <id>.saving the next catalog read renames it in and the new rig opens; with an incomplete one (a referenced file missing) it restores <id>.old and the previous rig opens. | verify: (cd packages/session_repository && /Users/Tomas/development/flutter/bin/flutter test)
- After a save, legacy track*_lane*_L*.wav files are gone and every referenced file exists. | verify: (cd packages/session_repository && /Users/Tomas/development/flutter/bin/flutter test)
- New bytes larger than the injected free space throw StorageFailure.full with nothing written. | verify: (cd packages/session_repository && /Users/Tomas/development/flutter/bin/flutter test)
- Delete interrupted after its rename is finished by the next catalog read, and an .old with no live bundle and no staging is restored, never deleted. | verify: (cd packages/session_repository && /Users/Tomas/development/flutter/bin/flutter test) && /Users/Tomas/development/flutter/bin/flutter test test/session test/library
- The real-engine layer round trip still restores every undo/redo layer byte-exact. | verify: /Users/Tomas/development/flutter/bin/flutter test test/session/session_layers_roundtrip_test.dart
- HARDWARE: on the appliance, cut power during a save of a session with 40 layers, ten times; every boot opens either the previous or the new session, never neither. | verify: manual on device
NON-GOALS:
- Recovery UI, performance takes, USB backup format.
VERIFICATION COMMAND: (cd packages/session_repository && /Users/Tomas/development/flutter/bin/flutter test --coverage) && /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos && bloc lint lib test packages
```

### Part 8: finalize, recover and hold without copying (about 660 production lines; `performance_repository`; depends on Parts 2, 3, 4, 5)

- `_finalize` (`performance_repository.dart:941-1046`): read the newest valid
  checkpoint slot and the sidecar, verify each sealed part's size, write the
  manifest with `parts` (including `overs`), `takeId`, `format`, `overs` and
  `finalized: true`: on Internal by tmp + flush + rename + `le_fs_sync_dir`;
  on a removable volume fresh with a trailing `checksum` (D5). No PCM read,
  no `master.wav`. `_readRawPcm` goes.
- `recoverCapture` (`:628-629`): the D4 trust rule. Present frames are
  trusted only with the same boot id (injected reader over
  `/proc/sys/kernel/random/boot_id`), the same volume generation as at arm
  (Internal always), and a bundle-side checkpoint; otherwise the
  checkpoint's frames. Parts the checkpoint does not list are removed; the
  last kept part of each stream is truncated, its sizes patched, its digest
  and overs recomputed (`le_digest_file` in `Isolate.run`, a bounded float
  scan for overs); then finalize as above.
- Legacy bundles (`master.pcm` present, no parts): one stream at a time,
  re-chunk the float `.pcm` into float parts with `RecordedPartWriter` in
  1 MiB chunks in `Isolate.run` (no sample changes; overs counted), write an
  interim manifest naming that stream's parts, sync, then remove that
  `.pcm`; the space check is the largest stream's size (review L4). Not
  enough space leaves the bundle untouched for the next start and reports it
  (#1078's "surface a recoverable failure").
- Held takes: `captureStatus` gains `held(reason)`; on a native self-stop or
  an engine-ended capture (snapshot `isPerfArmed` false while
  `_armedDir != null`) the repository calls `perfDisarm`, keeps the
  directory, releases the capture guard (D8, review M4) and reports `held`.
  `saveHeld()` takes a `transfer` lease while it runs the recovery finalize;
  `discardHeld()` renames to `.discarding-<slug>` and deletes.
- `unfinishedTakes()` (D9, review M5) replaces the silent boot salvage for
  new takes: Internal bundles without a finalized manifest become held takes
  at start; `.discarding-*` are finished. Bundles already in `recovered/`
  stay there; the 30-day prune (`:868-899`) is removed (owner decision:
  recovered takes are kept; the Library's Delete for recordings frees
  space, Library Part 7, review M9).
- `listCaptures()` (Library Part 7's method, if already merged; otherwise
  added here with Library Part 7's signature) returns duration and `overs`
  from `parts` and includes `recovered/` takes marked `recovered: true` (pen
  48 `Z3V6Z` shows a recovered take in the Library; Library Part 7 excluded
  them).

```success-criteria
GOAL: A take finalizes and recovers in bounded memory without copying audio, recovery never trusts bytes a pulled or power-cut drive may not hold, a stopped take is held for the player's choice, and legacy raw captures are recovered unchanged.
SUCCESS CRITERIA:
- Finalize of a three-part fixture writes a manifest whose parts list matches the checkpoint and whose sha256 values match le_digest_file of each part; no file other than performance.json is created or changed. | verify: (cd packages/performance_repository && /Users/Tomas/development/flutter/bin/flutter test)
- Recovery of a stereo fixture whose checkpoint says 1000 frames and whose open part holds 1500: with a different boot id the part is truncated to 84 + 8 * 1000 bytes with data size 8000; with the same boot id and generation it keeps 1500 frames; with the same boot id and another generation (a detach and re-attach in the same boot) it is truncated to 1000; all read back as finalized. | verify: (cd packages/performance_repository && /Users/Tomas/development/flutter/bin/flutter test)
- A part that rolled over after the checkpoint is removed, and a part sealed after it is truncated, re-patched and re-digested. | verify: (cd packages/performance_repository && /Users/Tomas/development/flutter/bin/flutter test)
- A legacy master.pcm plus input-0.pcm fixture converts one stream at a time through a reader that records its largest read (at most 1 MiB); each .pcm is removed only after its parts and the interim manifest exist; sample bytes are unchanged; with injected free space below the largest stream the bundle is untouched and the failure is reported. | verify: (cd packages/performance_repository && /Users/Tomas/development/flutter/bin/flutter test)
- A fake engine reporting reserve_reached, slow_storage, disk_full or isPerfArmed false emits held(reason) and leaves no guard held; saveHeld finalizes under a transfer lease; discardHeld removes the bundle after the .discarding rename; a crash between the two is finished at the next start. | verify: (cd packages/performance_repository && /Users/Tomas/development/flutter/bin/flutter test)
- An unfinalized Internal bundle at start is reported by unfinishedTakes and not moved; a recovered/ bundle older than 30 days is not deleted. | verify: (cd packages/performance_repository && /Users/Tomas/development/flutter/bin/flutter test)
- Performance repository coverage floor (99%) holds. | verify: (cd packages/performance_repository && /Users/Tomas/development/flutter/bin/flutter test --coverage)
- HARDWARE: the 38 GB capture on the appliance (#1078) recovers into parts without the app exceeding 200 MB RSS growth, and plays in the Library. | verify: manual on device
NON-GOALS:
- Recorder cubit and UI, USB mirror recovery.
VERIFICATION COMMAND: (cd packages/performance_repository && /Users/Tomas/development/flutter/bin/flutter test --coverage) && (cd packages/wav_codec && /Users/Tomas/development/flutter/bin/flutter test) && dart analyze --fatal-infos
```

### Part 9: recorder state for long, held and failed takes (about 500 production lines; `lib/performance/cubit`; depends on Part 8 and USB Part 6)

- `PerformanceStopReason` (`performance_recorder_state.dart:5-18`) gains
  `reserveReached`, `slowStorage`, `volumeLost` (USB Part 6 adds it; reused)
  and keeps `diskFull` for write failures (copy that does not claim a full
  disk, as the enum's own note demands) and `deviceChanged`.
- States: `Armed` gains `remaining: Duration?`, `format: RecordingFormat`,
  `streams`, `parts: List<TakePart>`, `overs`, `nearlyFull: bool`
  (remaining < 60 s); `Held(reason, elapsed, parts, overs, saveFailed,
  waitingForDrive)`; `Completed` unchanged for a normal Stop.
- `PerformanceRecorderCubit`: remove `lowDiskThresholdBytes`,
  `finalizeHeadroomBytes`, `stopFloorFor`, `_checkLowDisk` and
  `_stopForLowDisk` (`:97-123`, `:411-463`). USB Part 6 routes `volumeLost`
  through `_stopForLowDisk`; that route becomes the repository's
  `held(volumeLost)` (review note). Arm refusal and remaining time both come
  from `remainingFramesTogether` over every captured stream with the
  destination's reserve and the allowance (D2, review M2), on the existing
  20-tick cadence; `saveRecovered()`, `discardRecording()`; the device-loss
  path through the repository's `held(deviceChanged)` (fixes the stale Armed
  state of §1).

```success-criteria
GOAL: The recorder reports remaining time and parts for every stream it writes, and holds every interrupted take for an explicit Save or Discard.
SUCCESS CRITERIA:
- With 64 GB free, 1 GiB reserve, 48 kHz stereo master and two captured stereo inputs the Armed state's remaining equals remainingFramesTogether over all three streams (24 bytes a frame), a third of the master-only figure; at 59 s remaining nearlyFull is true; with unknown space remaining is null and arming still succeeds. | verify: /Users/Tomas/development/flutter/bin/flutter test test/performance
- On a removable destination with only the master, nearlyFull turns on 60 s before the 16 MiB floor, not after it. | verify: /Users/Tomas/development/flutter/bin/flutter test test/performance
- Arming when the destination cannot hold 10 s of every stream above its reserve, the allowance and one header per stream is refused with noRecordingSpace and arms nothing; one byte more arms. | verify: /Users/Tomas/development/flutter/bin/flutter test test/performance
- held(reserveReached) emits Held; saveRecovered emits Finalizing then Completed; a throwing save emits Held(saveFailed: true) and a second saveRecovered succeeds; discardRecording emits Idle only after the repository confirms; a lease lost while armed emits Held(volumeLost). | verify: /Users/Tomas/development/flutter/bin/flutter test test/performance
- A device loss while armed (fake engine: isPerfArmed false) emits Held(deviceChanged) within one tick, not Armed. | verify: /Users/Tomas/development/flutter/bin/flutter test test/performance
- No lowDiskThresholdBytes, finalizeHeadroomBytes, stopFloorFor or _stopForLowDisk remain. | verify: ! grep -rn -E 'lowDiskThresholdBytes|finalizeHeadroomBytes|stopFloorFor|_stopForLowDisk' lib test
- Root coverage, analyzer, Bloc lint. | verify: /Users/Tomas/development/flutter/bin/flutter test --coverage && dart analyze --fatal-infos && bloc lint lib test packages
NON-GOALS:
- Widgets (Part 13), USB reconnect (Part 10).
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos && bloc lint lib test packages
```

### Part 10: direct-USB ownership and same-drive recovery (about 520 production lines; depends on Parts 4, 8, 9 and USB Part 6)

- Arm on a removable destination: `capture_dir =
  <mount>/Segno/Performances/<slug>/`, `live_sidecar_dir` and `mirror_dir`
  `= {exportsRoot}/.takes/<takeId>/`, `ring_seconds` 8 (capped, D2),
  `reserve_bytes` 16 MiB, `volume_generation` the volume's; the repository
  writes the arm snapshot to the mirror too, with the volume `fingerprint`,
  `generation` and `label`. The `recording` lease (USB Part 6) and the
  `capture` guard are held while the take records and released when it is
  finalized or held (review M4).
- `unfinishedTakes()` (Part 8) also lists every mirror without a finalized
  bundle, at start and on every volume event (review M5): a mounted volume
  with the mirror's fingerprint holding the bundle → held with Save enabled
  (this covers a power cut with the stick still attached); no such volume →
  `Held(waitingForDrive: label)`. Recovery reads the mirror's slots as
  authoritative (M1), verifies each part's `sgno` chunk (`take_id`, stream,
  index) and sealed digest, and always trusts only the checkpoint (D4,
  review H2: the volume was not continuously mounted, or recovery is
  mirror-driven); then it finalizes on the drive and deletes the mirror. A
  different drive is ignored.
- Discard of a USB take whose drive is absent removes only the mirror after
  the confirm, stating that the parts stay on the drive.

```success-criteria
GOAL: A take recorded to USB is owned by that drive, survives a pull or power cut as a held take that blocks nothing, and is recovered only from the same drive's exact parts, to the durable checkpoint.
SUCCESS CRITERIA:
- With a fake mounted volume, arming to USB creates <mount>/Segno/Performances/<slug>/ and .takes/<takeId>/ on Internal, the PerfTarget has the mirror and live-sidecar directories on Internal, ring_seconds 8 and reserve 16 MiB, and a recording lease and capture guard are held. | verify: (cd packages/performance_repository && /Users/Tomas/development/flutter/bin/flutter test) && /Users/Tomas/development/flutter/bin/flutter test test/performance
- Detach while armed → Held(volumeLost, waitingForDrive: 'SEGNO USB') with no guard or lease held, so power off, Open and eject of another drive proceed; attaching a volume with another fingerprint changes nothing; attaching the same fingerprint enables save; saveRecovered truncates to the mirror's checkpoint even though the file on the stick is longer, finalizes on the drive and removes the mirror. | verify: /Users/Tomas/development/flutter/bin/flutter test test/performance
- At start with a mirror and its bundle present on a mounted volume (power cut with the stick attached), the take is held with Save enabled; with the volume attaching after start, the attach event does the same. | verify: /Users/Tomas/development/flutter/bin/flutter test test/performance
- A part whose sgno take id differs, or whose sealed digest does not match, makes recovery refuse with the part named and leaves everything untouched. | verify: (cd packages/performance_repository && /Users/Tomas/development/flutter/bin/flutter test)
- Eject of the volume is refused while the take records; an export or backup to that volume is refused while the take records. | verify: /Users/Tomas/development/flutter/bin/flutter test test/storage test/performance
- HARDWARE: record to an exFAT stick with loops playing; pull it at 1:00; loops keep playing and the page reads "Reconnect SEGNO USB. Saved parts stay on that drive."; power off works while it is held; reinsert, Save recovered audio, and the take plays to at least 0:55 on a laptop with no stale audio after the checkpoint; repeat with a power cut instead of a pull, with the stick attached; repeat on FAT32 (mounted with flush) and on NTFS (ntfs3). | verify: manual on device
NON-GOALS:
- Copying a USB take to Internal (Library export/import), the picker itself (USB Part 6).
VERIFICATION COMMAND: (cd packages/performance_repository && /Users/Tomas/development/flutter/bin/flutter test) && /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos && bloc lint lib test packages
```

### Part 11: the guard registry (built: `claude/recording-1198-p11`, PR #1221; about 420 production lines; new `packages/operation_guards` + wiring; depends on nothing)

- The package: `GuardKind`, `GuardScope` (volume generation, optional item),
  the D8 matrix as one `const` table, `GuardRegistry.enter/blockers`,
  `OperationGuard.release`, `ActiveOperationSource` for owners that track
  their own operations, and a `purpose` string for refusals.
  `flutter_package.yml` job with `min_coverage: 100`.
- Wiring built: `PerformanceRepository.arm` takes a `capture` guard at its
  commit (refusal keeps the silent-ok return and emits on `armRefusals`; the
  recorder shows `PerformanceRecorderIdle(refusedBy:)` for the toggle and the
  pedal alike); `SessionCubit.loadNamed` holds `sessionApply` from its
  commit to the end of boot; `SessionRepository.save` holds `sessionWrite`
  on its bundle. One registry from `runSegno` (and `main_mock`) is shared by
  both repositories and `AppRuntime`.
- The review revision of D8 (capture and a writing transfer refuse each
  other on the same volume, review L6) is applied to the table and its
  literal test on the same branch. Releasing the capture guard when a take
  becomes held is Part 8's (the held state does not exist before it).
- **Follow-up for USB Part 6** (routed to the USB builder): `StorageRepository`
  implements `ActiveOperationSource` (each held lease reported as a
  `transfer` at Internal or `removable(generation)` with the lease's purpose,
  an eject in flight as `eject` at `removable(generation)`), and `acquire`
  and `eject` take the registry and call `enter` before registering, so
  shutdown refuses them and they refuse during shutdown or a take on the same
  volume.

```success-criteria
GOAL: Capture, session apply and write consult one table at their commit points, and the table accepts the storage service as a source.
SUCCESS CRITERIA:
- A table-driven test enumerates all 64 (wants, active) pairs, same and different volume, same and different item, against a literal transcription of D8. | verify: (cd packages/operation_guards && /Users/Tomas/development/flutter/bin/flutter test --coverage)
- Operations an ActiveOperationSource reports block exactly as held guards do, and disappear when the source drops them. | verify: (cd packages/operation_guards && /Users/Tomas/development/flutter/bin/flutter test)
- Arming while a session apply holds its guard is refused with refusedBy sessionApply through both the cubit and a direct repository call; the arm creates no directory and calls no perfArm. | verify: /Users/Tomas/development/flutter/bin/flutter test test/performance && (cd packages/performance_repository && /Users/Tomas/development/flutter/bin/flutter test)
- An open is refused at its commit while an audio change holds its guard, before disarm or apply; an open holds sessionApply from disarm through apply and releases it. | verify: /Users/Tomas/development/flutter/bin/flutter test test/session
- A save is refused once a restart guard is held and leaves the bundle untouched; it holds sessionWrite on its bundle while writing and releases it after success and failure. | verify: (cd packages/session_repository && /Users/Tomas/development/flutter/bin/flutter test)
- Analyzer, Bloc lint, root coverage. | verify: /Users/Tomas/development/flutter/bin/flutter test --coverage && dart analyze --fatal-infos && bloc lint lib test packages
NON-GOALS:
- Power, restart, audio apply and latency (Part 12); the storage service's wiring (USB Part 6 follow-up above).
VERIFICATION COMMAND: (cd packages/operation_guards && /Users/Tomas/development/flutter/bin/flutter test) && /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos && bloc lint lib test packages
```

### Part 12: power, restart, audio apply and latency honour the guards (about 430 production lines; `lib/appliance`, `lib/update`, `lib/audio_setup`; depends on Parts 9 and 11)

- Power off (`power_off_gate.dart:48-73`, `power_off_cubit.dart:61-111`):
  a recording performance take is finalized (`disarmAndFinalize`) and the
  session is saved before `restart` is entered (the table refuses a session
  write once restart is active); if the finalize fails the shutdown stops
  on the existing failure face with Retry and no discard shortcut (AB §7.8).
  A held take does not block: its durable state is already on disk or in
  the mirror and it is offered again at the next start (D9, review M4). A
  loop still capturing keeps today's refusal. A transfer or eject refuses
  with `Wait for the USB transfer to finish.`.
- Update restart (`updates_system_tab.dart:262-271`,
  `updates_settings_section.dart:76-97`) runs the same sequence instead of
  its confirm-and-reboot.
- `AudioSetupCubit._persistAndApply` enters `deviceChange` before
  `stopEngine` (`audio_setup_cubit.dart:296`); refusal leaves the draft and
  shows `Stop recording first.`. Latency measurement (`:415-419`, `:478`,
  `audio_bootstrap.dart:301`) enters `calibration`; a restart cancels it.

```success-criteria
GOAL: Shutdown, restart, audio changes and latency measurement wait for or finish the operations that would otherwise corrupt them, at their commit points.
SUCCESS CRITERIA:
- Power off while recording: disarmAndFinalize, then session save, then the restart guard, then halt, in that order (mock call order); a failed finalize stops before halt with Retry. | verify: /Users/Tomas/development/flutter/bin/flutter test test/appliance
- Power off and update restart with a held take (Internal, or USB waiting for its drive) proceed without touching the take, and the take is held again at the next start. | verify: /Users/Tomas/development/flutter/bin/flutter test test/appliance test/update test/performance
- Power off and update restart with a held transfer guard are refused; with a calibration guard the measurement is cancelled and its previous result kept. | verify: /Users/Tomas/development/flutter/bin/flutter test test/appliance test/update test/audio_setup
- Audio apply and latency measurement while a take is armed are refused with the draft unchanged and no stopEngine call; after Stop they proceed. | verify: /Users/Tomas/development/flutter/bin/flutter test test/audio_setup
- Analyzer, Bloc lint, root coverage. | verify: /Users/Tomas/development/flutter/bin/flutter test --coverage && dart analyze --fatal-infos && bloc lint lib test packages
- HARDWARE: on the appliance, press power while recording to Internal; the take is in the Library after boot and plays to the press. | verify: manual on device
NON-GOALS:
- Touch calibration (does not exist yet; its owner enters `calibration` when built).
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos && bloc lint lib test packages
```

### Part 13: the Record performance page and the persistent indicator (about 640 production lines; `lib/performance/view`, `lib/library`; depends on Part 9, USB Part 6, Library Part 7)

- `lib/performance/view/record_performance_page.dart` in the shared
  `LoopSettingsFrame` (`lib/looper/view/loop_settings/loop_settings_frame.dart:41`)
  with crumb `LIBRARY / Audio`, matching 20/01, 20/02, 20/04–20/06, 47 and
  48 `cH9UX`/`FwjUV`/`HWH3p`: title `Record performance`, status line
  (`Ready to record`, `Recording`, `Recording saved`, `Recording
  interrupted`), the timer, the session name, the remaining-time line
  (`52:45:49 remaining` / `Remaining time unavailable`), the format line
  (`48 kHz · 2 channels · 32-bit float`, from the frozen format; the pen's
  `24-bit PCM` is a recorded departure, §9), a line naming samples above
  full scale when `overs > 0` (`Some audio is above full scale. It is kept
  as recorded.`, new copy, §9), `Save to`
  with USB Part 6's picker, `Follow output volume` (existing setter,
  `segno_engine_api.h:2749`), the `Main output` card, the parts list
  (`5 file parts · One take`, `Playback and export use these parts in
  order.`, `1. 1:26:48` at 48 kHz stereo), the reserve warning, the held notes and `Save
  recovered audio` / `Discard recording` (with the existing confirm dialog
  for Discard), `View recording` / `Record another`, `Start recording` /
  `Stop recording`. The reason copies: reserve (`yzmtU`), USB (`HWH3p`),
  generic and slow storage (`dgedL`: `The available recording can be
  saved. It may be incomplete.`), save failure (`owAnd`). `Hear an example`
  beside `Follow output volume` (`cH9UX`) plays the existing example the
  setting already offers; if none exists in code it is not drawn and is
  listed in §9 (no stand-in). Recording by foot (20/03 `E7kQV`) needs no new
  screen: the stage keeps its timer and the foot Stop; its criterion checks
  that the stage shows `01:23` and `Stop recording` on the Record/Play
  pedal label while armed (review L7).
- The Audio tab's sub-nav entry `Record performance` (Library plan
  deviation 3 leaves it to this item); the completion sheet's saved face is
  replaced by the page's saved state.
- `_RecordLight` (`stage_top_bar.dart:344-412`) becomes
  `PerformanceRecordingIndicator`, drawn in `StageTopBar` and in
  `LoopSettingsFrame`'s top row, so it shows on Library, Settings, FX and
  Loop settings pages and in Mixer and Fade bodies (`tracks_view.dart:209-212`).
- l10n in `app_en.arb` with the pen copy verbatim; `app_es.arb` keys added.

```success-criteria
GOAL: The Record performance page draws every accepted recorder state from real state, and the recording indicator is visible wherever the player is.
SUCCESS CRITERIA:
- Widget tests for Ready, Recording with 52:45:49 remaining and five parts, Capacity unavailable, nearly full, reserve held, USB held waiting for SEGNO USB (Save disabled), interrupted, save failure, saved, and a take with overs, each asserting the pen strings quoted above and the format line `48 kHz · 2 channels · 32-bit float`. | verify: /Users/Tomas/development/flutter/bin/flutter test test/performance/view
- While armed, the stage shows the elapsed time and the Record/Play pedal label reads `Stop recording` (20/03 `E7kQV`). | verify: /Users/Tomas/development/flutter/bin/flutter test test/looper/view
- Save to is disabled while recording; Discard asks before acting; Save recovered audio calls saveRecovered. | verify: /Users/Tomas/development/flutter/bin/flutter test test/performance/view
- The indicator is present on the Library, Settings, FX and Loop settings pages and in Mixer and Fade while armed, and absent when idle. | verify: /Users/Tomas/development/flutter/bin/flutter test test/performance test/looper/view
- Library > Audio shows the Record performance entry and opens the page. | verify: /Users/Tomas/development/flutter/bin/flutter test test/library
- Screenshot goldens regenerated and compared against the pen screens on the author's machine. | verify: /Users/Tomas/development/flutter/bin/flutter test test/screenshots
- Root coverage, analyzer, Bloc lint, cspell. | verify: /Users/Tomas/development/flutter/bin/flutter test --coverage && dart analyze --fatal-infos && bloc lint lib test packages && npx cspell --config .github/cspell.json docs/plan/*.md
NON-GOALS:
- Export of recordings (Library Part 7), the picker (USB Part 6).
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos && bloc lint lib test packages
```

### Part 14: Open inspection and the candidate (about 560 production lines; `session_repository` + `lib/library/application`; depends on Part 7 and Library Part 4)

- `SessionRepository.inspect(id) → OpenCandidate` (D7 step 1): every layer
  reference (undo, live and redo positions) checked for presence, decode,
  frames, format and digest (`le_digest_file` in `Isolate.run`), one
  `RepairItem` per missing or damaged `audioId` listing every
  (track, lane, position) that needs it; unverified-and-missing → refusal
  item (D6).
- `AudioCandidates.find(audioId, format, frames)`: scans Internal session
  bundles' `audio/`, `recovered/`, and, while a volume is mounted,
  `<mount>/Segno/Sessions/*/audio/` and `.part`-free backups, matching by
  digest first by name (`audio/<hex>.wav`) and then by content for other
  files of the same byte length; returns location (`Internal audio`,
  `USB backup`) and duration.
- `OpenCandidate.choose(item, candidate)` and `apply()` (D7 step 3, entered
  under `sessionApply` and `sessionWrite`): recheck, copy into the bundle
  through `copyFile`'s protocol for USB sources (USB Part 4) or a local
  `.part` copy, then Library Part 4's open.
- Prepared backing references (once #1200's Part 5 gives backing assets an
  identity) are inspected the same way: a missing backing file is a
  `missingBacking` item listing the prepared-list rows that use it, and
  candidates match by #1200's asset identity only (D7, review M8).
- `SessionCubit.open(id)` calls `inspect` first and, with no items, opens as
  before; with items it emits `needsRepair(candidate)`.

```success-criteria
GOAL: Opening a session first finds every missing or damaged recording, including history-only ones, and repairs only from exact copies before anything changes.
SUCCESS CRITERIA:
- A fixture whose live layer and one undo layer of track 2 are missing yields one item per audioId with both positions; a truncated file yields damagedAudio; a file with the right name and length but other content yields damagedAudio; an unverified missing layer yields the unverified refusal. | verify: (cd packages/session_repository && /Users/Tomas/development/flutter/bin/flutter test)
- Candidates: a renamed exact copy on a fake USB backup is found by content; a same-name different-content file is not offered; a file with the same digest but another sample rate is not offered. | verify: (cd packages/session_repository && /Users/Tomas/development/flutter/bin/flutter test)
- apply copies the chosen file to audio/<hex>.wav, leaves session.json byte-identical, and the session then opens with every layer byte-exact; Cancel leaves the bundle and the live rig unchanged; a candidate whose source volume was detached after the choice is refused at apply. | verify: (cd packages/session_repository && /Users/Tomas/development/flutter/bin/flutter test) && /Users/Tomas/development/flutter/bin/flutter test test/session test/library
- Session coverage floor, root coverage, analyzer, Bloc lint. | verify: (cd packages/session_repository && /Users/Tomas/development/flutter/bin/flutter test --coverage) && /Users/Tomas/development/flutter/bin/flutter test --coverage && dart analyze --fatal-infos && bloc lint lib test packages
NON-GOALS:
- Widgets (Part 15), connections and targets (Parts 16-20).
VERIFICATION COMMAND: (cd packages/session_repository && /Users/Tomas/development/flutter/bin/flutter test) && /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos && bloc lint lib test packages
```

### Part 15: the recovery panels (about 580 production lines; `lib/library/view`; depends on Part 14, and #1200's Part 5 for the backing row)

- In the Library's session preview area, matching pen 36 and 42: the
  `Open session` panel with `Cancel`, the session name, `N audio files to
  find` / `Audio ready`, one row per item (`Track 2 · Original`, `Find
  audio` / `Ready`), `Your current session stays open until everything is
  ready.`, `Open session`; the `Find original recording` chooser with
  `Back`, the reference name, `Internal / backup copies`, `Choose an intact
  copy of this recording. Loop length stays the same.` and candidate rows
  (`USB backup · WAV · 0:02`); the save-failure line `Could not save your
  current loop. Nothing was changed.` with retry (`sra8u`); the device
  panel `Audio interface unavailable` / `Reconnect it to open this
  session.` / `Audio setup` (`LaqVi`); and the backing row (`Evening
  lights.wav`, `Prepared audio · Backing track`, `Find audio` / `Ready`) on
  `b28GI1`, `w9WB8`, `sra8u` and `LaqVi` (review M8), whose chooser lists
  only exact copies of that asset.
- `LibraryCubit` holds the candidate; leaving the Library discards it.

```success-criteria
GOAL: The player can find each missing recording, see it marked ready, and open the session, or cancel with nothing changed.
SUCCESS CRITERIA:
- Widget tests for DEY0v, KNzYO, l3bgeK, b28GI1, w9WB8, sra8u and LaqVi states with the pen strings, including the backing row; a candidate row tap marks the item Ready and changes no file. | verify: /Users/Tomas/development/flutter/bin/flutter test test/library
- Cancel and navigating away call no repository write; Open session calls apply once; an apply failure shows the retry line and keeps the choices. | verify: /Users/Tomas/development/flutter/bin/flutter test test/library
- Encoder and touch both reach every control (the Library's existing focus tests extended). | verify: /Users/Tomas/development/flutter/bin/flutter test test/library
- Root coverage, analyzer, Bloc lint. | verify: /Users/Tomas/development/flutter/bin/flutter test --coverage && dart analyze --fatal-infos && bloc lint lib test packages
NON-GOALS:
- Accepting a different file of the same duration and format (pen `HfLgr`; AB §6.10 wins, §9).
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos && bloc lint lib test packages
```

### Part 16: sessions record physical connections; inspection and remap (about 540 production lines; `session_repository`, `lib/session`; depends on Parts 6 and 14)

- Manifest `audioRouting.portBindings` (schema step after Part 6's, with
  its #1196 migration step that records none): `{id, direction,
  interfaceId, portIds[1|2], label}`, one per logical input row (mono or
  ordered stereo pair from `SessionInputSetup.pairs`, `models/session.dart:518-546`)
  and per output bus in use; `interfaceId` is the open device's name (the
  key port aliases use, `port_aliases.dart:69-75`), `label` the alias at
  save time. Captured in `session_mapping.dart:152-157`.
- `inspectConnections(candidate, inventory)`: a binding whose `interfaceId`
  differs from the current device, or whose port exceeds the device's
  channel count, is a `missingPort` item with its affected routes (lane
  inputs, monitors, lane outputs, output buses, click mask). A session
  without `portBindings` (saved before this part) produces no items and
  opens as today (unverified, never inferred: design doc
  `2026-09-08-audio-ports-and-long-recording.md:36-37`).
- `remap(binding, ports)`: refuses a port already used by another binding
  in the candidate (`occupied`), refuses a stereo binding on a single port
  or on two ports the inventory does not declare as an ordered pair
  (`incompatible`), and rewrites every affected index in the candidate
  keeping left/right order.

```success-criteria
GOAL: A session knows which interface and jacks its connections used, and a repair rewrites every affected route in the candidate while keeping stereo roles and refusing conflicts.
SUCCESS CRITERIA:
- Saving with a stereo pair on inputs 1-2 named "Acoustic guitar" on device "Stage" records {direction input, interfaceId Stage, portIds [Stage:input:1, Stage:input:2], label Acoustic guitar}. | verify: (cd packages/session_repository && /Users/Tomas/development/flutter/bin/flutter test) && /Users/Tomas/development/flutter/bin/flutter test test/session
- On device "Spare" that binding is missingPort listing 5 routes for a fixture with 4 track recording inputs and 1 monitor; remap to Spare inputs 5-6 rewrites all five with left→5 and right→6; remap to 3-4 when 3-4 belong to another binding is refused occupied; remap of the pair onto input 7 alone is refused incompatible. | verify: (cd packages/session_repository && /Users/Tomas/development/flutter/bin/flutter test)
- A previous-version session yields no connection items and applies exactly as before. | verify: /Users/Tomas/development/flutter/bin/flutter test test/session
- Coverage floors, analyzer. | verify: (cd packages/session_repository && /Users/Tomas/development/flutter/bin/flutter test --coverage) && dart analyze --fatal-infos
NON-GOALS:
- Widgets, CTRL and MIDI.
VERIFICATION COMMAND: (cd packages/session_repository && /Users/Tomas/development/flutter/bin/flutter test) && /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos
```

### Part 17: the port repair panels (about 480 production lines; `lib/library/view`; depends on Parts 15 and 16)

- Pen 43: `Check <session> connections`, the row (`Acoustic guitar ·
  Saved interface <id> is not the current interface.`), `Replace`,
  `Reconnect the required device or choose a replacement.`, `Cancel`,
  `Retry open`; the chooser `Replace Acoustic guitar` / `Choose the
  connection to use for this session.` with one row per current port pair,
  occupied rows disabled with `These ports already belong to another saved
  audio connection.`, and the `Routes` list; the review popup (`Review
  connections`, `For` / `Use connection`, `5 routes updated`, `Opening
  <session> stops playback.`, `Cancel`, `Reset choices`, `Apply and
  open`). `Retry open` re-runs inspection against the current inventory.
- A disconnect of the interface while the panel is open invalidates
  `Apply and open` (AB §6.11 "Apply/open rechecks … hardware").

```success-criteria
GOAL: The player can replace missing interface ports with compatible current ones, review the affected route count, and open, or cancel with nothing changed.
SUCCESS CRITERIA:
- Widget tests for K48Hse, v7zSCN (occupied rows disabled with the pen copy) and gtG0I (For / Use connection, "5 routes updated") states. | verify: /Users/Tomas/development/flutter/bin/flutter test test/library
- Apply and open publishes the repaired manifest and applies once; Cancel and Reset choices write nothing; a device change after the choice disables Apply until Retry open. | verify: /Users/Tomas/development/flutter/bin/flutter test test/library test/session
- Root coverage, analyzer, Bloc lint. | verify: /Users/Tomas/development/flutter/bin/flutter test --coverage && dart analyze --fatal-infos && bloc lint lib test packages
- HARDWARE: save a session on the Scarlett with a stereo input pair, open it with a second interface attached instead, repair onto its inputs, record, and confirm left and right land on the chosen jacks. | verify: manual on device
NON-GOALS:
- CTRL and MIDI rows (Part 18).
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos && bloc lint lib test packages
```

### Part 18: CTRL and MIDI connection rows (about 420 production lines; depends on Part 17 and #1206, session-owned external and MIDI assignments)

AB §6.9 makes musical MIDI assignments and expression ranges session-owned,
but today all of them are global (`settings_repository.dart:535-560`,
`pedal_setup.dart:275`) and the session's remap covers built-in pedals only
(`pedal_binding.dart:24-50`). A session cannot "need expression on CTRL 1"
until it carries those assignments, so this part waits for that move,
which #1206 plans on its own (AB §6.9 wins over the Library plan's §6
reading).

- Inspection items `missingCtrl` (the session's assignments need a jack
  type the current `ExternalPedalSetup` does not provide: `CTRL 1 needs
  expression; current setup is dual.`) and `missingMidiDevice` (a
  `MidiSource.device` id absent from the current inventory,
  `midi_protocol.dart:35-90`).
- Choosers per pen 40 `I8foz` and `D3Rij` (`Replace CTRL 1`, `This is the
  original connection. Choose another pedal port.`, the `Assignments`
  list), and `UOyKO`'s review (`CTRL 1 → CTRL 2 · Expression`, `Apply these
  assignments and open <session>. Playback stops; hardware settings
  stay.`). Repointing reuses `ExternalControls.repointActivation`/
  `repointParameter` and `MidiMappingDraft.repointing` on the candidate's
  copies, keeping conditions and ranges.

```success-criteria
GOAL: A session whose assignments need a missing pedal type or MIDI controller can be pointed at a current one before opening, with hardware settings untouched.
SUCCESS CRITERIA:
- A session needing expression on CTRL 1 with CTRL 1 set to dual yields missingCtrl; choosing CTRL 2 (expression) repoints its assignments with heel/toe ranges unchanged; the global pedal.setup is byte-identical after apply. | verify: /Users/Tomas/development/flutter/bin/flutter test test/library test/control
- A session whose MIDI assignments name an absent device yields missingMidiDevice; choosing another device repoints CC 1 · Ch 1 assignments only. | verify: /Users/Tomas/development/flutter/bin/flutter test test/library test/control
- Widget tests for TNFh0, I8foz, UOyKO and D3Rij with the pen strings. | verify: /Users/Tomas/development/flutter/bin/flutter test test/library
- Root coverage, analyzer, Bloc lint. | verify: /Users/Tomas/development/flutter/bin/flutter test --coverage && dart analyze --fatal-infos && bloc lint lib test packages
- HARDWARE: with a dual switch in CTRL 1 and an expression pedal in CTRL 2, open a session saved with expression on CTRL 1, repair, and sweep the pedal. | verify: manual on device
NON-GOALS:
- Moving assignments into the session (#1206).
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos && bloc lint lib test packages
```

### Part 19: control-target inspection and repoint (about 400 production lines; `lib/control/binding`, `lib/library/application`; depends on Part 14)

- `inspectTargets(candidate, assignments)`: resolves every assignment that
  will be live after Open (the candidate's own pedal remap; the global
  external and MIDI assignments) against the candidate's target universe
  (its four chain stages by `slotId`, its tracks, the current device's
  inputs and output buses), reusing `valueTargetResolves` and
  `bindingResolves` (`control_value_resolver.dart:120-162`,
  `fx_binding_resolver.dart:87`) with the candidate in place of the live
  rig. Unresolved → `missingTarget` with source, target label
  (`Guitar / Lost delay · Delay · Mix`) and sources' current values.
- `repoint(item, newTarget)` on the candidate's copies: same-kind targets
  only (a value target to a value target, an activation to an
  activation), keeping each source's range positions as source values
  (pen `qLXt5`: `Range positions are kept. These are the replacement
  values.`); `Scale unverified · source values` when the new parameter has
  no verified descriptor (AB §8 forbids inventing a scale).
- Apply (D7): session-owned assignments in the repaired manifest, global
  ones through their owners' existing save paths after the manifest; a
  failure of the second reports `Assignments not saved` with Retry.

```success-criteria
GOAL: Assignments that will point at nothing after Open are found against the incoming session, and can be repointed to same-kind targets with their ranges kept.
SUCCESS CRITERIA:
- A global MIDI CC 21 mapped to a delay Mix slot absent from the incoming session yields missingTarget; one mapped to a slot present in the incoming session (same slotId) does not, even if the outgoing rig lacks it. | verify: /Users/Tomas/development/flutter/bin/flutter test test/control test/library
- Repointing a Mix target keeps From 0.15 / To 0.9 source values; an activation cannot be repointed to a value target; three assignments sharing the target are all repointed and counted 3. | verify: /Users/Tomas/development/flutter/bin/flutter test test/control
- A failing global save after a successful manifest commit yields the assignments-not-saved state, never unchanged. | verify: /Users/Tomas/development/flutter/bin/flutter test test/library
- Root coverage, analyzer, Bloc lint. | verify: /Users/Tomas/development/flutter/bin/flutter test --coverage && dart analyze --fatal-infos && bloc lint lib test packages
NON-GOALS:
- Widgets (Part 20).
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos && bloc lint lib test packages
```

### Part 20: the control repair panels (about 520 production lines; `lib/library/view`; depends on Parts 15 and 19)

- Pen 41: `Check <session> controls` with the row (`Guitar / Lost delay ·
  Delay · Mix is unavailable.`), `Replace`, `Reconnect the required control
  or choose a replacement.`, `Cancel`, `Retry open`; `Replace control`
  destination pages (inputs, tracks, track/input lanes, `All tracks ·
  Combined playback`, `Main output`, `Monitor output`, `Click`, `Backing`,
  `Loop`) in short pages; the control list for the chosen destination
  (`Delay · Mix · Input 1 · Stage vocal / Clean Rhythm`); `Use this
  control?` with each source's values and `Use control`; `Review changes`
  (`From` / `To`, `3 assignments updated`, `Opening <session> stops
  playback.`, `Cancel`, `Reset choices`, `Apply and open`). `Backing` is
  disabled with its reason until E7-8 exists.

```success-criteria
GOAL: The player can replace each missing control target, review From/To and the assignment count, and open, or cancel with nothing changed.
SUCCESS CRITERIA:
- Widget tests for WZvK8, GwDUd, v5FPjK (paged), qLXt5 (source values and the kept-ranges note) and iEuYw ("3 assignments updated") with the pen strings. | verify: /Users/Tomas/development/flutter/bin/flutter test test/library
- Cancel and Reset choices write nothing; Apply and open writes once and opens once. | verify: /Users/Tomas/development/flutter/bin/flutter test test/library
- Root coverage, analyzer, Bloc lint, goldens on the author's machine. | verify: /Users/Tomas/development/flutter/bin/flutter test --coverage && dart analyze --fatal-infos && bloc lint lib test packages && /Users/Tomas/development/flutter/bin/flutter test test/screenshots
NON-GOALS:
- New target kinds.
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos && bloc lint lib test packages
```

## 6. Order and dependencies

| Part | Size (prod lines) | Depends on | Autonomy |
|---|---|---|---|
| 1 SHA-256, digests, dir sync (built, #1220) | ~260 | – | auto |
| 2 float WAV parts | ~640 | 1 | merge-gate (capture format) |
| 3 reserve and slow-storage stops | ~380 | 2 | merge-gate |
| 4 two-slot checkpoints and mirror | ~480 | 2 | merge-gate (blocked-verify for the power-cut criterion) |
| 5 part format in Dart | ~420 | 1 | auto |
| 6 layer identity + schema step | ~380 | 1, #1196 | merge-gate (schema) |
| 7 content-addressed audio through the Library swap | ~520 | 1, 6, Library P1/P3 (#1203) | merge-gate |
| 8 finalize, recover, hold | ~660 | 2, 3, 4, 5 | merge-gate |
| 9 recorder state | ~500 | 8, USB P6 | auto |
| 10 USB ownership + same-drive recovery | ~520 | 4, 8, 9, USB P6 | blocked-verify |
| 11 guard registry (built, #1221) | ~420 | – (USB P6 follow-up) | auto |
| 12 power, restart, apply, latency | ~430 | 9, 11 | merge-gate |
| 13 Record performance page + indicator | ~660 | 9, USB P6, Library P7 | merge-gate (screen) |
| 14 Open inspection + candidate | ~600 | 7, Library P4, #1200 P5 for backing | auto |
| 15 recovery panels | ~580 | 14 | merge-gate (screen) |
| 16 port bindings + remap | ~540 | 6, 14 | merge-gate (schema) |
| 17 port repair panels | ~480 | 15, 16 | merge-gate |
| 18 CTRL and MIDI rows | ~420 | 17, #1206 | merge-gate |
| 19 target inspection + repoint | ~400 | 14 | auto |
| 20 control repair panels | ~520 | 15, 19 | merge-gate |

Parts 1, 5 and 11 are built or can start at once. The capture chain is 1 →
2 → {3, 4} → 8 → 9 → {10, 12, 13}. The publication chain is 1 → 6 (#1196) →
7 → 14 → {15, 16, 19}. Library Part 7 takes D3's contract (listing,
`dawPackageFiles` as ordered parts, audition from part 1 through
`wav_codec`'s bounded reader, multi-part export) and adds the Delete action
for recordings (owner decision, review M9) whichever lands first; Part 8
adjusts `listCaptures` if Library Part 7 is already in. Part 18 waits for
#1206 (review L1: that issue settles session-owned assignments for its own
plan, and AB §6.9 wins over the Library plan's §6 reading; nothing else
here waits for it).

## 7. Hardware-only

- **Power cut**: the checkpoint guarantee (Part 4: at most the last 5 s
  lost after a cut, nothing lost after an app crash on a volume that stayed
  mounted), bundle publication (Part 7: the previous or the new session,
  never neither), power-off finishing a take (Part 12), a power cut with
  the stick attached (Part 10).
- **Real USB**: direct recording to exFAT, FAT32 (mounted with `flush`) and
  NTFS (ntfs3, review L9) sticks at 48 and 96 kHz with loops playing, a pull
  mid-take and same-drive recovery to the checkpoint with no stale audio
  after it, a different drive refused, eject refused while armed (Part 10);
  the 8 s ring absorbing real flash stalls with `perfZeroFilledFrames` and
  `perfOverruns` at 0, checkpoints running and no per-cycle file on the
  stick (Part 4); a slow stick ending as `slow_storage` rather than with
  silence (Part 3).
- **Capacity**: a take on a nearly full Internal stopping at the reserve
  with the session still savable (Parts 3, 7, 9).
- **Large legacy capture**: the 38 GB bundle of #1078 (Part 8).
- **Interfaces and pedals**: a second audio interface for port repair
  (Part 17); a dual switch and an expression pedal for CTRL repair
  (Part 18).

## 8. Open points

Defaults taken under the standing rules (override on the issue): the 5 s
checkpoint interval; the 8 s USB ring capped at 64 MiB total; the 16 MiB
removable floor; the `sgno` chunk; SHA-256 as the slot checksum (Part 1's
one hash, in place of a separate CRC); the trust rule (same boot and
continuous mount); restart cancelling latency measurement; power off
refusing (not closing) a loop still recording; a held take blocking
nothing; recovered takes listed in the Library.

Decided by the owner on the review (2026-10-06): float parts with an overs
count (H1); recovered takes kept with no automatic deletion, freed by the
Library's Delete for recordings (Q1, M9); #1206 owns session-owned
assignments (Q2).

No genuine question remains open.

## 9. Pen write-back list

Departures the pen must take (the pen is not edited by builders; the main
session writes these back):

1. `48 kHz · 2 channels · 24-bit PCM` → `48 kHz · 2 channels · 32-bit float`
   on `D9QbI2`, `vjohm`, `X4UXKN`, `yzmtU`, `T8ACW`, `cH9UX`, `FwjUV`,
   `HWH3p` (D3).
2. Part durations on `X4UXKN`: a full part at 48 kHz stereo is `1:26:48`,
   not `1:55:44`; an 8:00:00 take is 6 parts (5 × 1:26:48 + 0:45:58), not 5.
3. A line for samples above full scale on the Record performance page
   (`Some audio is above full scale. It is kept as recorded.`), new.
4. `HfLgr`: a recorded track accepts only an exact original or intact
   backup (AB §6.10, pen 42), not "Same duration and format".
5. `cH9UX` `Hear an example`: drawn only if the code has an example to play.

## 10. Review record (PR #1205)

The plan review (2026-10-06) requested changes; every finding is applied
above:

- **H1** (24-bit clips the pre-limiter master): parts are float, overs
  counted (D3, Parts 2, 5, 8, 13, §9).
- **H2** (same-boot recovery after a pull trusts stale clusters): present
  frames are trusted only with the same boot and a continuously mounted
  volume (D4, Parts 8, 10).
- **M1** (rename over a file is not atomic on FAT and exFAT): two checkpoint
  slots with a sequence and a checksum, mirror authoritative, removable
  manifest written fresh with a checksum (D4, D5, Part 4).
- **M2** (remaining time ignored inputs and the removable reserve): one
  function over every stream and the destination's reserve, also for the
  picker's required rate (D2, Parts 5, 9).
- **M3** (two atomicity mechanisms): Part 7 extends #1203's save-back swap
  and its recovery rules (D5, Part 7).
- **M4** (a held take blocked power off and Open): a held take holds no
  guard or lease (D8, D9, Parts 8, 10, 12).
- **M5** (power cut with the stick attached had no path): every mirror and
  unfinalized bundle becomes a held take at start and on each volume event
  (D9, Parts 8, 10).
- **M6** (FAT `flush` sleeps on every close): no per-cycle file on a
  removable target; the live sidecar lives in the Internal mirror (D1,
  Part 2, Part 4's hardware criterion).
- **M7** (Library contract and three WAV readers): D3 records the Library
  changes; `wav_codec` is the one Dart reader.
- **M8** (backing rows owned by neither plan): Parts 14 and 15 build them
  after #1200's Part 5.
- **M9** (no way to free space): the Library's Delete for recordings (Library
  Part 7), referenced from D9 and Part 8.
- **L1** #1206 (§6, Part 18); **L2** rollover recovery (D4, Part 8); **L3**
  arm floor (D2, Part 9); **L4** stream-by-stream legacy conversion (D3,
  Part 8); **L5** ring bound (D2, Part 2); **L6** capture × transfer on one
  volume (D8, Part 11); **L7** pen gaps (§9, Part 13); **L8** the floor's
  wording (D2); **L9** NTFS (§7, Part 10); **L10** sub-issues (§4).
