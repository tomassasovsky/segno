# Backing player: prepared list, transport, routing, foot Backing and the Mixer strip

Tracking: #1200 (gap inventory E7-8, E6-8, E3-3, E5-6 and the backing and
click targets of E6-12), `stage:plan`, `autonomy:merge-gate` (a new native
audio source, a new session field and new performance surfaces: verifiable
here, but taste and blast radius are the owner's). Base:
`origin/claude/segno-integration` at `5c163d11f`. Unless a branch is named,
every `file:line` below is on that head. Other heads cited:
`origin/claude/library-1178-p3` at `2d88d96ce` (the Library plan,
`docs/plan/2026-10-06-feat-library-sessions-plan.md` there, and its
`RemovableVolumes` port) and `origin/claude/usb-storage-1177-p4` at
`3dbb98421` (`packages/storage_repository`). Format precedent:
`docs/plan/2026-10-05-feat-engine-reopen-plan.md` and
`docs/plan/2026-10-05-feat-stem-history-replay-plan.md`.

Owner decisions applied: the settings tray and Bluetooth page are retired (this
plan adds nothing to them); DAW export lives under Library > Audio; USB gadget
mode is out of scope; saved v7 sessions migrate on open (#1196), so this plan's
schema bump adds its own step to that chain; the trunk already carries settings
consolidation (#1159), Reverse P1, Peel P1, pitch/time P1, USB storage P1-P3
and Library P1-P3 (in review).

## 1. Current boundary (verified, pre-change)

- **No backing source exists anywhere.** The engine has no backing voice,
  command, API or snapshot field (`grep -i backing packages/segno_engine/src/core`
  finds only comments: `segno_engine_api.h:2834`, and an unrelated overdub
  local at `engine_process.c:5896`). Output routing says so in code: the
  `players` kind draws a single `Click` card because "the accepted design's
  backing track has no engine, repository or bloc seam yet"
  (`lib/looper/view/audio_routing/output_routing_tab.dart:326-336`, kind enum
  `:29-30`, mask read `:123-124`, send `:138-139`).
- **The click is the closest independent source, and the template.** It is a
  synthesized voice with its own output mask and volume
  (`LE_CMD_SET_CLICK_OUTPUT` 22, `LE_CMD_SET_CLICK_VOLUME` 24,
  `segno_engine_api.h:254-260`; API `:2235-2242`; handlers
  `engine_process.c:3450-3465`). Since slice 3b it sums into its masked
  channels **before** the output buses (`engine_process.c:4296-4302`, call site
  `:6767-6768`, bus loop `:6771-6775`), so a destination's chain, level and
  mute process it, the master gain, limiter and output meters see it, and the
  Record performance tap on the captured bus contains it
  (`output_bus_frame` `:4192-4207`, `perf_tap_master_pair` `:4141-4147`). It
  is never perf-logged (`:313-322`, `:3429-3433`), so the offline renderer,
  which rebuilds stems and its master from tracks only (`perf_render.c:14-36`),
  never contains it. Two header comments still describe the pre-3b click as
  bypassing master gain and never appearing in captures
  (`segno_engine_api.h:242-246`, `:2218-2226`); they are stale.
- **The click has no pan.** `click_frame` writes one mono sample to every
  masked channel (`engine_process.c:4412-4470`); there is no pan command,
  owner or target. The stereo fan-out every other source uses is
  `le_fx_route_frame` (`:2534-2566`) with gains from the unity-centre pan law
  `le_pan_gains` (`engine_private.h:393-411`).
- **Engine lifetimes.** `le_engine_configure` quiesces the workers and resets
  material and runtime (`engine.c:885-892`); a retained reopen at the same
  rate quiesces and resets runtime only (`engine.c:932-972`, the material/runtime
  split documented at `:415-421`). Cut sound is `handle_cut_sound`
  (`engine_process.c:2201-2230`, applied `:3862-3865`), and the catalogue
  already promises it stops backing: "Stop tracks and backing and end existing
  effect tails" (`lib/control/binding/control_action.dart:208-209`).
- **Decoding is compiled out.** `miniaudio_impl.c:10` defines
  `MA_NO_DECODING`; the only file reader in Dart is `packages/wav_codec`
  (WAV only). The only resamplers are the exact 2:1 half-band pair
  (`restore_halfband.h:1-45`), the pitch/time plan's two-tap fractional read
  head (`docs/plan/2026-10-06-feat-pitch-time-core-plan.md` D1, `:190-197`)
  and the vendored Signalsmith DSP headers under
  `packages/segno_engine/third_party/signalsmith-stretch/dsp/`, compiled only
  through `src/stretch/le_stretch.cpp`.
- **Mixer.** Eight-strip `MixerColumn` (`lib/looper/view/mixer_column.dart:37`)
  hosted by `_MixerSlot` (`lib/looper/view/tracks_view.dart:559-597`); the
  Mixer-only top action is `_ResetMixerButton`
  (`lib/looper/view/stage_top_bar.dart:62-64`, `:162-223`). There is no
  `Backing & click` entry.
- **Catalogue.** `ControlActionGroup.backing` is declared and empty ("Empty
  until the audio library part", `control_action.dart:66-68`); its heading is
  localized (`control_action_labels.dart:50`, `app_en.arb:4818`). Value targets
  include `ClickVolumeTarget` (`lib/control/binding/control_value_target.dart:401-428`,
  parse `:113-115`) and none for click pan, backing level or backing pan.
- **Click owners.** Click volume and Hear click are #1159 `SettingsOwner`
  families (`lib/looper/application/tempo_settings.dart:19-47`,
  `ClickVolumeFamily` `settings_families.dart:16-60`); the click mask is a
  plain `TempoSettings` setter persisted through `SettingsRepository`
  (`tempo_settings.dart:160-176`, `:214-220`) and replayed by
  `LooperRepository` after a reconfigure (`looper_repository.dart:2540-2560`).
- **Session.** Schema `formatVersion = 11` (`packages/session_repository/lib/src/models/session.dart:847`),
  strict decode of the current version only (`:751-760`); Peel takes 12 on
  `origin/claude/peel-1164-p2` (`session.dart:844` there) and Reverse 13
  (#1196's text). Session capture goes through
  `SessionSettingsCoordinator.capture` (`lib/session/application/session_settings_coordinator.dart:61-96`)
  into `settingsFromLooper` (`lib/session/session_mapping.dart:103-170`) and
  back through the bundle mapper (`:300-330`).
- **Interaction modes.** `InteractionMode` has record, mute, fx, custom, mixer
  and fade (`lib/looper/model/interaction_mode.dart:8-49`). Foot Fade is the
  newest performance surface and the pattern to copy: a role table, a
  stateless action adapter, a `ControlCubit` part extension
  (`lib/control/cubit/control_foot_fade.dart:1-75`,
  `lib/control/foot_fade_actions.dart`, `lib/looper/view/foot_fade_view.dart`).
- **Library (in review, `library-1178-p3`).** Library > Audio is Part 7 of
  that plan and lists `Performances` and `Sessions` only; it explicitly leaves
  `Add to prepared`, `Use as backing`, the sub-nav row and the `Backing tracks`
  group to E7-7/E7-8 (its section 2 deviations 2 and 3, Part 7 non-goals). Its
  D6 records that "the first shared reference arrives with backing", its D8
  playback predicate covers tracks only, and its section 6 leaves "prepared
  backing (E7-8)" to confirm. Its audition voice (section 4.4, Part 6a) is an
  engine-owned one-shot PCM voice with an atomic slot, a block-end ack and a
  control-thread free; Part 6a is not built yet.
- **USB storage (#1177, `usb-storage-1177-p4`).** `StorageRepository.acquire`
  checks writability before it grants a lease
  (`packages/storage_repository/lib/src/storage_repository.dart:174-185`,
  `_checkWritable` `:209-226` refuses a read-only drive), `copyFile` holds a
  lease on the **destination** only (`:388-422`), and `WriteLease.lost`
  completes when the drive goes (`write_lease.dart:6-56`). Nothing yet holds a
  drive that is only being **read**.

## 2. Design sources (`segno-ui.pen`, group `01 CURRENT UX`)

| Screen | What it fixes |
|---|---|
| 18/01 `Audio library / Internal` (`bx7vK`) | The `Backing tracks` group heading in the Internal list; preview actions `Add to prepared`, `Export to USB`, `Use as backing`, `Use in loop`; sub-nav `Prepared audio` / `Save audio` / `Record performance`. |
| 18/02 `Audio library / USB drive` (`B5q2Q`) | A drive folder (`Live set`) of `.wav` and `.mp3` files; an unreadable file shows `—` for its duration; caption "Copies to Internal, so you can unplug the drive."; actions `Add to prepared`, `Use as backing`, `Use in loop`. |
| 18/05 `Backing track / Ready` (`OIOV1`) | The player page: `Choose audio`, `Clear backing`, kind and duration (`WAV · 3:42`), name, waveform with `0:00` / `3:42`, `Level 0.0 dB` with `−` `+` `Unity`, `Pan Center` with `−` `+` `Center`, `Stop`, `Play`. |
| 18/06 `USB disconnected` (`jsmae`) | "Connect a USB drive / Your internal audio is still available." |
| 18/07 `Prepared audio / Performance order` (`EM37x`) | Numbered rows, `Move up` / `Move down` beside the `Performance order` heading, `Perform` and `Save audio` top right, preview with `Preview`, `Remove from prepared`, `Export to USB`, `Use as backing`, `Use in loop`. |
| 18/08 `Backing / Ready` (`Vbg8o`) | The foot surface on the ten-pedal map: Record/Play `Play · Backing audio`, Stop `Stop · Backing audio`, Undo `Previous · Hold: −10 seconds`, Mode `Exit`, Track 1-4 the page's four prepared items, Clear (raised) `Next · Hold: +10 seconds`, Bank (raised) `Page 1 / 3 · Hold: At end`; the header `Ready · Evening lights`, a position bar `0:00` / `3:42`, `At end` `Stop` `Repeat` `Next`, `Prepared audio · 9 recordings`. |
| 18/09 `Backing / Playing and selected` (`xI2WT`) | `Playing`; a different selection reads `Selected · press Play` and Record/Play reads `Play selected`; the playing item's pedal says `Playing`, the selected one `Selected` (amber outline). |
| 18/10 `Backing / More prepared audio` (`wotfZ`) | Page 2 / 3. |
| 18/11 `Backing / Nothing prepared` (`g7wH7`) | `No audio loaded`, `Nothing prepared yet · 0 recordings · Add audio in Library before performing.`, empty pedals `—`. |
| 21/04 `Backing & click` (`Z3tJMK`) | Output routing kind `Backing & click` with a `Backing track` / `Click` choice, then `Send to`. |
| 25 `Mixer · Backing & click / Tile` (`bZDIR`) | A `Backing & click` button in the Mixer top actions (frame `IwBG4`, x 1392) opening a 1260 x 549 dialog: `Backing · Prepared audio` with `Volume` and `Pan`, `Click · <Hear click mode>` with `Volume` and `Pan`, `Done`. |
| 28 `Apply during playback / Tile` (`btTbs`) | "Loops and backing audio will stop. Your recordings stay intact." |

Behavior references: accepted 6.4, 6.5 (managed internal copy), 6.9 (recall
restores prepared backing), 3.1 (output FX process backing and click), 3.11
(renders exclude backing and click), section 4's Backing row, 1.6 (Mixer
auxiliary level/pan), 4.11 (shared targets cover backing/click); the
interaction study `docs/design/2026-09-08-backing-playback-ux.md` and
`docs/design/backing-performance-study.js` in the main checkout (untracked;
the pedal roles and the Next/selection-following rules below come from
`assignments()` and `run()` there).

**Deviations the build must write back into the pen** (none planned beyond):
the Mixer dialog subtitle for Backing shows the loaded file's name when one is
loaded and `Prepared audio` otherwise (the pen draws only the latter).

## 3. Decisions

### D1 Preload, never stream

A backing file is decoded and resampled once, off the audio thread, into an
engine-owned interleaved stereo float32 buffer at the engine rate, and played
from RAM. Reasons:

1. Every accepted operation is exact and I/O-free on the audio thread: seek is
   an index store, Repeat wraps at the last frame, Next is a gapless pointer
   swap at a known frame, Stop rewinds. A streamed player turns each of these
   into a reader-thread flush and refill with an underrun window, and the
   appliance boots from an SD card or NVMe whose stalls we do not control
   during a performance.
2. Established players with a load state do this: Looper X's backing player
   has "empty, loading, and loaded states" over FFmpeg
   (`docs/research/sheeran-looper-x-1.0.2/features.md` F11), and RAM-loaded
   tracks are the norm on performance players.
3. The cost is bounded and measurable. Stereo float32 is 23 MB per minute at
   48 kHz and 46 MB per minute at 96 kHz. `LE_BACKING_MAX_SECONDS` is 900
   (15 minutes: 346 MB at 48 kHz, 691 MB at 96 kHz per buffer). At most two
   full buffers are resident: the loaded one plus either the staged Next or a
   pending `Play selected` decode, never both, because starting a
   `Play selected` decode first releases the staged Next (it belongs to the
   outgoing file and is re-staged for whichever file ends up loaded). A
   replaced buffer outlives its replacement by at most one audio block. A
   file over the cap is refused at import with the reason, never truncated.

Selection does not pre-decode: `Play selected` decodes on demand while the
current file keeps playing, then switches (AB 6.4 "Selecting a different
backing file leaves the current one playing until Play"; the library study's
"The old file stays loaded until the new load or copy succeeds"). Only an
`At end: Next` decodes ahead, because gapless continuation needs it.

### D2 Decode path: miniaudio's decoders, natively, in a Dart background isolate

- **Formats:** WAV (PCM 8/16/24/32, float 32/64), FLAC and MP3, the three
  decoders miniaudio already vendors (dr_wav, dr_flac, dr_mp3) and that
  `MA_NO_DECODING` (`miniaudio_impl.c:10`) compiles out today. The pen shows
  `.wav` and `.mp3` (18/02). Mono files play dual-mono; files with more than
  two channels are refused ("Only mono and stereo files can be used."), not
  silently downmixed. Anything else, a damaged file, or a file over the cap is
  refused at import with its reason and listed with `—` (18/02's damaged row).
  `MA_NO_ENCODING`, `MA_NO_RESOURCE_MANAGER` and the rest stay.
- **Where:** one pure native function, `le_backing_decode_file` (no engine
  handle, never on the audio thread), called from `Isolate.run` in Dart with
  the library opened by the existing top-level `_openLibrary()`
  (`packages/segno_engine/lib/src/native_audio_engine.dart:39-48`). The UI
  isolate never decodes; no new native thread is added. The function returns
  an owned `le_backing_buffer*` (address crossing the isolate boundary as an
  integer) plus 512 peak buckets for the waveform. Ownership passes to the
  engine on a successful `load`/`stage_next`; every other path frees it
  explicitly.
- **Validation at import:** importing decodes once to prove the file plays and
  to record its duration and peaks (`info.json`, D7). A file that cannot
  decode never enters `Backing tracks`, so a performance never meets a
  damaged file first.

### D3 Sample-rate conversion: offline windowed sinc from the vendored Signalsmith DSP

The pitch/time plan's resampling is the wrong tool here, checked piece by piece:
its read head is a two-tap fractional read for real-time varispeed (D1 there),
whose imaging and aliasing are acceptable for a performance effect but not for
a whole file converted once; `le_stretch_render_offline` is a phase vocoder
that would smear transients for a ratio near 1; the half-band pair converts
2:1 only. What it does give us is the vendored, already compiled
`signalsmith::delay::InterpolatorKaiserSincN` (`third_party/signalsmith-stretch/dsp/delay.h`,
`InterpolatorKaiserSincN<Sample, n>`), a Kaiser-windowed sinc with a
configurable pass and stop band.

`le_resample_offline` is added to `src/stretch/le_stretch.cpp` (it stays the
one TU that includes Signalsmith): a 64-tap `InterpolatorKaiserSincN<float, 64>`
read at `t · in_rate / out_rate`, with pass/stop at `0.42 r` / `0.55 r` where
`r = min(1, out_rate / in_rate)` and the output scaled by `pass + stop` so DC
gain stays 1. Ratios below 0.5 first decimate through `le_halfband_decimate`
until `r >= 0.5` (a 192 kHz file on a 48 kHz engine). Equal rates copy
bit-exactly. Output length is `floor(in_frames · out_rate / in_rate)`.
Aliases from the transition band fold only above `0.45 · out_rate` (above
19.8 kHz at 44.1 kHz). Offline cost is 64 MACs per output sample per channel;
on a Pi 5 a five-minute file at 96 kHz is about 58 M output samples, under a
second of CPU (measured on the appliance in Part 2). This is the decode-time
converter; the audio thread never resamples.

### D4 Transport, seek and End semantics (accepted 6.4, section 4's Backing row)

- **Play** loads the selection, or toggles Pause when the selection is the
  loaded file. Loading a new selection while another plays keeps the old one
  audible until the new buffer is installed, then switches at a block
  boundary with a 5 ms fade-out of the old file (`LE_BACKING_RAMP_MS 5`); the
  new file starts at frame 0 unfaded. A failed decode leaves the old file
  loaded and playing and reports the reason.
- **Pause** fades out over 5 ms and keeps the position; resume fades in over
  5 ms. **Stop** fades out over 5 ms and rewinds to 0. Stop also cancels a
  pending `Play selected` decode (its result is freed; the old file stays
  loaded, stopped at 0).
- **Seek** addresses the **loaded** file even when another is selected; it
  clamps to `[0, frames - 1]` and preserves playing or paused. While playing it
  fades out 5 ms, jumps and fades in 5 ms. By foot, hold Previous is −10 s and
  hold Next is +10 s; a hold consumes the press, so it never also changes
  selection. On screen the position bar is a seek slider: touch seeks at once;
  encoder press starts a draft, turn moves it in seconds, press commits, Back
  cancels; double tap rewinds to 0 (AB 1.8; the study's `finish`/`reset`).
- **End** is one selector, default **Stop**: Stop stops and rewinds. **Repeat**
  wraps from the last frame to frame 0 with no gap and no fade.
  **Next** continues gaplessly into the staged buffer of the following
  prepared item; after the last prepared item, or when the loaded file is no
  longer in the prepared list, it stops and rewinds and never wraps. If the
  following item could not be decoded, or was not ready, it stops and reports
  "Couldn't play <name>: <reason>" (the study's "A failed automatic load stops
  and reports the problem").
- **Automatic Next and selection:** when the selection was following the
  loaded file, it follows the new one and its page; a different pending manual
  selection stays selected until Play (the study's `sync()`).
- **Clear backing** asks first ("Clear backing? Stops and unloads; prepared
  audio stays."), then unloads the player; the file and its prepared-list
  membership stay (AB 6.4). **Remove from prepared** only removes the entry;
  the file and any playing audio stay (library study).
- **Exit** returns to Tracks and preserves playback. Loop Stop, Undo, Clear,
  Clear All, mode changes and mix edits never touch the backing transport; Cut
  sound stops it at once (no fade, AB 3.6 "immediately stops audible sources")
  and rewinds, as its catalogue label already says.

### D5 Where the backing sounds, and what it is excluded from

Exactly where the click sums today: into its masked output channels after the
live monitors and before the output-bus loop (`engine_process.c:6767-6775`),
through `le_fx_route_frame` with `le_pan_gains` (pan acts as balance on the
stereo file). So output FX, level, Mono and mute process it (AB 3.1), master
gain, limiter, output meters and the loop viz see it, and a Record performance
contains it when it is routed to the captured bus (AB 6.6 "captures everything
routed to its output"). It is **never perf-logged**, so the offline stems and
the renderer's reconstructed master never contain it, and a loop take never
contains it (lanes read inputs, never outputs). The future shared render
recipe (E5-1: Bounce, Save selected audio, AB 3.11) is track-only by
construction; its plan must keep it so. No loop transport, tempo, Speed,
Transpose or Reverse affects the backing (AB section 4 Speed row: "backing ...
unaffected"); the backing has no tempo control (Looper X F11 has none either).

### D6 Click pan joins the click, in the same part

The Mixer dialog draws `Pan` for the click (25 `bZDIR`), and E6-12 asks for
click level and pan targets. `click_frame` moves from the per-channel write to
`le_fx_route_frame` with `le_pan_gains(click_pan)`. At centre the gains are 1
and `le_fx_route_frame` writes the same mono sample to every masked channel,
so every existing click test is unchanged (rule 1). Click pan becomes a
`ClickPanFamily` beside `ClickVolumeFamily`, saved with the session like
click volume.

### D7 Managed internal copies with content identity (AB 6.5, 6.9)

Backing never plays from a drive: `Add to prepared` and `Use as backing` copy a
USB file into Internal first (18/02's caption; AB 6.5 "makes a managed
internal copy, independent of drive removal"). So eject never interrupts a
performance and the player never holds a removable volume. The store is
`<exportsRoot>/Backing tracks/<id>/<original file name>` plus a derived
`info.json` (`name`, `sourceRate`, `sourceChannels`, `seconds`, 512 `peaks`),
where `id` is the first 16 hex digits of the file's SHA-256. The id is the
stable identity AB 6.9 and 6.10 require ("same name is not enough"):
importing identical bytes again reuses the existing copy (the study's "reuses
its copy"), two files with the same name and different bytes coexist, and a
session references assets by id. The copy itself is #1177's `copyFile`
(`.part`, fsync, rename) to `StorageDestination.internal()`, so a full disk or
a failed write leaves nothing behind. A USB source is held for the copy's
duration by a **read hold** (D8). `info.json` is derived; a missing or
unreadable one lists the asset as unavailable with `—` until it re-validates.
There is no Delete for audio in the accepted design, so no reference check is
needed yet (Library D6's note); when E7-7 adds one, it must check every saved
session's prepared ids.

### D8 Eject: a read hold on the source drive

`StorageRepository` gains `withReadHold(RemovableDestination source, String
purpose, body)`: it registers a lease with the purpose `Copying <name> to
Backing tracks` exactly like `acquire` (`storage_repository.dart:174-185`) but
skips the writability verdicts that only matter to writers (`readOnly`), still
refusing an absent, ejecting, ejected, unsupported or unmounted drive. Eject is
then refused naming the copy, and a pulled drive completes `lost`, which
aborts the copy (the part file is deleted by `copyFile`'s own failure path and
nothing is added to the store). The Library port gets the same method. Rule 4:
one lease registry, not a second "busy" flag.

### D9 Recall ownership (E7-6): the prepared setup is the session's, the files are the appliance's

Per AB 6.9 ("Recall restores ... prepared backing"), the session owns: the
prepared order (ids with their display names, so a missing item can still be
named), the loaded item id, `At end`, backing level, pan and output mask, and
click pan. The appliance owns the `Backing tracks` files themselves (they
survive New Loop, session delete and session backup; AB 6.8 puts backing in
the complete appliance backup, E7-15, not in a session backup). Playback
always restores **stopped at 0** (the playback study: "Playback itself always
starts stopped after reload"; AB 6.1 "Restored transport starts stopped").
New Loop keeps the whole prepared setup and stops the player (AB 6.1
"prepared backing remains stopped"). A recalled id with no file is a
`Missing` row that cannot be loaded and says so (repair is E7-16); it is never
dropped silently and never matched by name. Level, pan, mask and End follow
the click-volume lifecycle exactly (a #1159 family: checkpoint plus session
capture plus recall replace); the prepared order and loaded id are captured
and recalled with the session only, like the pedal remap.

### D10 Engine lifetime

A **configure** (rate or cap change) frees every backing buffer with the
callback stopped (material, `le_engine_reset_material`); a **retained reopen**
at the same rate keeps the buffers but returns the transport to Stopped at 0
(runtime, `le_engine_reset_runtime`, `engine.c:500`); both bump
`backing_epoch`. The repository sees the epoch change, replays mask, level,
pan and End (as `LooperRepository` replays the click,
`looper_repository.dart:2540-2560`) and, after a configure, re-decodes the
loaded item (and the staged Next) at the new rate, stopped at 0, with the
notice "Backing stopped: the audio interface changed." (rule 3; pen 28 says
backing stops). A decode failure there leaves the item listed and unloaded
with its reason (rule 2).

## 4. Architecture

### 4.1 Native contract (`segno_engine_api.h`, Part 1 and Part 2)

```c
/* ---- backing player (#1200) ----
 * One engine-owned stereo voice played from RAM. It sums into its masked
 * output channels after the live monitors and BEFORE the output buses, like
 * the click: output FX, level, Mono and mute process it; master gain, the
 * limiter, output metering and the Record performance tap of the captured bus
 * see it. Never perf-logged: stems, the renderer's master and loop takes never
 * contain it. Buffers move by atomic pointer, never through the ring; freed
 * only on the control thread after the callback acknowledged them. */
#define LE_BACKING_MAX_SECONDS 900
typedef struct le_backing_buffer le_backing_buffer;
LE_EXPORT int32_t le_backing_buffer_from_pcm(const float* interleaved,
    int32_t frames, int32_t channels, int32_t sample_rate,
    le_backing_buffer** out);                          /* 1 or 2 channels */
LE_EXPORT int32_t le_backing_decode_file(const char* path, int32_t sample_rate,
    le_backing_buffer** out, int32_t* source_rate,
    int32_t* source_channels);                         /* Part 2; any thread but audio */
LE_EXPORT int32_t le_backing_buffer_frames(const le_backing_buffer* b);
LE_EXPORT int32_t le_backing_buffer_peaks(const le_backing_buffer* b,
    float* out, int32_t buckets);
LE_EXPORT void le_backing_buffer_free(le_backing_buffer* b);

typedef enum le_backing_transport { LE_BACKING_STOPPED = 0,
    LE_BACKING_PLAYING = 1, LE_BACKING_PAUSED = 2 } le_backing_transport;
typedef enum le_backing_end { LE_BACKING_END_STOP = 0,
    LE_BACKING_END_REPEAT = 1, LE_BACKING_END_NEXT = 2 } le_backing_end;
typedef enum le_backing_end_event { LE_BACKING_EV_NONE = 0,
    LE_BACKING_EV_STOPPED = 1, LE_BACKING_EV_REPEATED = 2,
    LE_BACKING_EV_ADVANCED = 3, LE_BACKING_EV_NEXT_MISSING = 4 } le_backing_end_event;

/* Takes ownership on LE_OK. `item` is the caller's token, reported back.
 * play=1 starts at frame 0 once installed. LE_ERR_INVALID: NULL, rate !=
 * engine rate, frames 0. LE_ERR_NOT_RUNNING: not configured.
 * LE_ERR_NOT_READY: a retired buffer still awaits its ack (retry after one
 * block). */
LE_EXPORT int32_t le_engine_backing_load(le_engine*, le_backing_buffer*,
                                         int32_t item, int32_t play);
LE_EXPORT int32_t le_engine_backing_stage_next(le_engine*,
                                   le_backing_buffer* /* NULL clears */, int32_t item);
LE_EXPORT int32_t le_engine_backing_clear(le_engine*);
LE_EXPORT int32_t le_engine_backing_transport(le_engine*, int32_t op);   /* ring */
LE_EXPORT int32_t le_engine_backing_seek(le_engine*, int32_t frame);     /* ring */
LE_EXPORT int32_t le_engine_backing_set_end(le_engine*, int32_t mode);   /* ring */
LE_EXPORT int32_t le_engine_backing_set_output(le_engine*, int32_t mask);/* ring */
LE_EXPORT int32_t le_engine_backing_set_level(le_engine*, float gain);   /* 0..LE_MAX_GAIN */
LE_EXPORT int32_t le_engine_backing_set_pan(le_engine*, float pan);      /* -1..1 */
LE_EXPORT int32_t le_engine_set_click_pan(le_engine*, float pan);        /* -1..1 */

typedef struct le_backing_state {
  uint32_t epoch;          /* bumps at configure and at every reopen */
  int32_t item, next_item; /* tokens; -1 none */
  int32_t transport;       /* le_backing_transport */
  int32_t position, frames;
  int32_t end_mode;        /* le_backing_end */
  uint32_t end_count;      /* bumps on every end-of-file handling */
  int32_t last_end;        /* le_backing_end_event of the latest */
  uint32_t mask; float level, pan, click_pan;
} le_backing_state;
/* Reads the state and frees every acknowledged retired buffer (the collect
 * point, like le_cache_collect). Control thread. */
LE_EXPORT int32_t le_engine_backing_state(le_engine*, le_backing_state* out);
```

Mechanics:

- **Slots.** `_Atomic(le_backing_buffer*) a_backing_cur` and `a_backing_next`
  with a generation each, an audio-thread `a_backing_ack` stored with release
  **after the block's last mixed frame** (the Library plan's review edit E4
  and `engine_private.h`'s note that a plain command ack lands before the
  block's frames finish), and two retired slots. A replace parks the old
  pointer; the control thread frees it once `a_backing_ack` reaches the
  retiring generation, or at once when `a_running == 0`
  (`engine_private.h:1452`). An automatic Next swap is done by the callback:
  it moves the finished buffer into the callback-owned `ended` slot, which the
  next `le_engine_backing_state` frees after the ack. Nothing allocates or
  frees on the audio thread.
- **One slot helper, shared with Library audition.** The publish/retire/ack
  logic lives in a new `src/core/engine_voice.h` (static inline, C atomics
  only, so it passes the C++ shim repro in `docs/PROGRESS.md`). If the Library's
  Part 6a lands first, Part 1 extracts its slot into this header and both
  voices use it; otherwise Part 6a builds on it (rule 4).
- **Commands.** Transport, seek, End and output mask go through the command
  ring so they apply at a block boundary in order; they take the next free
  `le_command_code` values at landing (the trunk ends at 83; Peel and Multiply
  may take more; never reuse a value, never collide). Level, pan and click pan
  are direct atomic stores read once per block, like click volume
  (`engine_process.c:6386-6391`). None is perf-logged. Raw ring posts of these
  codes are refused, as raw click-mode posts are.
- **Callback.** Per block: load the two pointers (acquire), mask
  `& out_enabled`, level, pan gains. Per frame after `click_frame`: if playing
  or ramping, read `(l, r)` at `pos` (dual mono for one channel), apply the
  5 ms linear ramp state (fade-out then the pending action: pause, stop,
  seek, switch; fade-in on resume and after a seek), multiply by level and the
  pan gains, `le_fx_route_frame` into the masked channels, advance. At
  `pos == frames`: Stop → stopped, `pos = 0`, `EV_STOPPED`; Repeat → `pos = 0`,
  `EV_REPEATED`; Next with a staged buffer → swap at this exact frame (the
  next frame is its frame 0), `EV_ADVANCED`; Next without → stopped, `pos = 0`,
  `EV_NEXT_MISSING`. Publish position, transport, item ids and the end event
  per block. `handle_cut_sound` sets Stopped, `pos = 0`, with no ramp.
- **Lifetimes.** `le_engine_reset_material` frees both slots and the retired
  ones (configure); `le_engine_reset_runtime` sets Stopped at 0, clears mask,
  level 1, pan 0, End Stop, click pan 0, and bumps `a_backing_epoch` (both
  paths). `le_engine_destroy` frees everything.
- **Decode (Part 2).** `le_backing_decode_file` opens with
  `ma_decoder_init_file` (output format f32, native channels and rate),
  refuses more than two channels and anything over `LE_BACKING_MAX_SECONDS`
  at the source rate (reading the length first where the format reports it,
  and stopping the read at the cap otherwise), reads in chunks into a
  growable buffer, converts through `le_resample_offline` when the rates
  differ, interleaves stereo, and computes nothing else. Errors:
  `LE_ERR_INVALID` (unreadable, unsupported, damaged, too many channels),
  `LE_ERR_TOO_LONG` (a new `le_result` value, the next free negative code at
  landing; the trunk ends at `LE_ERR_REVERSED = -9`, `segno_engine_api.h:39-52`),
  `LE_ERR_CAPACITY` for an allocation failure.

### 4.2 Dart ownership

| Concern | Owner | Notes |
|---|---|---|
| The FFI seam: decode in `Isolate.run`, load, stage, clear, transport, seek, End, mix, click pan, state | `BackingControl`, a new role interface in `packages/segno_engine/lib/src/audio_engine.dart` composed into `AudioEngine` (`:1513-1527`); `NativeAudioEngine`, `MockAudioEngine` | `BackingBuffer` (address, frames, peaks) with an explicit `free()`; `BackingState` model. |
| The asset store (`Backing tracks`: list, import with hash and validation, resolve, info) and the player (desired mix, loaded and staged items, epoch replay, decode lifecycle, failures) | new `packages/backing_repository` (REPO layer, VGV package) over `BackingControl` and a copy port (the #1177 `copyFile` shape) | Knows nothing about sessions, pedals or the prepared order's meaning beyond "the following item". |
| Prepared order, selection, Play semantics, Move up/down, Remove, Next staging, session capture/recall, New Loop stop | new `BackingPlayer` application owner, `lib/backing/application/backing_player.dart`, presented by `BackingCubit` | One selection, shared by the Prepared audio page and the foot surface (rule 4). |
| Backing level, pan, output mask and End; click pan | #1159 families `BackingMixFamily` and `ClickPanFamily` in `lib/looper/application/settings_families.dart`, owners in a `BackingSettings` beside `TempoSettings` | Same receipt, checkpoint and session-capture lifecycle as `ClickVolumeFamily` (`settings_families.dart:16-60`). |
| Foot Backing | `InteractionMode.backing`, `FootBackingProjection` role table, `FootBackingActions`, `control_foot_backing.dart` part of `ControlCubit` | The Fade precedent (`control_foot_fade.dart`). |
| Library integration | `LibraryCubit` (Library plan section 4.1) | Adds the `Backing tracks` group and the two actions; reads `BackingCubit`. |

## 5. Parts

Sizes are production lines (Dart or C, comments included), excluding tests,
generated bindings, l10n ARB files and docs. Dependencies: P1 → P2 → P3 → P4 →
P5 → {P6, P7, P8}; P8 → P9. P8 also needs Library Part 7, P9 also needs
#1177 Part 4, and P7's `Perform` button on 18/07 lands with whichever of P7
and P8 merges second. Every part leaves the app working, adds no control that does
nothing, and runs normal, ASAN and telemetry-off native suites where it
touches native code.

### Part 1: native backing voice and click pan (about 560 lines)

Files: `src/core/engine_voice.h` (new), `engine_private.h` (backing fields
beside the click block), `engine_core.h` if a helper must reach
`engine_commands.c`, `engine_commands.c` (the API), `engine_process.c`
(handlers, `backing_frame` after `click_frame` at `:6767`, `click_frame` via
`le_fx_route_frame`, `handle_cut_sound` `:2201`, block-end ack),
`engine.c` (`le_engine_reset_material` `:422`, `le_engine_reset_runtime`
`:500`, `le_engine_destroy` `:1209`), `segno_engine_api.h` (4.1 without
`le_backing_decode_file`; the stale click comments `:242-246` and `:2218-2226`
corrected), `lockfree_ring.h` only if a payload shape is missing, regenerated
and formatted bindings.

Tests (new `src/test/test_engine_backing.h`, included like
`test_engine_peel.h` at `test_engine_core.c:33548`; buffers from
`le_backing_buffer_from_pcm` with a literal ramp `x[k] = (k + 1) / 1024.0f` on
L and `x[k] / 2` on R, 48 kHz, so every expected sample is a closed form):

- `test_backing_play_literal`: load play=1, routed to channels 0-1, level 1,
  pan 0, nothing else sounding: output frame `f` equals `(x[f], x[f] / 2)` exactly
  for 4096 frames; channels 2-3 stay 0.
- `test_backing_level_pan_route`: level 0.5 halves every sample; pan 0.5 gives
  `gl = 0.70710677f` on L and 1 on R (the `le_pan_gains` value, asserted
  against the formula); mask `0b0001` writes the mid `0.75 · x[f]` to the lone
  channel per `le_fx_route_frame`; a structurally disabled output never
  carries it.
- `test_backing_pause_resume_stop_ramps`: pause at frame 1000 yields 240
  frames `x[1000 + i] · (1 - (i + 1) / 240)` then silence with position held;
  resume fades in over 240 frames from that position; Stop ramps out and
  rewinds to 0.
- `test_backing_seek_clamp_and_preserve`: seek while paused to 9000 then
  Play reads `x[9000]` first; seek past the end clamps to `frames - 1`; seek
  while playing ramps out, jumps, ramps in; seek with no buffer is refused.
- `test_backing_end_modes`: a 300-frame buffer; Stop → silence after frame
  299, transport Stopped, position 0, `EV_STOPPED`; Repeat → frame 300 equals
  `x[0]` with no ramp, `EV_REPEATED` each wrap; Next with a staged second
  buffer `y` → frame 300 equals `y[0]`, `item` becomes the staged token,
  `EV_ADVANCED`; Next without → Stopped at 0, `EV_NEXT_MISSING`.
- `test_backing_replace_while_playing`: playing A at frame 500, load B
  play=1: 240 frames of A ramping out, then `B[0]`; A is freed only after the
  ack (ASAN catches a premature free; a test hook asserts the pointer is not
  freed while the block that read it is open); a second replace before the ack
  returns `LE_ERR_NOT_READY`.
- `test_backing_independent_of_loops`: a recorded track plays; loop Stop,
  Clear and Undo leave the backing samples unchanged; Cut sound silences the
  backing on the next frame with no ramp and rewinds.
- `test_backing_capture_and_stems`: arm a performance on bus 0, track and
  backing both routed there, disarm, finalize, render: `master.pcm` equals
  track plus backing sample for sample; the track's stem equals the track
  alone; `events.log` contains no backing code. A take recorded while backing
  plays contains only its input.
- `test_backing_output_bus_processes_it`: output bus 0 level 0.5 halves the
  backing; bus mute silences it; master gain 0.5 halves it.
- `test_backing_lifetimes`: configure frees every buffer (ASAN leak check
  clean), bumps the epoch, state reads no item; a retained reopen keeps the
  buffer with frames intact, Stopped at 0, epoch bumped; destroy with
  current, staged, retired and ended buffers frees all four.
- `test_click_pan`: pan 0 is bit-identical to the existing click output on
  every masked channel (the existing click tests pass unchanged); pan -1
  leaves the right channel of the pair exactly 0.
- Shim: `docs/PROGRESS.md`'s C++ repro with `engine_voice.h` reachable from
  `engine_private.h`.

```success-criteria
GOAL: An independent, routed backing voice plays an engine-owned buffer sample-exactly with Play, Pause, Stop, seek and End = Stop/Repeat/Next, level, pan and an output mask, is processed by the output buses and captured on the captured bus, never reaches stems or loop takes, and the click gains pan.
SUCCESS CRITERIA:
- Literal-ramp oracles hold for play, level, pan, routing, ramps, seek, the three End modes, gapless Next, replace and Cut sound. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- Buffers are freed only on the control thread after the block-end ack; configure, reopen and destroy leak nothing; sanitizer and telemetry-off builds pass. | verify: EXTRA_CFLAGS="-fsanitize=address -g" bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS="-DLE_CALLBACK_TELEMETRY=0" bash packages/segno_engine/src/test/run_native_tests.sh
- master.pcm contains the routed backing; stems and events.log do not; existing click tests are unchanged at pan 0. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- Bindings are regenerated and formatted, symbol parity holds, and the C++ shim repro compiles. | verify: (cd packages/segno_engine && dart run ffigen --config ffigen.yaml && dart format lib/src/generated/segno_engine_bindings.dart && git diff --stat lib/src/generated) && packages/segno_engine/tool/check_ffi_symbols.sh "$(bash packages/segno_engine/tool/build_test_lib.sh)"
NON-GOALS:
- File decoding, resampling, Dart, UI, sessions.
VERIFICATION COMMAND: bash packages/segno_engine/src/test/run_native_tests.sh
```

### Part 2: decode and resample (about 330 lines)

Files: `src/miniaudio/miniaudio_impl.c:10` (drop `MA_NO_DECODING` only),
new `src/core/backing_decode.c` (`le_backing_decode_file`, `le_backing_buffer_peaks`),
`src/stretch/le_stretch.cpp` and `le_stretch.h` (`le_resample_offline`),
`segno_engine_api.h` (`le_backing_decode_file`, `LE_ERR_TOO_LONG`),
`src/CMakeLists.txt:60-135`, `run_native_tests.sh:70-105`,
`tool/build_test_lib.sh`, `macos/Classes/backing_decode.c` (forwarder like
`restore_halfband.c`), `Package.swift`, bindings. Fixtures under
`src/test/fixtures/backing/`: `sine1k_44k1_stereo.mp3` and
`sine1k_44k1_mono.flac` (each two seconds, generated once with ffmpeg/LAME
from a stated command recorded in the fixture README, a few tens of KB); WAV
fixtures are written by the test itself.

Tests (`test_engine_backing_decode.h`):

- `test_resample_identity`: equal rates copy bit-exactly.
- `test_resample_dc_and_tone`: DC 0.5 at 44.1→48, 48→44.1, 96→48 and
  44.1→96 reads `0.5 ± 5e-4` away from the edges; a 1 kHz sine of amplitude
  0.5 keeps `0.5 ± 0.0006` (±0.01 dB) by Goertzel at 1 kHz; every other
  Goertzel bin below 18 kHz is at least 90 dB below it; output length is
  `floor(in · out / in_rate)` exactly.
- `test_resample_192k_to_48k` takes the half-band path and meets the same
  bounds.
- `test_decode_wav_formats`: test-written 16-bit, 24-bit and float WAVs of a
  literal ramp at 48 kHz decode at 48 kHz to the exact ramp (16-bit to
  `k / 32768.0f`), mono to dual-mono.
- `test_decode_mp3_flac`: the fixtures decode at 48 kHz to two seconds
  ±1152 frames (the MP3 decoder delay bound), 1 kHz dominant by ≥ 60 dB.
- `test_decode_refusals`: a missing path, a truncated header, a text file
  renamed `.wav`, a 4-channel WAV (`LE_ERR_INVALID`), and a WAV whose header
  claims 901 s (`LE_ERR_TOO_LONG`, nothing allocated past the cap).
- `test_decode_peaks`: 512 buckets of a literal ramp equal the per-bucket max.

```success-criteria
GOAL: WAV, FLAC and MP3 files decode off the audio thread into stereo float buffers at the engine rate through a bandlimited windowed-sinc converter, and unusable files are refused with a typed reason.
SUCCESS CRITERIA:
- Identity is bit-exact; DC, 1 kHz amplitude, spurious-component floor and output length meet the literal bounds for 44.1, 48, 96 and 192 kHz sources. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- WAV variants decode to exact ramps; MP3 and FLAC fixtures decode within their bounds; refusals return the documented codes and allocate nothing past the cap. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- Sanitizer, telemetry-off, shim repro and symbol parity pass. | verify: EXTRA_CFLAGS="-fsanitize=address -g" bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS="-DLE_CALLBACK_TELEMETRY=0" bash packages/segno_engine/src/test/run_native_tests.sh && packages/segno_engine/tool/check_ffi_symbols.sh "$(bash packages/segno_engine/tool/build_test_lib.sh)"
- Appliance: a five-minute 44.1 kHz MP3 decodes at the device rate in under 3 s, and a 15-minute 96 kHz decode stays within 2 x 691 MB RSS growth. | verify: manual on the console with a timing log line around the decode and /proc/self/status VmRSS before and after. [HARDWARE]
NON-GOALS:
- Streaming, Ogg/AIFF/AAC, multichannel downmix, tempo or pitch change.
VERIFICATION COMMAND: bash packages/segno_engine/src/test/run_native_tests.sh
```

### Part 3: the Dart engine seam (about 420 lines)

Files: `packages/segno_engine/lib/src/audio_engine.dart` (`BackingControl`
role, composed into `AudioEngine`), `native_audio_engine.dart` (FFI calls;
`decodeBackingFile(path, sampleRate)` runs `Isolate.run` around
`SegnoEngineBindings(_openLibrary())` and returns a `BackingBuffer`; the
`notReady` retry once after one block period), `mock_audio_engine.dart`
(an in-memory voice with the same transport and End rules, counting frees),
new `backing_state.dart`, exports.

Tests: `packages/segno_engine/test` (mock: every transport and End rule, the
free count after replace and clear); `pumped_native_engine_test.dart`
against the built library (decode a test-written WAV, load, play, pump,
state position and `EV_ADVANCED`, the `notReady` retry, the decode refusal
codes as typed `BackingDecodeFailure` values).

```success-criteria
GOAL: Dart reaches the backing voice and decoder through one role interface, decoding off the UI isolate, with a faithful mock.
SUCCESS CRITERIA:
- The native seam decodes in a background isolate, loads, plays, stages, seeks, reports state and retries once on notReady through the real FFI. | verify: SEGNO_ENGINE_LIB=$(bash packages/segno_engine/tool/build_test_lib.sh) /Users/Tomas/development/flutter/bin/flutter test packages/segno_engine/test/pumped_native_engine_test.dart
- The mock obeys the same rules and every superseded buffer is freed exactly once. | verify: (cd packages/segno_engine && /Users/Tomas/development/flutter/bin/flutter test)
- Analyzer clean. | verify: dart analyze --fatal-infos packages/segno_engine
NON-GOALS:
- Repository, files, UI.
VERIFICATION COMMAND: (cd packages/segno_engine && /Users/Tomas/development/flutter/bin/flutter test) && dart analyze --fatal-infos packages/segno_engine
```

### Part 4: `backing_repository`: the asset store and the player (about 620 lines)

Files: new `packages/backing_repository` (Very Good package template:
`pubspec.yaml` with `crypto` as a direct dependency, `analysis_options.yaml`),
`lib/src/backing_asset_store.dart` (`list()`, `import(sourcePath, {name,
keepDecoded})`: streaming SHA-256 in `Isolate.run`, reuse on an existing id,
`copyFile` to `Backing tracks/<id>/<name>` through an injected `BackingCopier`
with the #1177 signature, decode-validate at the engine rate, `info.json`
written as `.part` then renamed, the directory removed on any refusal;
`resolve(id)`), `lib/src/backing_repository.dart` (desired mix and End,
`load(id, {play})`, `stageNext(id?)`, `clear()`, `play()`, `pause()`,
`stop()`, `seek(seconds)`, state polling at 20 Hz only while playing or
loading and on demand otherwise, epoch replay and post-configure re-decode
with the notice event, failure stream with typed reasons), models
(`BackingAsset`, `BackingPlayerState`, `BackingFailure`), `.github/workflows/main.yaml`
(the package's test job and a coverage floor of 95%), `.github/cspell.json`.

Tests (fake `BackingControl`, temp directories, a recording `BackingCopier`):
import hashes and copies once, a second import of the same bytes reuses the
id with no copy, a different file with the same name gets its own id; a
refused decode leaves no directory; `copyFile` failures (`full`, `io`) leave
no directory and report the failure; `list()` marks a missing or corrupt
`info.json` unavailable; `load` while playing keeps the old file until the
install; a failed decode leaves the old file loaded; `stop()` during a pending
load frees the result; a `Play selected` decode releases the staged Next first
and re-stages for the file that ends up loaded; epoch change replays mix and End and re-decodes the
loaded and staged items stopped; every decoded buffer the repository drops is
freed (the mock's count).

```success-criteria
GOAL: Backing files live as content-addressed managed internal copies, validated at import, and one repository drives the voice through loads, staging, transport, mix and engine restarts without leaking buffers.
SUCCESS CRITERIA:
- Import, dedupe, refusal cleanup, listing and resolve behave as specified on a temp root. | verify: (cd packages/backing_repository && /Users/Tomas/development/flutter/bin/flutter test --coverage)
- Replace, failed load, Stop during load, epoch replay and re-decode keep the old file or the stopped state as specified, and every dropped buffer is freed once. | verify: (cd packages/backing_repository && /Users/Tomas/development/flutter/bin/flutter test)
- Analyzer and the package coverage floor pass in CI. | verify: dart analyze --fatal-infos packages/backing_repository
NON-GOALS:
- Prepared order, sessions, UI, USB sources.
VERIFICATION COMMAND: (cd packages/backing_repository && /Users/Tomas/development/flutter/bin/flutter test --coverage) && dart analyze --fatal-infos packages/backing_repository
```

### Part 5: the application owner, mix families and the session (about 640 lines)

Files: new `lib/backing/application/backing_player.dart` (prepared order of
`(id, name)`, one selection, Play/Pause/Play-selected semantics, Move up/down,
Remove, Add to prepared without duplicates, Use as backing = prepare plus
load stopped and a confirm when another file is playing, automatic Next
staging of the following item while End is Next and the loaded item is in the
list, selection following on `EV_ADVANCED`, `EV_NEXT_MISSING` reported with
the following item's name and reason, New Loop and Open stop),
`lib/backing/cubit/backing_cubit.dart` and state,
`lib/looper/application/settings_families.dart` (`BackingMixFamily`:
level, pan, mask, End; `ClickPanFamily`), new
`lib/looper/application/backing_settings.dart` (owners, beside
`TempoSettings`), `packages/settings_repository` (checkpoint keys),
`packages/session_repository/lib/src/models/session.dart` (`SessionBacking`
{`prepared: [{id, name}]`, `loaded`, `endMode`, `level`, `pan`, `outputMask`}
and `clickPan`; the version after the last landed bump, 14 if Peel 12 and
Reverse 13 are the only ones ahead, plus its migration step into #1196's
chain defaulting an empty prepared list, nothing loaded, End Stop, level 1,
pan 0, mask 0 and click pan 0, recorded as defaulted fields),
`lib/session/session_mapping.dart` (`settingsFromLooper` `:103-170` and the
bundle mapper `:300-330`),
`lib/session/application/session_settings_coordinator.dart:61-96` (capture),
`lib/session/cubit/session_cubit.dart` (recall: apply the prepared setup,
reload the loaded item stopped; Open and New Loop stop the backing; if Library
Part 4 has landed, its D8 interruption predicate also asks while the backing
plays, and its D9 field-table test lists every new key with fate "kept"),
`lib/app/view/app.dart` and `lib/app/run_segno.dart` (wiring; the
`BackingCopier` adapter over the Library's `RemovableVolumes.copyFile`, or a
direct `File.copy`-into-`.part`-then-rename internal copier until that port
exists).

Tests: `test/backing/application/backing_player_test.dart` (Play toggles on
the loaded selection and loads a different one; Move up/down across a page
boundary keeps the selection; Remove keeps the playing file; Add twice keeps
one entry; automatic Next stages the following item only in Next mode,
follows the selection only when it was following, never wraps, reports a
missing following item; New Loop stops and keeps the list); family tests
beside the click-volume family tests; `packages/session_repository/test`
(round trip of the new block, the migration step from the previous version,
strict rejection of malformed ids, a missing `backing` key rejected at the
current version); `test/session/session_mapping_test.dart` (capture and
recall of every new field; a missing asset id survives a round trip and reads
`Missing`).

```success-criteria
GOAL: One owner holds the prepared order, selection and Play semantics; backing mix, End and click pan are #1159 families; the session saves and recalls the prepared setup by asset id, stopped, and the previous schema migrates.
SUCCESS CRITERIA:
- Play/Pause/Play-selected, Move, Remove, Add, Use as backing, automatic Next staging, selection following, no wrap and reported failures behave as specified. | verify: /Users/Tomas/development/flutter/bin/flutter test test/backing
- The new schema round-trips strictly; the previous version migrates with defaulted fields recorded; recall reloads the loaded item stopped and keeps missing ids as Missing. | verify: (cd packages/session_repository && /Users/Tomas/development/flutter/bin/flutter test) && /Users/Tomas/development/flutter/bin/flutter test test/session
- Analyzer and Bloc lint are clean. | verify: dart analyze --fatal-infos && bloc lint lib test packages
NON-GOALS:
- Screens, foot surface, routing UI, USB.
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos && bloc lint lib test packages
```

### Part 6: routing, the Mixer `Backing & click` dialog and the value targets (about 470 lines)

Files: `output_routing_tab.dart:326-336` (21/04: the `players` kind becomes
the pen's `Backing track` / `Click` choice; `_mask` `:123-124` and `_send`
`:138-139` gain the backing owner; the comment saying there is no seam goes),
new `lib/looper/view/backing_click_dialog.dart` (25 `bZDIR`: 1260 x 549,
`Backing` with subtitle, `Click` with its Hear click mode as subtitle, each
with `Volume` and `Pan` `LoopSlider`s (`loop_settings_widgets.dart:892`) on
the Mixer gain axis and the pan scale, double tap to unity and centre, `Done`),
`stage_top_bar.dart:62-64` (the `Backing & click` button beside Reset mixer,
Mixer view only), `control_value_target.dart` (`BackingLevelTarget`,
`BackingPanTarget`, `ClickPanTarget` as owned targets, parse and
`isStructurallyValid` arms), `lib/app/application/owned_value_port.dart`
(`:98`, `:142-144`, `:247-250` patterns for the three), picker labels, l10n
(English and Spanish).

Tests: `test/looper/view/audio_routing/output_routing_tab_test.dart`
(Backing track routes through the backing owner, Click unchanged);
`test/looper/view/backing_click_dialog_test.dart` (four sliders, double tap
resets, a drag commits one value, the backing subtitle reads the loaded name);
`stage_top_bar_test.dart` (button only in Mixer); `control_value_target_test.dart`
(canonical strings round-trip byte-exact; malformed ones parse to null);
owned-value-port tests driving each target from a MIDI CC fake.

```success-criteria
GOAL: Backing has its own routing in Audio routing, the Mixer opens the shared Backing & click level and pan dialog, and backing level/pan and click pan are assignable value targets.
SUCCESS CRITERIA:
- 21/04 and 25 render to their pen geometry and drive the owners; the click route is unchanged. | verify: /Users/Tomas/development/flutter/bin/flutter test test/looper
- The three targets serialize byte-stably, refuse malformed keys and move the live values through the shared port. | verify: /Users/Tomas/development/flutter/bin/flutter test test/control test/app
- Analyzer and Bloc lint are clean. | verify: dart analyze --fatal-infos && bloc lint lib test packages
- Appliance: backing routed to Monitor only is heard on outputs 3-4 and not 1-2; Pan hard left silences the right jack; Output FX on Main process it. | verify: manual on the console with headphones on each pair. [HARDWARE]
NON-GOALS:
- Library pages, foot surface.
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos && bloc lint lib test packages
```

### Part 7: foot Backing and the catalogue actions (about 640 lines)

Files: `interaction_mode.dart` (`backing`, not a boot default),
new `lib/control/model/foot_backing.dart` (the role table: Record/Play →
Play / Play selected / Pause; Stop → Stop; Undo → Previous, hold −10 s;
Mode → Exit; Track 1-4 → select the page's item; Clear → Next, hold +10 s;
Bank → page, hold cycles At end Stop → Repeat → Next), new
`lib/control/foot_backing_actions.dart` (stateless over `BackingPlayer`),
new `lib/control/cubit/control_foot_backing.dart` (the Fade gesture
pattern: immediate Play and Stop, `_armGesture` for the three press/hold
pairs, Exit always available), `control_cubit.dart` (mode routing at the
existing per-mode switches `:1274`, `:1309`, `:1449`, `:1580`, `:1722`,
`:1788`, `:2350`), `control_projection.dart:97`, `:204` and
`invariants.dart:158` (wire mode `custom`; LEDs: Record/Play lit while
playing, the track pedal of the playing item lit, Mode lit as the way out),
`control_action.dart` (`ModeAction(backing)` under functions; `BackingAction`
entries `backing:play`, `backing:stop`, `backing:previous`, `backing:next`,
`backing:rewind`, `backing:forward`, `backing:end`, `backing:page` under
`ControlActionGroup.backing`, with `tryParse` arms; the group doc's "Empty
until" line goes), `control_action_labels.dart`, new
`lib/looper/view/foot_backing_view.dart` (18/08-18/11: status, name,
position bar as the seek slider, `At end` segment, `Prepared audio · N
recordings` or `Selected · press Play`, the shared pedal contact widget
`performance_pedal.dart`), `tracks_view.dart` composition, the `Perform`
button on 18/07 (with whichever of Parts 7 and 8 merges second; until then the mode is reached through
`ModeAction(backing)` from Custom and MIDI), l10n.

Tests: `test/control/cubit/control_foot_backing_test.dart` (each role;
holds consume the press; Previous/Next cross pages; Bank pages
independently of the track bank; Exit keeps playback; refused actions on an
empty list; LEDs), `test/control/binding/control_action_test.dart` (the eight
keys round-trip, the group is no longer empty, picker order),
`test/looper/view/foot_backing_view_test.dart` (the four pen states,
`Play selected` when selection differs), one fuzz seed in `test/fuzz/` for
the new mode.

```success-criteria
GOAL: The Backing performance function is operable and escapable by foot on the ten-pedal map, its actions are assignable from the shared catalogue, and Exit preserves playback.
SUCCESS CRITERIA:
- Every pedal role, hold, page and Exit behaves as 18/08-18/11 and the study specify, through the real ControlCubit. | verify: /Users/Tomas/development/flutter/bin/flutter test test/control test/looper/view/foot_backing_view_test.dart
- The eight backing actions and the mode action are in the catalogue with stable keys. | verify: /Users/Tomas/development/flutter/bin/flutter test test/control/binding
- The control fuzzer, analyzer and Bloc lint pass. | verify: /Users/Tomas/development/flutter/bin/flutter test test/fuzz && dart analyze --fatal-infos && bloc lint lib test packages
- Appliance: enter Backing from a Custom pedal, page, select, Play selected, hold Next, cycle At end, Exit with playback continuing; LEDs match. | verify: manual on the console with the built-in pedals. [HARDWARE]
NON-GOALS:
- Library pages, USB.
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos && bloc lint lib test packages
```

### Part 8: Library > Audio: `Backing tracks`, Prepared audio and the Backing track page (about 650 lines)

Needs Library Part 7 (`library_audio_tab.dart`). Files:
`lib/library/view/library_audio_tab.dart` (the `Backing tracks` group of
18/01 from `BackingAssetStore.list()`, unavailable assets with `—`; the
sub-nav row's `Prepared audio` entry, the Library plan's deviation 3 lifted
for this entry only; preview actions `Add to prepared` and `Use as backing`
for Backing tracks, Performances (`master.wav`) and session mixdowns, each
importing into the store first with inline progress), new
`lib/library/view/prepared_audio_page.dart` (18/07: numbered rows, `Move up`
/ `Move down` beside `Performance order` with the encoder rules of the
library study, preview with `Remove from prepared` and `Use as backing`,
`Perform` once Part 7 has landed), new
`lib/library/view/backing_track_page.dart` (18/05: `Choose audio` returns to
the Audio tab, `Clear backing` with its confirm, kind and duration, the
waveform from `info.json` peaks as the seek slider with the D4 touch,
encoder and double-tap rules, Level and Pan with `−` `+` `Unity`/`Center`,
`Stop`, `Play`), `library_cubit.dart` (navigation and import progress),
l10n. `Preview` on backing items reuses the Library audition voice (its Part
6a) fed by `decodeBackingFile` truncated to the audition cap; without Part
6a the `Preview` control is not drawn. `Export to USB` and `Use in loop` are
not drawn here (E7-13 and E7-9).

Tests: `test/library/view/library_audio_tab_test.dart` (the group, the two
actions, progress, a refused import's reason), `prepared_audio_page_test.dart`
(numbering, moves across the four-row page boundary, selection kept, Remove),
`backing_track_page_test.dart` (seek touch and encoder draft/commit/cancel,
double tap, Clear confirm and cancel, Level/Pan steps and resets, Stop and
Play states, `No audio loaded`).

```success-criteria
GOAL: Audio can be prepared and loaded as backing from the Library, ordered for performance, and played, positioned, mixed and cleared on the Backing track page.
SUCCESS CRITERIA:
- 18/01 Backing tracks, 18/05 and 18/07 render to their pen geometry and act through BackingPlayer. | verify: /Users/Tomas/development/flutter/bin/flutter test test/library
- Seek, Clear, Level and Pan follow the touch, encoder and double-tap rules; a refused import shows its reason and adds nothing. | verify: /Users/Tomas/development/flutter/bin/flutter test test/library
- Root coverage floor, analyzer and Bloc lint hold. | verify: /Users/Tomas/development/flutter/bin/flutter test --coverage && dart analyze --fatal-infos && bloc lint lib test packages
- Appliance: prepare three files, reorder, play through with At end Next and hear gapless joins; Repeat loops with no gap. | verify: manual on the console, listening at each join. [HARDWARE]
NON-GOALS:
- USB sources, Export to USB, Use in loop, audio delete.
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos && bloc lint lib test packages
```

### Part 9: USB sources with a read hold (about 380 lines)

Needs #1177 Part 4 behind the Library port. Files:
`packages/storage_repository/lib/src/storage_repository.dart` (`withReadHold`
per D8, beside `withWriteLease` `:192-207`), the Library port
`lib/library/application/removable_volumes.dart` (same method;
`InternalOnlyVolumes` throws `unsupported`), `library_audio_tab.dart`
(18/02: the drive's folders and audio files by extension, `—` for a file
that fails a header probe, the "Copies to Internal" caption; 18/06 when no
drive), `backing_asset_store.dart` (import from a removable source runs
inside the read hold and aborts on `lost`), progress, `Cancel` and the
interruption copy "USB drive disconnected. Nothing was changed." with
`Retry`, l10n.

Tests: `packages/storage_repository/test` (a read hold refuses eject naming
its purpose, is granted on a read-only drive, is refused on an absent or
ejecting one, completes `lost` on removal); `test/library` (listing, a
pulled drive mid-copy leaves the store unchanged, Retry completes, the
imported asset plays after the drive is gone).

```success-criteria
GOAL: Audio on a USB drive becomes a managed internal backing copy, the drive cannot be ejected mid-copy, a pulled drive changes nothing, and playback never depends on the drive.
SUCCESS CRITERIA:
- The read hold refuses eject with its purpose, accepts read-only drives and reports loss. | verify: (cd packages/storage_repository && /Users/Tomas/development/flutter/bin/flutter test)
- 18/02 and 18/06 render; an interrupted copy leaves no asset and Retry completes. | verify: /Users/Tomas/development/flutter/bin/flutter test test/library
- Analyzer and Bloc lint are clean. | verify: dart analyze --fatal-infos && bloc lint lib test packages
- Appliance: copy an MP3 from FAT32 and exFAT drives, try Eject mid-copy (refused, names the copy), pull the drive mid-copy (nothing added), then copy, eject, and play the backing. | verify: manual on the console with two drives. [HARDWARE]
NON-GOALS:
- Export to USB, Use in loop, folder creation on the drive.
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && (cd packages/storage_repository && /Users/Tomas/development/flutter/bin/flutter test) && dart analyze --fatal-infos && bloc lint lib test packages
```

## 6. Scope against the inventory

| Item | Where |
|---|---|
| E7-8 backing player | Parts 1-5, 8 |
| E6-8 foot Backing | Part 7 |
| E3-3 Mixer Backing & click (both halves, including click pan) | Parts 1 (click pan), 5 (family), 6 |
| E5-6 Backing in Audio routing | Part 6 |
| E6-12 backing level/pan, click level/pan targets | Part 6 (click volume already exists) |
| E7-7 Audio library: `Backing tracks`, `Add to prepared`, `Use as backing`, managed internal copy, USB source | Parts 4, 8, 9 (no issue exists for E7-7; this plan takes the backing half, rule 4) |
| E7-7 remainder: `Use in loop` (E7-9), `Export to USB` of backing assets (E7-13), audio delete | not here |
| E7-6 recall ownership for prepared backing | D9, Part 5 |

## 7. Hardware-only evidence

Decode time and memory on the Pi 5 (Part 2), audible routing, pan and output
FX on real jacks (Part 6), footswitch roles, holds and LEDs (Part 7),
gapless Next and Repeat by ear (Part 8), FAT32/exFAT copies with eject and
pull (Part 9), and a Record performance with backing routed to Main: the
master contains it and the stems do not (also proven natively in Part 1).
Display keep-awake during backing playback (AB 7.6) has no owner yet; when
the idle-dimming owner lands it must read `BackingPlayerState.playing`.

## 8. Findings outside this plan (no product-direction question identified)

- `segno_engine_api.h:242-246` and `:2218-2226` still say the click bypasses
  master gain and never appears in captures; slice 3b changed both
  (`engine_process.c:4296-4302`). Part 1 corrects them because its own
  contract sits beside them.
- The Library plan's D8 playback predicate and D9 field-table test predate the
  backing; Part 5 extends both if those parts landed first, otherwise the
  Library parts must include the backing fields when they land.
- The Library plan's Part 6b decodes WAV in Dart and refuses a rate mismatch;
  `decodeBackingFile` (Part 3) decodes WAV, FLAC and MP3 at any rate, so that
  part can adopt it instead of a second decoder (rule 4).
- A session backup to USB (Library Part 8) carries no backing files; restoring
  it on another appliance shows `Missing` rows until the complete appliance
  backup (E7-15) carries `Backing tracks`. That follows AB 6.8's split and is
  recorded, not changed.

## 9. Defaults taken under the owner rules

- 15-minute file cap and at most two resident buffers (D1; rule 2, bounded
  memory, refusal with a reason rather than truncation).
- More than two channels refused rather than downmixed (rule 3).
- Stop during a pending `Play selected` cancels it (rule 2: the last press
  wins and leaves a known state).
- Cut sound stops the backing without a ramp (AB 3.6) and rewinds (the
  catalogue label).
- A retained reopen stops and rewinds the backing; a configure re-decodes it
  stopped, with a notice (rules 2, 3; pen 28).
- Missing assets stay listed as `Missing` (rule 5's notice, rule 2's
  recovery path; never matched by name).

## 10. Budget and review ceiling

Estimates: 560, 330, 420, 620, 640, 470, 640, 650, 380 production lines.
Stop for review on any change to the output-bus order, a perf-log code, a
second decoder, a second lease registry or a second selection owner. Each
part gets independent architecture, test-quality and adversarial review
before publication; CI on the published head, `/code-review` and the human
merge gate remain separate.
