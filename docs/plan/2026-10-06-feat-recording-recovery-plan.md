# Recording to USB, long recordings, atomic publication and recovery

<!-- cspell:ignore dpwx vjohm Xcpyh dged UXKN yzmt headerless repointing Repointing statvfs vfat EROFS sgno RDONLY abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq xyzabcdef CLOEXEC -->

Tracking: #1198 (gap inventory E7-11, E7-12, E7-19, E7-16, E7-17, E7-18),
`autonomy:merge-gate`, `stage:plan`. Builds on the USB storage service
(#1177) and the Library (#1178). Related open issues this plan closes or
absorbs: #1078 (bounded-memory recovery of large captures) and #727 (crash
durability of the capture bundle).

Base: `origin/claude/segno-integration` at `5c163d11f`. Every `file:line`
below is on that head unless a branch is named. Engine paths written as bare
file names are under `packages/segno_engine/src/core/`. Branch citations:
USB plan and Part 4 on `origin/claude/usb-storage-1177-p4` (`79d37ea97`);
Library plan on `origin/claude/library-1178-p3` (`2d88d96ce`).

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

Copy the screens fix (quoted verbatim in the parts): `48 kHz · 2 channels ·
24-bit PCM`, `52:45:49 remaining`, `Remaining time unavailable`, `5 file
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

The part durations in `X4UXKN` (`3. 1:55:44`, `4. 1:55:44`, `5. 17:02`, an
8:00:00 take) fix the part size: 2,000,000,000 bytes per file, header
included, at 48 kHz stereo 24-bit is 333,333,319 frames = 6,944.4 s =
1:55:44. The prototype model computes the same with a 44-byte header
(main checkout `docs/design/performance-recording-model.js:5-8`).

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
drain does not know which kind it is; it receives a target struct (§5 Part 2)
whose `ring_seconds` and `reserve_bytes` differ by destination.

Rejected: spooling to Internal and copying to USB afterwards. AB §7.7 says
direct USB recording "owns its removable target explicitly and has
same-drive/exact-part recovery", pen `HWH3p` says "Saved parts stay on that
drive", and a spool would consume the Internal space that recording to USB
exists to avoid. Field recorders write straight to their card for the same
reason.

What Internal still gets for a USB take: a **mirror** of each durable
checkpoint and the arm snapshot at `{exportsRoot}/.takes/<takeId>.json`
(written by the checkpoint thread, D4), carrying the volume fingerprint
(`RemovableVolume.fingerprint`, ID_SERIAL + filesystem UUID, USB plan §2.1).
That is what lets the console show `Reconnect SEGNO USB` after the drive is
pulled or the power is cut, and what "same drive" is checked against.

### D2. Slow writes and full disks stop at complete frames

Two native stop rules, both in the drain, both ending every stream at the
same frame:

- **Reserve.** At arm the drain receives `reserve_bytes` (1 GiB on Internal,
  `StorageRepository.internalReserveBytes`, P4 `storage_repository.dart:56`;
  16 MiB on a removable volume, room for the checkpoint, mirror and
  manifest). Every 5 s, on the checkpoint cadence, the drain re-reads the
  volume's free bytes (the existing statvfs, `perf_drain.c:126`); between
  samples it subtracts every byte it writes (PCM parts and headers,
  `events.log`, layer files). Before each write it computes how many whole
  frames all continuous streams can still take together; when that reaches
  zero it writes exactly those frames, seals the parts and stops with
  `stopped_early: "reserve_reached"`. The JSON files it rewrites in place
  (sidecar, checkpoint) are covered by a fixed 1 MiB allowance inside the
  reserve. A volume whose free space cannot be read records no budget (pen
  `T8ACW`: Start stays enabled, the line reads `Remaining time unavailable`,
  rule 1: the unanswerable-volume case arms today), and stops only on a
  write failure.
- **Slow storage.** The audio thread records the first frame it had to drop
  (`perf.first_drop_frame`, set once per take, published with the same
  release add as `a_perf_frames`). The drain writes each stream up to that
  frame, never past it and never pads after it, seals and stops with
  `stopped_early: "slow_storage"`. Frames the ring accepted after the drop
  are discarded, so the take never contains a hole followed by more audio.
  AB §6.7 requires this ("slow writes stop at complete recorded frames").
  The other zero-fill cause, frames counted but never tapped (#710,
  `perf_drain.c:1024-1068`), is not a storage fault and keeps today's
  behaviour: silence, the glitch flag, the take continues.
- **Ring size.** `ring_seconds` stays 2 on Internal (rule 1: today's
  value, `engine_private.h:163`) and is 8 on a removable volume, where
  flash erase stalls of 1–4 s are normal and the vfat `flush` mount option
  makes writes near-synchronous (USB plan §8 point 4). 8 s of 96 kHz stereo
  float is 6 MB per stream.
- **Write failure** (ENOSPC from another writer, EIO, EROFS, a pulled
  drive) keeps today's self-stop and `stopped_early: "disk_full"` string
  (`perf_drain.c:1269-1271`), which every existing bundle on disk uses; the
  app labels it by the lease outcome (`volumeLost` when the volume record
  vanished, USB plan Part 6) or as a write failure.
- **Warning.** The recorder shows pen `yzmtU`'s `Storage is nearly full.
  Recording stops before reserved space is used.` once the remaining time
  (D3 rate, `StorageRepository.recordingTimeRemaining`, P4 `:326`) drops
  under 60 s. It is computed from actual capacity and the frozen format,
  never from elapsed time.
- **Arm refusal.** Arming Internal is refused when free space is below the
  reserve (pen 31 `No recording space`), replacing the 500 MB constant
  (`performance_recorder_cubit.dart:97`) and the duplicate-copy stop floor
  (`:112-123`, `:411-437`). Both exist only because finalize copied the
  take; after D3 it copies nothing.

### D3. Part format: ordered 24-bit WAV parts written once

- **Encoding.** Little-endian signed 24-bit PCM, `WAVE_FORMAT_PCM` (tag 1),
  at the device rate, with the channel count frozen at arm: 1 or 2 for the
  master (`engine_commands.c:4614-4616`), 2 for each captured input. Float
  samples are clamped to [-1, 1] and rounded to nearest (`1.0 → 0x7FFFFF`,
  `-1.0 → 0x800000`), the conversion `le_write_le_int` already performs for
  ASIO (`engine_convert.c:59-75`). No dither: the master is post-limiter and
  24-bit quantization sits near -144 dBFS. Accepted baseline, AB §6.7.
- **Size.** At most 2,000,000,000 bytes per file, header included. This is
  under FAT32's 4 GiB − 1 file limit (the drives people bring), under RIFF's
  32-bit size fields, and under 2^31 for readers that hold RIFF sizes in a
  signed int.
- **Layout.** `RIFF`/`WAVE`, `fmt ` (16 bytes), a 32-byte `sgno` chunk
  (`take_id` 16 bytes, `stream` u16: 0 master, 1 + n input n, `part_index`
  u16 from 1, 12 reserved zero bytes), then `data`. Header total 84 bytes,
  so a part holds `floor((2,000,000,000 − 84) / frame_bytes)` frames. RIFF
  readers skip unknown chunks; the `sgno` chunk makes a copied or renamed
  part identifiable (Pro Tools' unique-file-ID idea, without depending on
  BWF tooling).
- **Names.** `master-001.wav`, `master-002.wav`, … and `input-<n>-001.wav`,
  in the bundle root. The user-facing name of a part is `<take name> · Part
  001.wav` (prototype `performance-recording-model.js:38`), applied at
  export only.
- **Lifecycle.** The drain writes the header with zero sizes, appends data,
  and on rollover or stop **seals** the part: patches the RIFF and `data`
  sizes, flushes, and records the part's SHA-256 over its `data` payload
  (computed incrementally while writing, D6). Finalize copies nothing: the
  parts are the take. This removes the second copy, the 2× space
  requirement and #1078's whole-file read for every new take.
- **One Library item.** The finalized manifest lists `parts` per stream in
  order with `index`, `file`, `frames`, `bytes`, `sha256`; the take's frame
  count is the master's sum. Library Part 7's `listCaptures` reads duration
  from it, its audition plays from part 1, and its single-WAV export of a
  multi-part take writes the parts as consecutive `<name> · Part NNN.wav`
  files (each fits FAT32). That contract change to the Library plan is
  recorded here and in Part 8.
- **Legacy bundles** (raw `master.pcm`, including the 38 GB capture on the
  appliance) are recovered by streaming them into the same part format in
  bounded chunks (Part 8), then removing the `.pcm` once the parts and the
  finalized manifest are durable. Rule 1 (they recover) and rule 3 (the
  conversion is reported in the recovered take's facts).

### D4. Durability: checkpoints off the drain cycle (answers #727)

- A **checkpoint thread**, owned by the drain session, runs every 5 s (the
  prototype's interval, `2026-09-08-audio-ports-and-long-recording.md:73`).
  After each cycle's `fflush` the drain publishes, under a mutex it holds
  only to copy a few integers, the progress it has made visible to the OS:
  per stream the part count and frames in the open part, sealed parts'
  digests, `events.log` bytes, layer files written. The checkpoint thread
  copies that snapshot, opens each touched file read-only and `fdatasync`s
  it (Linux syncs the inode, whichever descriptor wrote it), writes
  `checkpoint.json.tmp`, `fsync`s it, renames it over `checkpoint.json`,
  `fsync`s the directory, then writes the same bytes to the Internal mirror
  path the same way. A checkpoint therefore never claims a frame that is not
  durable, and the drain cycle never waits on the device. The 250 ms
  `performance.json` stays as it is: a live, non-durable view for readers.
- **What recovery trusts.** `checkpoint.json` carries the kernel boot id
  (`/proc/sys/kernel/random/boot_id`; empty elsewhere). Recovery in the
  **same boot** (an app crash, an interrupted take) trusts the files as
  written: every whole frame present in every stream, floored to the
  shortest stream, because the page cache survived. Recovery in **another
  boot** (power cut, kernel crash, unknown boot id) trusts only the
  checkpoint and truncates each stream's open part to it. This is the pen's
  copy: `The saved checkpoint can be recovered. Audio after it may be
  unavailable.` It keeps today's salvage-everything behaviour after an app
  crash (rule 1) and gives a stated guarantee after a power cut: at most the
  last 5 s are lost.
- **Transient errors** are not fatal: `EINTR` is retried as today
  (`perf_drain.c:511-529`); a failed `fdatasync` or checkpoint write keeps
  the previous checkpoint, sets `checkpoint_failures` in the snapshot and
  retries next interval; it never stops the take. Only drain write failures
  stop a take (D2).
- The guarantee and file set are written into
  `docs/design/performance-manifest-format.md` beside the `.boot-recovery`
  contract, as #727 asks.

### D5. One recoverable publication per Library operation

The established pattern (git objects plus an atomic ref update; Ardour's
immutable sources plus an atomically replaced session file) applied to the
session bundle:

- **Audio is immutable and named by identity.** A session layer is written
  once as `audio/<sha256-hex>.wav` (D6), through `<name>.part`, `fsync`,
  rename. A re-save writes only layers that are not already in the bundle,
  so saves stop rewriting unchanged audio.
- **The manifest is the single commit point.** `session.json.tmp`, `fsync`,
  rename over `session.json`, `fsync` the directory. Before the rename the
  old session is intact; after it the new one is complete with every
  referenced file durable. Audio, history (every undo, live and redo layer
  is a reference) and metadata publish together.
- **Allocation is accounted before writing.** The commit sums the bytes of
  the layers it must add and refuses with `StorageFailure.full` before
  writing anything when they exceed free space. Saves may use the 1 GiB
  reserve (that is what the reserve is for: a take stops before it, so the
  session can still be saved).
- **Garbage is collected after the commit.** Files under `audio/` that the
  new manifest does not reference, legacy index-named layer WAVs, and any
  `*.part`, are deleted after the rename. A crash before the rename leaves
  only unreferenced files, which a boot sweep deletes.
- **Every other Library mutation is one rename.** Save as and Duplicate
  build into `.<id>.part/` and rename to `<id>/`; Restore from USB copies
  into `.<id>.part/` and renames (Library Part 8 already renames a drive-side
  `.part` directory); Delete renames to `.<id>.deleting/` and then removes
  it; Move to folder is a rename. The boot sweep finishes a `.deleting` and
  removes a `.part`. Library Part 1's "interrupted save" (a manifest-less
  directory with layer WAVs, Library plan D2) gains `audio/` as a marker and
  is cleaned by this sweep (the Library plan names it E7-19's work).
- **Performance takes publish the same way.** Finalize writes
  `performance.json` with `finalized: true` through tmp, `fsync`, rename and
  a directory `fsync`, after the sealed parts are durable. Discard renames
  the bundle to `.discarding-<slug>` and deletes it; the allocation is
  released only after that rename succeeded (prototype model, design doc
  `:75-77`), and the sweep finishes it.
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
   reference (exists, decodes, frames, digest), check physical connections
   against the current interface (Part 16), check control targets against
   the candidate's target universe (Part 19). The result is an
   `OpenCandidate`: the parsed session plus a list of `RepairItem`s
   (`missingAudio`, `damagedAudio`, `unverifiedAudio`, `missingPort`,
   `missingCtrl`, `missingMidiDevice`, `missingTarget`), each with its
   affected references (track/layer including undo/redo positions, routes,
   assignments).
2. **Choose** (candidate only): each repair choice replaces a value in the
   candidate. Nothing on disk or in the rig changes. Cancel discards the
   candidate (AB §6.11).
3. **Apply and open** (one guarded commit): recheck everything against the
   current media and hardware (a drive pulled since the choice invalidates
   it), copy each chosen audio file into the bundle as its content-addressed
   name (this needs no manifest edit: the manifest already references that
   identity), publish a repaired manifest when connections or targets
   changed (D5), save the outgoing rig (Library D7), then apply. A failure
   before the manifest rename leaves the bundle as it was (the copied files
   are referenced by it already and only make it more complete); a failure
   after it reports that the session was repaired but not opened, with
   Retry. Global settings changes (global MIDI and external assignments,
   Part 20) are written after the manifest; if that write fails the state
   reads "repaired, assignments not saved" with Retry, never "unchanged"
   (AB §6.11 "must not claim unchanged state if rollback itself failed").

Pen 36 `HfLgr` shows a recorded track (`Guitar phrase.wav`) accepting a
different file with "Same duration and format". AB §6.10 and section 42
(accepted on the same day, the later record) allow only the exact original or
an intact backup for recorded audio. This plan follows AB: section 36 is the
shell (list, `Find audio`, `Ready`, save failure, device unavailable) and
section 42 is the rule for recorded layers. Backing files (E7-8) are not
built yet; their repair rows arrive with them.

### D8. Guards: one registry, checked at commit

A new pure-Dart package `packages/operation_guards` holds
`GuardRegistry.enter(kind, scope) → OperationGuard` (throws
`GuardRefused(blockers)`), `blockers(kind, scope)` for disabling buttons,
and a release handle. Dart runs these owners on one isolate, so the check
and the registration are one synchronous step; each owner calls `enter` at
its **commit point**, not when its dialog opens (AB §6.12). Scope is
`Internal` or a removable volume generation.

| Wants to commit ↓ / active → | capture | sessionApply | sessionWrite | transfer | eject | deviceChange | calibration | restart |
|---|---|---|---|---|---|---|---|---|
| **capture** (arm) | – | refuse | allow | allow | refuse (same volume) | refuse | refuse | refuse |
| **sessionApply** (Open, New loop) | finish the take first (today's `disarmAndFinalize`, rule 1) | refuse | refuse | allow | allow | refuse | refuse | refuse |
| **sessionWrite** (save, Save as, rename, duplicate, delete, restore into Internal) | allow | allow (its own preservation save) | refuse (same bundle) | allow | allow | allow | allow | refuse |
| **transfer** (export, backup, import, restore read) | allow | allow | allow | allow | refuse (same volume) | allow | allow | refuse |
| **eject** | refuse (same volume, including a held USB take) | allow | allow | refuse (same volume) | refuse | allow | allow | refuse |
| **deviceChange** (audio apply, rate change) | refuse | refuse | allow | allow | allow | refuse | refuse | refuse |
| **calibration** (latency measurement; touch calibration when it exists) | refuse | refuse | allow | allow | allow | refuse | refuse | refuse |
| **restart** (power off, restart, update install) | finish the take first, then refuse if one is still active | refuse | refuse | refuse | refuse | refuse | cancel it (keeps the old profile, AB §7.6) | – |

Wiring (Parts 11 and 12): `PerformanceRepository.arm` before `le_perf_arm`
(the pedal reaches the repository directly, `performance_repository.dart:278-283`);
`SessionCubit` at the step after preservation and before
`disarmAndFinalize` (`session_cubit.dart:254`); `SessionRepository`'s commit;
`StorageRepository.acquire` and `eject` (P4 `:174`, `:249`), whose lease
registry becomes the `transfer` guard's representation rather than a second
conflict table (rule 4); `AudioSetupCubit` before `stopEngine`
(`audio_setup_cubit.dart:296`); latency measurement (`:415-419`, `:478`);
the power-off commit (`power_off_cubit.dart:104-111`) and the update
restart (`updates_system_tab.dart:262-271`). Involuntary events are not
guarded, they end the guarded operation: a device loss ends the take with
`device_changed` (now surfaced, Part 9), a pulled drive ends leases with
`volumeLost` (USB P4). AB §7.8: power off finishes the performance take
(finalize), saves the session, then shuts down; a loop still capturing
keeps today's refusal (`power_off_gate.dart:54-62`), because closing a loop
is a musical act the console should not take for the player.

### D9. Held takes

A take that stops for any reason other than the player's Stop (reserve,
slow storage, write failure, volume lost, device changed) is **held**: the
repository disarms (the final checkpoint is written), does not finalize, and
the Record performance page shows pen `yzmtU`/`HWH3p`/`dgedL` with `Save
recovered audio` and `Discard recording`. Save runs the recovery finalize
(D4, same boot); Discard publishes the discard (D5). `Save` failing shows
`owAnd` and keeps the take. A held take survives Open, New loop and restart:
after a restart it is an unfinalized bundle and the existing silent boot
salvage finalizes it (rule 1). A held USB take whose drive is gone keeps
`Save recovered audio` disabled with `Reconnect SEGNO USB. Saved parts stay
on that drive.` until a volume with the same fingerprint mounts (Part 10).
A normal Stop finalizes at once and shows `04 / Saved recording`.

## 3. Fault matrix

| Fault | Detected by | Result | Pen |
|---|---|---|---|
| Internal reaches the reserve | drain budget (D2) | stops at a whole frame, held, `Storage reserve reached. The recorded part of this take is kept.` | 47 `yzmtU` |
| Fewer than 60 s left | recorder, `recordingTimeRemaining` | warning line, take continues | 47 `yzmtU` (warning line) |
| Capacity unreadable | statvfs fails | `Remaining time unavailable`; no budget; Start enabled | 47 `T8ACW` |
| Writes slower than capture | first dropped frame (D2) | stops at the frame before the drop, held, slow-storage copy | 20 `dgedL` |
| USB pulled mid-take | lease `volumeLost` + drain write failure | held; loops keep playing; Save disabled until the same drive returns | 48 `HWH3p` |
| Same drive reconnected | fingerprint match on attach | Save recovered audio enabled; recovery on the drive | 48 `HWH3p` → `Z3V6Z` |
| Different drive connected | fingerprint differs | nothing offered; take stays held | 48 `HWH3p` |
| Power cut mid-take | next boot: unfinalized bundle or mirror | parts recovered to the last checkpoint; Library shows it recovered | 48 `Z3V6Z` |
| App crash mid-take | next start, same boot id | everything written recovered | 48 `Z3V6Z` |
| Audio device lost mid-take | `isPerfArmed` false while repository armed | held with device-changed copy | 20 `dgedL` |
| Save recovered audio fails | finalize throws | `Could not save the recording. It is kept here for another try.` | 20 `owAnd` |
| Crash during a session save | boot sweep | old manifest intact; unreferenced `audio/` files and `.part` removed | – |
| Session layer missing or damaged | Open inspection | repair list, `Find audio`, exact identity only | 36, 42 |
| Saved interface absent | Open inspection | `Replace` ports, stereo roles kept, occupied ports refused | 43 |
| Eject during a USB take, held take, export or backup | guard registry | refused naming the purpose | 31 `BQc2H` |
| Audio apply or latency measurement while recording | guard registry | refused: `Stop recording first.` | – |
| Power off while recording | power flow | take finalized, session saved, then shutdown | 32 |

## 4. Splitting

Twenty parts, each independently mergeable, each about 700 production lines
or fewer. Native parts carry native tests with literal oracles.

```
Part 1 sha256 + fs sync ──► Part 2 part writer ──► Part 3 stop rules
                                   │                     │
                                   └──► Part 4 checkpoints ─┐
Part 5 part format (Dart) ─────────────────────────────────┼─► Part 8 finalize/recover/held ─► Part 9 recorder state ─► Part 10 USB recovery
Part 6 schema step + identity ─► Part 7 bundle publication ┘           │                      (+ USB P6)
Part 11 guard registry ─► Part 12 power/restart/device/latency        Part 13 Record page (+ Library P7)
Part 7 ─► Part 14 inspection + candidate ─► Part 15 recovery UI
Part 14 ─► Part 16 port bindings ─► Part 17 port repair UI ─► Part 18 CTRL/MIDI rows (needs E7-6)
Part 14 ─► Part 19 target inspection ─► Part 20 target repair UI
```

## 5. Parts

### Part 1: SHA-256, file digests and directory sync (about 260 production lines; native + bindings; depends on nothing)

- `sha256.c` / `sha256.h` in `src/core/`: a vendored public-domain
  implementation (Brad Conte's `crypto-algorithms` `sha256.c`, the common
  dependency-free one), with the licence note in its header. Add it to
  `ENGINE_SRC` in `run_native_tests.sh`, `CMakeLists.txt`, the podspec
  `Classes/` forwarders and the SPM target. The header is included only by
  `.c` files, never by `engine_private.h`, so it does not reach the VST3 C++
  units (PROGRESS "Adding a header to `src/core/`").
- `segno_engine_api.h`: `le_digest_bytes(const void*, uint64_t len, uint8_t out[32])`,
  `le_digest_file(const char* path, uint64_t offset, uint64_t length, uint8_t out[32])`
  (64 KiB stack buffer, `length = UINT64_MAX` means to end of file, returns
  `LE_ERR_DEVICE` on a short file), `le_fs_sync_dir(const char* path)`
  (`open(O_RDONLY|O_DIRECTORY)` + `fsync`; `LE_OK` no-op on Windows). All
  engine-free, so `Isolate.run` can call them.
- Dart: an `EngineStorageIo` role interface in `audio_engine.dart` beside
  `EnginePerformanceCapture` (`:1420`), implemented in
  `native_audio_engine.dart` next to `volumeFreeBytes` (`:2311`) and in the
  mock; regenerated and formatted bindings.

Tests: `test_engine_core.c` gains `test_sha256_known_answers`,
`test_digest_file_ranges`, `test_fs_sync_dir`.

```success-criteria
GOAL: The engine exposes one SHA-256 implementation over memory and over a file range, and a directory fsync, all usable without an engine.
SUCCESS CRITERIA:
- le_digest_bytes("", 0) = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855; "abc" = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad; the 448-bit NIST message "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq" = 248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1; one million 'a' = cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- le_digest_file over bytes [3, 6) of a file holding "xyzabcdef" equals the "abc" digest; over [0, UINT64_MAX) equals le_digest_bytes of the whole content; a range past the end returns LE_ERR_DEVICE; a missing path returns LE_ERR_DEVICE. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- le_fs_sync_dir returns LE_OK on an existing directory and LE_ERR_DEVICE on a missing one. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- ASan and telemetry-off builds pass; bindings regenerated and formatted; symbol parity holds; the C++ shim repro still compiles. | verify: EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-DLE_CALLBACK_TELEMETRY=0' bash packages/segno_engine/src/test/run_native_tests.sh && dart analyze --fatal-infos && packages/segno_engine/tool/check_ffi_symbols.sh <built lib>
- The Dart wrappers return the same digests through the real library. | verify: (cd packages/segno_engine && /Users/Tomas/development/flutter/bin/flutter test)
NON-GOALS:
- Any caller; ARMv8 SHA instructions.
VERIFICATION COMMAND: bash packages/segno_engine/src/test/run_native_tests.sh && (cd packages/segno_engine && /Users/Tomas/development/flutter/bin/flutter test) && dart analyze --fatal-infos
```

### Part 2: the drain writes ordered 24-bit WAV parts (about 620 production lines; native + bindings; depends on Part 1)

- `segno_engine_api.h`: replace `le_perf_arm(engine, const char*)` with
  `le_perf_arm(le_engine*, const le_perf_target*)` (no old form kept,
  AGENTS.md):

  ```c
  typedef struct le_perf_target {
    const char* capture_dir;   /* the bundle directory on the destination */
    const char* mirror_path;   /* Internal file for checkpoint copies; NULL = none (Part 4) */
    uint8_t take_id[16];
    uint64_t part_bytes;       /* 2000000000; tests pass small sizes */
    int32_t ring_seconds;      /* 2 Internal, 8 removable */
    uint64_t reserve_bytes;    /* UINT64_MAX = no budget (Part 3) */
    int32_t checkpoint_ms;     /* 5000; 0 = only on demand (tests, Part 4) */
  } le_perf_target;
  ```

  `ring_seconds` replaces the fixed `LE_PERF_CAPTURE_SECONDS`
  (`engine_private.h:163`, `engine_commands.c:4540`); `reserve_bytes` and
  `checkpoint_ms` are stored here and used by Parts 3 and 4.
- `perf_drain.c`: `le_pd_file` becomes a part stream (`stream`, `channels`,
  `part_index`, `frames_in_part`, `frames_total`, an `le_sha256_ctx`). The
  ring drain converts each popped float block to packed 24-bit in a
  per-session scratch (allocated at start, so the cycle stays
  allocation-free, `perf_drain.c:16-50`), splits the write at the part
  boundary, seals the full part (patch sizes at offsets 4 and 80, `fflush`,
  digest), and opens the next with `"wbe"`-equivalent `O_CLOEXEC`
  descriptors (closing the inheritance window `perf_drain.c:456-462`
  describes). Torn-write flooring (`le_pd_whole_frames_landed`, `:972`) and
  the zero-fill (`:1069`) work in output frame bytes (6 or 3). Seal on stop.
  `events.log` and layer files are unchanged.
- Sidecar: `parts` replaces nothing (new key): `[{stream, index, file,
  frames, bytes, sha256?}]`, `sha256` present once sealed; `take_id` (hex);
  `encoding: "pcm24"`. `channel_layout` keeps its meaning.
- Dart: `perfArm(PerfTarget)` in `EnginePerformanceCapture`
  (`audio_engine.dart:1434`) and `native_audio_engine.dart:2275`; the
  repository passes Internal values (`part_bytes` 2,000,000,000,
  `ring_seconds` 2, `reserve_bytes` UINT64_MAX until Part 3,
  `checkpoint_ms` 0 until Part 4) and a minted `takeId`; `_finalize` reads
  the parts instead of `master.pcm` only far enough to keep it working
  (it writes no `master.wav`; Part 8 replaces it).

Native tests (in `test_engine_core.c`, beside `test_perf_drain_writes_master_pcm_byte_identical` `:9917`):

```success-criteria
GOAL: A capture is written as ordered, sealed, self-identifying 24-bit WAV parts that need no conversion at finalize.
SUCCESS CRITERIA:
- With configure(48000, 1 in, 2 out) and a stereo master, the first 84 bytes of master-001.wav are: "RIFF", u32 size, "WAVE", "fmt ", 16, tag 1, channels 2, rate 80 BB 00 00, byte rate 00 65 04 00 (288000), block align 6, bits 24, "sgno", 32, the 16 take-id bytes, stream 0, part index 1, 12 zero bytes, "data", u32 size. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- Samples 0.5, -1.0, 1.0, 2.0, -0.25, 0.25 are written as 00 00 40, 00 00 80, FF FF 7F, FF FF 7F, 00 00 E0, 00 00 20. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- part_bytes = 84 + 6 * 1000 and 2500 pumped stereo frames give master-001.wav and master-002.wav of 6084 bytes each and master-003.wav of 3084 bytes after disarm, each with its RIFF size (file size - 8) and data size patched, and part indexes 1, 2, 3 in their sgno chunks. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- Each sealed part's sidecar sha256 equals le_digest_file over its data payload, and equals le_digest_bytes of the 24-bit bytes the test builds independently from the pumped floats. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- The existing short-write, zero-fill, disk-full, crash-consistency and allocation-free drain tests pass with sizes in 24-bit frames; a part boundary inside a zero-fill gap still yields whole frames on both sides. | verify: bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-DLE_CALLBACK_TELEMETRY=0' bash packages/segno_engine/src/test/run_native_tests.sh
- An input captured at arm gets input-<n>-001.wav, stereo, stream 1 + n. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- Bindings regenerated; symbol parity; the repository arms through PerfTarget and its package tests pass. | verify: (cd packages/performance_repository && /Users/Tomas/development/flutter/bin/flutter test) && dart analyze --fatal-infos
NON-GOALS:
- Stop rules, checkpoints, finalize and recovery rewrite, any UI.
VERIFICATION COMMAND: bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-DLE_CALLBACK_TELEMETRY=0' bash packages/segno_engine/src/test/run_native_tests.sh && dart analyze --fatal-infos
```

### Part 3: stop at complete frames on reserve and on slow storage (about 380 production lines; native + bindings; depends on Part 2)

- Audio thread: `perf.first_drop_frame` (`_Atomic uint64_t`, `UINT64_MAX`
  at arm). At both drop sites (`engine_process.c:4134-4138`, `:4288-4293`)
  the first failure stores `block_base + f` (the audio thread already owns
  the block's frame base; it is the only writer). The release add at
  `:6875-6879` publishes it.
- Drain: before writing, `limit = min(elapsed, first_drop_frame)` and, with
  a budget, `limit = min(limit, frames_written + budget / bytes_per_frame_all_streams)`
  where the budget is `free_at_sample - reserve_bytes - 1 MiB - written_since_sample`.
  The free sample is refreshed on the checkpoint cadence (Part 4; every
  5 s with `checkpoint_ms` 0 the drain samples on each 20th cycle). Streams
  stop at `limit` together; the drain seals and self-stops with reason
  `slow_storage` or `reserve_reached`. `le_pd_catch_up` pads only to
  `limit`.
- Test hook `le_perf_drain_set_volume_free_for_test(int64_t)` beside the
  existing write-budget hook (`engine_internal.h:368`).
- `le_perf_stop_reason` enum: `NONE 0`, `DISARM`, `DEVICE_CHANGED`,
  `WRITE_FAILED`, `RESERVE_REACHED`, `SLOW_STORAGE`; snapshot tail fields
  `perf_stop_reason`, `perf_bytes_written`, `perf_first_drop_frame`
  (appended at the struct tail, offset-stable). Sidecar strings:
  `reserve_reached`, `slow_storage`; `disk_full` and `device_changed` keep
  their spelling.
- Dart: `PerfStopReason` on the snapshot; the repository passes the
  destination's reserve (Internal 1 GiB, removable 16 MiB).

```success-criteria
GOAL: A take ends at the last whole frame every stream can hold when the reserve is reached or the drain falls behind, and says why.
SUCCESS CRITERIA:
- Mono master, part_bytes 2e9, reserve R, volume-free hook = R + 1048576 + E + 84 + 3 * 700, where E is events.log's size after the arm cycle as the test reads it: after pumping 1000 frames the take holds exactly 700 frames, stopped_early is "reserve_reached", perf_stop_reason reads RESERVE_REACHED, zero_filled_frames is 0. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- The same with one captured stereo input: per-frame bytes are 3 + 6, so the free hook R + 1048576 + E + 84 + 84 + 9 * 500 stops both files at exactly 500 frames. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- With the drain held by the mid-cycle hook and ring_seconds 1, pumping 3 s of audio records a first_drop_frame F with 0 < F < 144000; after release master holds exactly F frames, stopped_early is "slow_storage", zero_filled_frames is 0, and no frame pumped after the drop appears. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- A tap gap without a drop (frames counted but not tapped) still zero-fills and the take continues (the existing #710 test passes unchanged). | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- reserve_bytes = UINT64_MAX never stops on budget; a refused write still stops as "disk_full". | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- ASan, telemetry-off, the allocation-free cycle test, bindings and symbol parity. | verify: EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-DLE_CALLBACK_TELEMETRY=0' bash packages/segno_engine/src/test/run_native_tests.sh && dart analyze --fatal-infos
NON-GOALS:
- Checkpoints, the recorder's reaction, the 60-second warning.
VERIFICATION COMMAND: bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-DLE_CALLBACK_TELEMETRY=0' bash packages/segno_engine/src/test/run_native_tests.sh
```

### Part 4: durable checkpoints and the Internal mirror (about 450 production lines; native; depends on Part 2)

- `perf_drain.c`: the published-progress block (mutex, a few integers per
  stream, sealed digests, `events.log` bytes, layer file names written since
  the last checkpoint), updated after each cycle's `fflush`
  (`perf_drain.c:1426-1431`).
- `perf_checkpoint.c` (new, `perf_checkpoint.h` included only by
  `perf_drain.c`): the thread started and joined with the drain session; the
  loop of D4; `checkpoint.json` keys `version: 1`, `take_id`, `boot_id`,
  `sample_rate`, `encoding`, `frames`, `streams[{stream, channels, parts[{index,
  file, frames, bytes, sha256?}]}]`, `events_bytes`, `layers[]`,
  `written_at_ms`; the mirror write to `mirror_path` (tmp, `fsync`, rename,
  directory `fsync`) when set; a final checkpoint after the drain's last
  cycle on every stop path, including self-stops and `DEVICE_CHANGED`
  (`engine.c:384-387`). Failures increment `perf_checkpoint_failures`
  (snapshot tail) and keep the previous file.
- `le_perf_checkpoint_now_for_test(engine)` for deterministic tests.
- `docs/design/performance-manifest-format.md`: the checkpoint, the mirror,
  the boot-id rule and the 5 s guarantee (#727's "decide what durability is
  owed").

```success-criteria
GOAL: Every few seconds the bundle durably records how much audio it holds, without blocking the drain, and the same record lands on Internal.
SUCCESS CRITERIA:
- With checkpoint_ms 0: pump 1500 frames, run a drain cycle, checkpoint now → checkpoint.json frames 1500, master part 1 frames 1500 and bytes 84 + 6 * 1500 (stereo), events_bytes equal to events.log's size; pump 500 more without a checkpoint → checkpoint.json still reads 1500. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- The mirror file is byte-identical to checkpoint.json after each checkpoint; with mirror_path NULL nothing else is written. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- A checkpoint never names more frames than the drain had flushed when it copied the progress block: with the mid-cycle hook pausing the drain between pop and flush, a concurrent checkpoint reads the previous cycle's count. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- A refused checkpoint write (write-budget hook applied to the checkpoint path) leaves the previous checkpoint.json intact, increments perf_checkpoint_failures, and the take continues. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- Disarm, a self-stop and a reconfigure while armed each leave a final checkpoint whose frames equal the sealed parts' frames. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- The drain cycle stays allocation-free with the checkpoint thread running (the allocator interposer counts only the drain thread). | verify: bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-DLE_CALLBACK_TELEMETRY=0' bash packages/segno_engine/src/test/run_native_tests.sh
- HARDWARE: on the appliance, a 20-minute Internal take and a 20-minute exFAT USB take each read perfZeroFilledFrames 0 and perfOverruns 0 with checkpoints running; cut power at minute 10 and confirm the next boot recovers at least 9:55. | verify: manual on device
NON-GOALS:
- Dart recovery logic, UI.
VERIFICATION COMMAND: bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-DLE_CALLBACK_TELEMETRY=0' bash packages/segno_engine/src/test/run_native_tests.sh
```

### Part 5: the part format in Dart (about 380 production lines; `wav_codec` + `performance_repository` models; depends on nothing)

- `packages/wav_codec`: `Pcm24PartHeader` (read and write the 84-byte
  header, including `sgno`), `Pcm24Writer` (a streaming writer over a
  `RandomAccessFile`: header, append float blocks as 24-bit, seal), a
  bounded `readFrames(file, offset, count)` decoder, and
  `WavCodec.decodeFloat32(bytes, {maxFrames})` (the bound the Library's
  audition needs, Library plan D10). `encodeFloat32` stays for layers.
- `performance_manifest.dart`: `RecordingFormat(sampleRate, channels,
  bitDepth: 24, partBytes, headerBytes: 84)` with `partFrames`, and
  `TakePart(stream, index, file, frames, bytes, sha256)`; the manifest's
  `parts` and `takeId`; `TakeCheckpoint.fromJson`. Pure computation of
  remaining time matching the prototype's `remaining()`
  (`performance-recording-model.js:22-30`): open-part room, then whole parts
  each costing one header.

```success-criteria
GOAL: Dart can read, write and account for the native part format without loading a part into memory.
SUCCESS CRITERIA:
- Pcm24PartHeader round-trips the native header bytes of Part 2's first criterion byte for byte (literal fixture). | verify: (cd packages/wav_codec && /Users/Tomas/development/flutter/bin/flutter test)
- RecordingFormat(48000, 2, partBytes 2000000000).partFrames == 333333319 and its duration formats as 1:55:44; remaining frames with 63000000000 bytes above the reserve and no open part == 10499999552 (31 full parts of 1999999998 bytes, then 166666663 frames in a 32nd). | verify: (cd packages/performance_repository && /Users/Tomas/development/flutter/bin/flutter test)
- Pcm24Writer writes 0.5, -1.0, 1.0 as 00 00 40, 00 00 80, FF FF 7F and seals sizes; readFrames returns the same floats within 1/8388608; decodeFloat32(maxFrames: 10) of a 1000-frame file returns 10 frames. | verify: (cd packages/wav_codec && /Users/Tomas/development/flutter/bin/flutter test)
- wav_codec coverage stays at its floor; analyzer clean. | verify: (cd packages/wav_codec && /Users/Tomas/development/flutter/bin/flutter test --coverage) && dart analyze --fatal-infos
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

### Part 7: atomic bundle publication and the boot sweep (about 560 production lines; `session_repository` + Library wiring; depends on Parts 1 and 6, Library Parts 1 and 3)

- `BundleCommit` in `session_repository`: write missing `audio/<hex>.wav`
  (`.part`, `RandomAccessFile.flush` = `fsync`, rename), sum their bytes
  first and refuse `StorageFailure.full` when they exceed free space, write
  the manifest by tmp + flush + rename + `le_fs_sync_dir`, then collect
  garbage (D5). `save` (`:451-511`) uses it; the in-place layer writes,
  the plain manifest write and `_pruneOrphanLayers` (`:521-532`) go.
  `mixdown.wav` is written by tmp + rename after the commit (a preview, not
  part of the commit).
- Library operations from the Library plan (Part 1 `renameSession`, Part 3
  Save as / Duplicate / Delete / Move, Part 8 restore) run through the
  staging names of D5. `listSessions` and the folder scan skip dot-entries.
- `sweepBundles()` at boot (called where `SessionCubit` starts, before any
  save can run): remove `*.part` files, `.<id>.part/` directories and
  unreferenced `audio/` files; finish `.deleting`; treat a manifest-less
  directory with `audio/` as an interrupted first save and remove it after
  logging (it never published).
- `read` (`:543-590`) loads layers by `file`, unchanged in shape; digest
  checks are Part 14's.

```success-criteria
GOAL: A session save, Save as, duplicate, delete, move or restore either fully happens or leaves the previous state, with audio, history and metadata published by one rename.
SUCCESS CRITERIA:
- Re-saving an unchanged rig writes no audio file (an injected file writer records zero layer writes) and replaces session.json once; adding one overdub writes exactly one new audio/<hex>.wav. | verify: (cd packages/session_repository && /Users/Tomas/development/flutter/bin/flutter test)
- An injected failure after the second of three new audio files leaves session.json byte-identical to before and the bundle opens to the previous rig; the sweep then removes the two orphans and any .part. | verify: (cd packages/session_repository && /Users/Tomas/development/flutter/bin/flutter test)
- An injected failure at the manifest rename leaves the old manifest; after it, every referenced file exists and legacy track*_lane*_L*.wav files are gone. | verify: (cd packages/session_repository && /Users/Tomas/development/flutter/bin/flutter test)
- New bytes larger than the injected free space throw StorageFailure.full with nothing written. | verify: (cd packages/session_repository && /Users/Tomas/development/flutter/bin/flutter test)
- Duplicate interrupted mid-copy leaves only .<id>.part/, which the sweep removes and the catalog never lists; delete interrupted after its rename is finished by the sweep. | verify: (cd packages/session_repository && /Users/Tomas/development/flutter/bin/flutter test) && /Users/Tomas/development/flutter/bin/flutter test test/session test/library
- The real-engine layer round trip still restores every undo/redo layer byte-exact. | verify: /Users/Tomas/development/flutter/bin/flutter test test/session/session_layers_roundtrip_test.dart
- HARDWARE: on the appliance, cut power during a save of a session with 40 layers, ten times; every boot opens either the previous or the new session, never neither. | verify: manual on device
NON-GOALS:
- Recovery UI, performance takes, USB backup format.
VERIFICATION COMMAND: (cd packages/session_repository && /Users/Tomas/development/flutter/bin/flutter test --coverage) && /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos && bloc lint lib test packages
```

### Part 8: finalize, recover and hold without copying (about 640 production lines; `performance_repository`; depends on Parts 2, 3, 4, 5)

- `_finalize` (`performance_repository.dart:941-1046`): read the final
  checkpoint and the sidecar, verify each sealed part's size, write the
  manifest with `parts`, `takeId`, `format` and `finalized: true` through
  tmp + flush + rename + `le_fs_sync_dir`. No PCM read, no `master.wav`.
  `_readRawPcm` goes.
- `recoverCapture` (`:628-629`): the D4 rule. Same boot id (injected reader
  over `/proc/sys/kernel/random/boot_id`): whole frames present in every
  stream, floored to the shortest; otherwise the checkpoint's frames. Each
  stream's open part is truncated and its sizes patched, its digest taken
  with `le_digest_file` in `Isolate.run`, then finalize as above.
- Legacy bundles (`master.pcm` present, no parts): stream-convert each
  `.pcm` into parts with `Pcm24Writer` in 1 MiB chunks in `Isolate.run`,
  after checking free space for 0.75× the source; finalize; delete the
  `.pcm` files only after the finalized manifest is durable. Not enough
  space leaves the bundle untouched for the next boot and reports it
  (#1078's "surface a recoverable failure").
- Held takes: `captureStatus` gains `held(reason)`; on a native self-stop or
  an engine-ended capture (snapshot `isPerfArmed` false while
  `_armedDir != null`) the repository calls `perfDisarm`, keeps the
  directory, and reports `held`. `saveHeld()` runs the recovery finalize;
  `discardHeld()` renames to `.discarding-<slug>` and deletes. The boot
  salvage (`:674-721`) treats `.discarding-*` as unfinished deletes.
- `listCaptures()` (Library Part 7's method, if already merged; otherwise
  added here with Library Part 7's signature) returns duration from `parts`
  and includes `recovered/` takes marked `recovered: true` (pen 48 `Z3V6Z`
  shows a recovered take in the Library; Library Part 7 excluded them).

```success-criteria
GOAL: A take finalizes and recovers in bounded memory without copying audio, a stopped take can be held for the player's choice, and legacy raw captures are recovered too.
SUCCESS CRITERIA:
- Finalize of a three-part fixture writes a manifest whose parts list matches the checkpoint and whose sha256 values match le_digest_file of each part; no file other than performance.json is created or changed. | verify: (cd packages/performance_repository && /Users/Tomas/development/flutter/bin/flutter test)
- Recovery of a fixture whose checkpoint says 1000 frames and whose open part holds 1500: with a different boot id the part is truncated to 84 + 6 * 1000 bytes with data size 6000; with the same boot id it keeps 1500 frames; both read back as finalized. | verify: (cd packages/performance_repository && /Users/Tomas/development/flutter/bin/flutter test)
- A legacy master.pcm fixture converts through a reader that records its largest read (at most 1 MiB) into parts at a small injected partBytes; the .pcm is removed only after the manifest exists; with injected free space below 0.75x the bundle is untouched and the failure is reported. | verify: (cd packages/performance_repository && /Users/Tomas/development/flutter/bin/flutter test)
- A fake engine reporting reserve_reached, slow_storage, disk_full or isPerfArmed false emits held(reason); saveHeld finalizes; discardHeld removes the bundle after the .discarding rename; a crash between the two is finished by boot salvage. | verify: (cd packages/performance_repository && /Users/Tomas/development/flutter/bin/flutter test)
- Performance repository coverage floor (99%) holds. | verify: (cd packages/performance_repository && /Users/Tomas/development/flutter/bin/flutter test --coverage)
- HARDWARE: the 38 GB capture on the appliance (#1078) recovers into parts without the app exceeding 200 MB RSS growth, and plays in the Library. | verify: manual on device
NON-GOALS:
- Recorder cubit and UI, USB mirror recovery, retention changes.
VERIFICATION COMMAND: (cd packages/performance_repository && /Users/Tomas/development/flutter/bin/flutter test --coverage) && (cd packages/wav_codec && /Users/Tomas/development/flutter/bin/flutter test) && dart analyze --fatal-infos
```

### Part 9: recorder state for long, held and failed takes (about 480 production lines; `lib/performance/cubit`; depends on Part 8 and USB Part 6)

- `PerformanceStopReason` (`performance_recorder_state.dart:5-18`) gains
  `reserveReached`, `slowStorage`, `volumeLost` (USB Part 6 adds it; reused)
  and keeps `diskFull` for write failures (copy that does not claim a full
  disk, as the enum's own note demands) and `deviceChanged`.
- States: `Armed` gains `remaining: Duration?`, `format: RecordingFormat`,
  `parts: List<TakePart>`, `nearlyFull: bool` (remaining < 60 s);
  `Held(reason, elapsed, parts, saveFailed, waitingForDrive)`; `Completed`
  unchanged for a normal Stop.
- `PerformanceRecorderCubit`: remove `lowDiskThresholdBytes`,
  `finalizeHeadroomBytes`, `stopFloorFor`, `_checkLowDisk` and
  `_stopForLowDisk` (`:97-123`, `:411-463`); arm refusal reads
  `StorageRepository.space(destination)` against the reserve; remaining
  time from `recordingTimeRemaining` on the existing 20-tick cadence;
  `saveRecovered()`, `discardRecording()`; the device-loss path through
  the repository's `held(deviceChanged)` (fixes the stale Armed state of
  §1).

```success-criteria
GOAL: The recorder reports remaining time and parts while recording, and holds every interrupted take for an explicit Save or Discard.
SUCCESS CRITERIA:
- With 64 GB free, 1 GiB reserve and 48 kHz stereo the Armed state's remaining equals recordingTimeRemaining for 288000 B/s; at 59 s remaining nearlyFull is true; with unknown space remaining is null and arming still succeeds. | verify: /Users/Tomas/development/flutter/bin/flutter test test/performance
- Arming Internal with free space below 1 GiB is refused with noRecordingSpace and arms nothing. | verify: /Users/Tomas/development/flutter/bin/flutter test test/performance
- held(reserveReached) emits Held; saveRecovered emits Finalizing then Completed; a throwing save emits Held(saveFailed: true) and a second saveRecovered succeeds; discardRecording emits Idle only after the repository confirms. | verify: /Users/Tomas/development/flutter/bin/flutter test test/performance
- A device loss while armed (fake engine: isPerfArmed false) emits Held(deviceChanged) within one tick, not Armed. | verify: /Users/Tomas/development/flutter/bin/flutter test test/performance
- No lowDiskThresholdBytes, finalizeHeadroomBytes or stopFloorFor remain. | verify: ! grep -rn -E 'lowDiskThresholdBytes|finalizeHeadroomBytes|stopFloorFor' lib test
- Root coverage, analyzer, Bloc lint. | verify: /Users/Tomas/development/flutter/bin/flutter test --coverage && dart analyze --fatal-infos && bloc lint lib test packages
NON-GOALS:
- Widgets (Part 13), USB reconnect (Part 10).
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos && bloc lint lib test packages
```

### Part 10: direct-USB ownership and same-drive recovery (about 480 production lines; depends on Parts 4, 8, 9 and USB Part 6)

- Arm on a removable destination: `capture_dir =
  <mount>/Segno/Performances/<slug>/`, `ring_seconds` 8, `reserve_bytes`
  16 MiB, `mirror_path = {exportsRoot}/.takes/<takeId>.json`; the
  repository writes the arm snapshot to the mirror too, with the volume
  `fingerprint` and `label`. The `recording` lease (USB Part 6) and the
  `capture` guard (Part 11) are held until the take is finalized or
  discarded, including while held.
- `PerformanceRepository.pendingUsbTakes()` lists mirrors whose bundle is
  absent from every mounted volume; the cubit keeps `Held(waitingForDrive:
  label)` for them. On a volume event, a mounted volume with the same
  fingerprint and a bundle whose checkpoint `take_id` equals the mirror's
  enables `Save recovered audio`; recovery verifies each part's `sgno`
  chunk (`take_id`, stream, index) and sealed digest before finalizing on
  the drive, then deletes the mirror. A different drive is ignored. Boot
  salvage skips mirrors whose drive is absent and leaves them.
- Discard of a USB take whose drive is absent removes only the mirror after
  the confirm, stating that the parts stay on the drive.

```success-criteria
GOAL: A take recorded to USB is owned by that drive, survives a pull or power cut as a held take, and is recovered only from the same drive's exact parts.
SUCCESS CRITERIA:
- With a fake mounted volume, arming to USB creates <mount>/Segno/Performances/<slug>/ and .takes/<takeId>.json on Internal, the PerfTarget has ring_seconds 8 and reserve 16 MiB, and a recording lease and capture guard are held. | verify: (cd packages/performance_repository && /Users/Tomas/development/flutter/bin/flutter test) && /Users/Tomas/development/flutter/bin/flutter test test/performance
- Detach while armed → Held(volumeLost, waitingForDrive: 'SEGNO USB'); attaching a volume with another fingerprint changes nothing; attaching the same fingerprint enables save; saveRecovered finalizes on the drive and removes the mirror. | verify: /Users/Tomas/development/flutter/bin/flutter test test/performance
- A part whose sgno take id differs, or whose sealed digest does not match, makes recovery refuse with the part named and leaves everything untouched. | verify: (cd packages/performance_repository && /Users/Tomas/development/flutter/bin/flutter test)
- Eject of the volume is refused while the take is armed or held. | verify: /Users/Tomas/development/flutter/bin/flutter test test/storage test/performance
- HARDWARE: record to an exFAT stick with loops playing; pull it at 1:00; loops keep playing and the page reads "Reconnect SEGNO USB. Saved parts stay on that drive."; reinsert, Save recovered audio, and the take plays to at least 0:55 on a laptop; repeat with a power cut instead of a pull; repeat on FAT32. | verify: manual on device
NON-GOALS:
- Copying a USB take to Internal (Library export/import), the picker itself (USB Part 6).
VERIFICATION COMMAND: (cd packages/performance_repository && /Users/Tomas/development/flutter/bin/flutter test) && /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos && bloc lint lib test packages
```

### Part 11: the guard registry (about 420 production lines; new `packages/operation_guards` + wiring; depends on USB Part 4)

- The package: `GuardKind`, `GuardScope`, the D8 matrix as one `const`
  table, `GuardRegistry.enter/blockers`, `OperationGuard.release`, and a
  `purpose` string for the Storage page's disabled-Eject subtitle.
  `flutter_package.yml` job with `min_coverage: 100`.
- Wiring for capture, sessionApply, sessionWrite, transfer and eject:
  `PerformanceRepository.arm` (refusal returns `EngineResult.ok` with the
  existing silent-refusal shape plus a `refusedBy` on `captureStatus`, so
  the pedal path and the cubit see the same reason); `SessionCubit` and
  `SessionRepository`'s commit; `StorageRepository.acquire`/`eject` enter
  `transfer`/`eject` (its `EjectRefused(holders)` now lists guards).
  Provided in `run_segno.dart` beside the other repositories.

```success-criteria
GOAL: Capture, session apply and write, transfer and eject consult one table at their commit points.
SUCCESS CRITERIA:
- A table-driven test enumerates all 64 (wants, active) pairs, same and different scope, against the D8 literal table. | verify: (cd packages/operation_guards && /Users/Tomas/development/flutter/bin/flutter test --coverage)
- Opening a dialog does not take a guard: an eject started after an export dialog opened but before its copy began succeeds, and the copy is then refused at its commit with the eject named. | verify: /Users/Tomas/development/flutter/bin/flutter test test/storage test/library
- Arming while a session apply holds its guard is refused with refusedBy sessionApply through both the cubit and the pedal path. | verify: /Users/Tomas/development/flutter/bin/flutter test test/performance test/control
- Two saves of the same bundle: the second is refused until the first releases. | verify: (cd packages/session_repository && /Users/Tomas/development/flutter/bin/flutter test)
- Analyzer, Bloc lint, root coverage. | verify: /Users/Tomas/development/flutter/bin/flutter test --coverage && dart analyze --fatal-infos && bloc lint lib test packages
NON-GOALS:
- Power, restart, audio apply and latency (Part 12).
VERIFICATION COMMAND: (cd packages/operation_guards && /Users/Tomas/development/flutter/bin/flutter test) && /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos && bloc lint lib test packages
```

### Part 12: power, restart, audio apply and latency honour the guards (about 430 production lines; `lib/appliance`, `lib/update`, `lib/audio_setup`; depends on Parts 9 and 11)

- Power off (`power_off_gate.dart:48-73`, `power_off_cubit.dart:61-111`):
  a performance take is finalized (`disarmAndFinalize`) and the session is
  saved before `restart` is entered; a held take is finalized by
  `saveRecovered` first, and if that fails the shutdown stops on the
  existing failure face with Retry and no discard shortcut (AB §7.8); a
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
- Power off while recording: disarmAndFinalize, then session save, then halt, in that order (mock call order); a failed finalize stops before halt with Retry. | verify: /Users/Tomas/development/flutter/bin/flutter test test/appliance
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
  (`48 kHz · 2 channels · 24-bit PCM`, from the frozen format), `Save to`
  with USB Part 6's picker, `Follow output volume` (existing setter,
  `segno_engine_api.h:2749`), the `Main output` card, the parts list
  (`5 file parts · One take`, `Playback and export use these parts in
  order.`, `1. 1:55:44`), the reserve warning, the held notes and `Save
  recovered audio` / `Discard recording` (with the existing confirm dialog
  for Discard), `View recording` / `Record another`, `Start recording` /
  `Stop recording`. The reason copies: reserve (`yzmtU`), USB (`HWH3p`),
  generic and slow storage (`dgedL`: `The available recording can be
  saved. It may be incomplete.`), save failure (`owAnd`).
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
- Widget tests for Ready, Recording with 52:45:49 remaining and five parts, Capacity unavailable, nearly full, reserve held, USB held waiting for SEGNO USB (Save disabled), interrupted, save failure and saved, each asserting the pen strings quoted above. | verify: /Users/Tomas/development/flutter/bin/flutter test test/performance/view
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

### Part 15: the recovery panels (about 520 production lines; `lib/library/view`; depends on Part 14)

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
  session.` / `Audio setup` (`LaqVi`).
- `LibraryCubit` holds the candidate; leaving the Library discards it.

```success-criteria
GOAL: The player can find each missing recording, see it marked ready, and open the session, or cancel with nothing changed.
SUCCESS CRITERIA:
- Widget tests for DEY0v, KNzYO, l3bgeK, b28GI1, w9WB8, sra8u and LaqVi states with the pen strings; a candidate row tap marks the item Ready and changes no file. | verify: /Users/Tomas/development/flutter/bin/flutter test test/library
- Cancel and navigating away call no repository write; Open session calls apply once; an apply failure shows the retry line and keeps the choices. | verify: /Users/Tomas/development/flutter/bin/flutter test test/library
- Encoder and touch both reach every control (the Library's existing focus tests extended). | verify: /Users/Tomas/development/flutter/bin/flutter test test/library
- Root coverage, analyzer, Bloc lint. | verify: /Users/Tomas/development/flutter/bin/flutter test --coverage && dart analyze --fatal-infos && bloc lint lib test packages
NON-GOALS:
- Backing rows (arrive with E7-8).
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

### Part 18: CTRL and MIDI connection rows (about 420 production lines; depends on Part 17 and on session-owned external and MIDI assignments, inventory E7-6)

AB §6.9 makes musical MIDI assignments and expression ranges session-owned,
but today all of them are global (`settings_repository.dart:535-560`,
`pedal_setup.dart:275`) and the session's remap covers built-in pedals only
(`pedal_binding.dart:24-50`). A session cannot "need expression on CTRL 1"
until it carries those assignments, so this part waits for that move (no
issue exists for E7-6; see §8).

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
- Moving assignments into the session (E7-6).
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
| 1 SHA-256, digests, dir sync | ~260 | – | auto |
| 2 24-bit WAV parts | ~620 | 1 | merge-gate (capture format) |
| 3 reserve and slow-storage stops | ~380 | 2 | merge-gate |
| 4 checkpoints and mirror | ~450 | 2 | merge-gate (blocked-verify for the power-cut criterion) |
| 5 part format in Dart | ~380 | – | auto |
| 6 layer identity + schema step | ~380 | 1, #1196 | merge-gate (schema) |
| 7 atomic bundle publication + sweep | ~560 | 1, 6, Library P1/P3 | merge-gate |
| 8 finalize, recover, hold | ~640 | 2, 3, 4, 5 | merge-gate |
| 9 recorder state | ~480 | 8, USB P6 | auto |
| 10 USB ownership + same-drive recovery | ~480 | 4, 8, 9, USB P6 | blocked-verify |
| 11 guard registry | ~420 | USB P4 | auto |
| 12 power, restart, apply, latency | ~430 | 9, 11 | merge-gate |
| 13 Record performance page + indicator | ~640 | 9, USB P6, Library P7 | merge-gate (screen) |
| 14 Open inspection + candidate | ~560 | 7, Library P4 | auto |
| 15 recovery panels | ~520 | 14 | merge-gate (screen) |
| 16 port bindings + remap | ~540 | 6, 14 | merge-gate (schema) |
| 17 port repair panels | ~480 | 15, 16 | merge-gate |
| 18 CTRL and MIDI rows | ~420 | 17, E7-6 | merge-gate |
| 19 target inspection + repoint | ~400 | 14 | auto |
| 20 control repair panels | ~520 | 15, 19 | merge-gate |

Parts 1, 5 and 11 can start at once. The capture chain is 1 → 2 → {3, 4} →
8 → 9 → {10, 12, 13}. The publication chain is 1 → 6 → 7 → 14 → {15, 16,
19}. Library Part 7 should take D3's parts contract (listing, audition from
part 1, multi-part export) if it lands before Part 8; otherwise Part 8
adjusts its `listCaptures`.

## 7. Hardware-only

- **Power cut**: the checkpoint guarantee (Part 4: at most the last 5 s
  lost after a cut, nothing lost after an app crash), bundle publication
  (Part 7: the previous or the new session, never neither), power-off
  finishing a take (Part 12).
- **Real USB**: direct recording to exFAT and FAT32 sticks at 48 and
  96 kHz with loops playing, a pull mid-take and same-drive recovery, a
  different drive refused, eject refused while armed or held (Part 10); the
  8 s ring absorbing real flash stalls with `perfZeroFilledFrames` and
  `perfOverruns` at 0 and checkpoints running (Part 4); a slow stick ending
  as `slow_storage` rather than with silence (Part 3).
- **Capacity**: a take on a nearly full Internal stopping at the reserve
  with the session still savable (Parts 3, 7, 9).
- **Large legacy capture**: the 38 GB bundle of #1078 (Part 8).
- **Interfaces and pedals**: a second audio interface for port repair
  (Part 17); a dual switch and an expression pedal for CTRL repair
  (Part 18).

## 8. Open points

Defaults taken under the standing rules (override on the issue): the 5 s
checkpoint interval; the 8 s USB ring; 16 MiB removable floor; no dither;
`sgno` chunk; the boot-id rule; restart cancelling latency measurement;
power off refusing (not closing) a loop still recording; recovered takes
listed in the Library.

Genuine questions:

1. **Retention of recovered takes.** Boot salvage moves crashed takes into
   `recovered/` and deletes them 30 days later
   (`performance_repository.dart:114-147`, `:868-899`). Pen 48 `Z3V6Z`
   lists a recovered take as an ordinary Library recording, so automatic
   deletion would remove a Library item the player never deleted. Default
   taken in Part 8: list them and **stop the 30-day prune** (rule 2: keep
   recoverable material). Alternative: keep the prune and show the expiry
   date on the row.
2. **Session-owned external and MIDI assignments (E7-6) have no issue.**
   AB §6.9 requires musical MIDI assignments and expression ranges to recall
   with the session; today they are global. Part 18 cannot start without
   that move. It needs its own issue and plan; this plan does not take it
   on.
