# Backing player: prepared list, transport, routing, foot Backing and the Mixer strip

<!-- cspell:ignore subformat ADPCM RIFX fseek isfinite finalizer Finalizer -->

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

Status: reviewed 2026-10-06 (PR #1207, "request changes": H1, M1-M5, L1-L8).
Every finding is applied in this text; section 14 maps each to where. Parts 1
and 2 are built (PRs #1222, #1223; section 12 records how the build departed
from the first text). Rebased on `origin/claude/segno-integration` at
`097e1ef68`, which carries #1198 Part 1 (`le_digest_file`,
`le_fs_sync_dir`).

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

**Deviations the build must write back into the pen** (repo rule: a shipped
departure updates the pen; this plan does not edit it):

1. The Mixer dialog subtitle for Backing shows the loaded file's name when one
   is loaded and `Prepared audio` otherwise (the pen draws only the latter).
2. 18/07 `EM37x` draws `Save audio` (top right), `Export to USB` and
   `Use in loop`; 18/01 `bx7vK` draws `Export to USB` and `Use in loop`. Part 8
   omits all of them until their features exist (`Save audio` is E7-10,
   `Use in loop` is E7-9, `Export to USB` of a backing asset is E7-13), so no
   control does nothing. Each is drawn by the part that builds its feature.
3. The pen gives 18/05 `Backing track / Ready` no entry point. Part 8 reaches
   it two ways: `Use as backing` opens it (the file now loaded), and the
   Prepared audio page (18/07) gets a `Backing track` button beside `Perform`
   when a file is loaded. Both are new controls the pen must draw.
4. `Play selected` shows `Loading <name>…` in the status line of 18/05 and
   18/08-18/09 while it decodes (review L4); the pen draws no loading state.

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
   (15 minutes: 346 MB at 48 kHz, 691 MB at 96 kHz per buffer). The engine
   enforces the backing's share: at most `LE_BACKING_BUDGET_BYTES` (1.5 GiB)
   of PCM and four buffers owned at once (Part 1, as built). In the owner's
   flows at most two full buffers are resident: the loaded one plus either
   the staged Next or a pending `Play selected` decode, never both, because
   starting a `Play selected` decode first releases the staged Next (it
   belongs to the outgoing file and is re-staged for whichever file ends up
   loaded). Import never holds a third: it probes, retaining no PCM (D2).
   A decode's own peak (the source it reads, the planes a halving works on,
   and its output) is checked against `MemAvailable` before it allocates
   (D11). A file over the cap is refused
   at import with the reason, never truncated.

Selection does not pre-decode: `Play selected` decodes on demand while the
current file keeps playing, then switches (AB 6.4 "Selecting a different
backing file leaves the current one playing until Play"; the library study's
"The old file stays loaded until the new load or copy succeeds"). Only an
`At end: Next` decodes ahead, because gapless continuation needs it.

### D2 Decode path: the app's one decoder, native, in a Dart background isolate

- **One reader of audio samples for the app (review M3(a), rule 4).**
  `le_backing_decode_file` (Part 2, `src/core/engine_decode.c`), natively and
  bounded, is the only code that turns a file's bytes into samples for the
  app: the backing player, the Library preview (its Part 6b) and #1198's
  recording recovery all decode through it. `wav_codec` stays the app's WAV
  writer and its header and part model (RIFF headers, part metadata,
  `.part` bookkeeping); it never decodes samples for playback, preview or
  recovery. The bounded form takes a start frame (source rate) and a maximum
  output length, says whether it stopped early, and returns exactly the
  whole-file decode's samples at the same positions; at the engine rate that
  is the file's own samples. What the other two plans must accept: the
  output is stereo (a mono part reads back as two equal sides), at the
  engine rate, from mono or stereo WAV PCM 16/24/32 or float32 at 8-192 kHz
  (a recording part at the device rate is read back unchanged).
  `le_backing_probe_file` decodes a whole file in 4096-frame chunks, keeping
  no PCM, to validate it and compute peaks. The coordinator routes this
  wording to the #1198 plan and the Library plan's Part 6b.
- **Formats (review of #1223, M1):** a whitelist, checked by the decoder's
  own header parse before any miniaudio decoder sees the file: WAV (RIFF)
  with 16/24/32-bit PCM or 32-bit float, plain or EXTENSIBLE with the PCM or
  float subformat, and MPEG Layer III (MP3), through miniaudio's dr_wav and
  dr_mp3 (`MA_NO_DECODING` removed, `MA_DR_MP3_ONLY_MP3` set). Refused as
  unsupported, before decoding: 8-bit and 64-bit WAV, ADPCM, mu-law and
  A-law, RIFX, RF64, BW64, Wave64, AIFF, Ogg, MPEG Layer I/II, and FLAC,
  which stays compiled out (`MA_NO_FLAC`) because CVE-2024-41147, an
  out-of-bounds write in `ma_dr_flac__decode_samples__lpc`, affects the
  vendored 0.11.21 (#1235 updates miniaudio and re-enables it). The pen
  shows only `.wav` and `.mp3` (18/02). Mono plays dual mono; more than two
  channels is refused ("Only mono and stereo files can be used."), never
  downmixed. Anything refused is listed with `—` and its reason (18/02's
  damaged row): unsupported for a format outside the list, damaged for a
  file that claims a listed format and is inconsistent.
- **Where:** `Isolate.run` in Dart, with the library opened by the existing
  top-level `_openLibrary()` (`native_audio_engine.dart:39-48`). The UI
  isolate never decodes and no native thread is added. The returned
  `le_backing_buffer*` crosses the isolate boundary as an address; ownership
  passes to the engine on a successful `load`/`stage_next`, and every other
  path frees it.
- **Import validates by streaming.** Import probes the copied file (whole
  decode, no PCM retained, 512 peaks and the decoded length into `info.json`)
  and keeps it only if that succeeds. The probe refuses a source rate the
  converter cannot reach from every engine rate (44.1, 48, 88.2 and 96 kHz;
  review of #1223, L1), so a file that imports decodes at whatever rate the
  interface runs, and a performance never meets a file that has not decoded
  cleanly once. Import never holds a full buffer.

### D2a Untrusted files (review M2; review of #1223, H1-H3, M1)

The decoders parse whatever a performer brings on a drive, inside the app's
process, so no input may crash, hang or poison audio (rule 2). The first
build left that to miniaudio's own checks, and a wider fuzzer found, within
minutes, a process abort (a WAV with 255 or 256 channels: miniaudio freed a
stack address after its post-init failed), endless seeks (a `fact` chunk
under 4 bytes, a Wave64 chunk size), an out-of-bounds table read (MS-ADPCM)
and non-finite float samples that silenced a bus with a reverb for good. As
built after that review:

- **Our own header parse first.** Before any miniaudio call the decoder reads
  the file itself: a RIFF/WAVE whose chunks up to `data` each fit inside the
  file, exactly one `fmt ` of a listed format (D2), 1-2 channels, a block
  align that matches, a `fact` chunk of at least 4 bytes; or ID3v2 tags
  followed, within 64 KiB, by a Layer III frame header and a consistent
  second one. Everything else is refused before a decoder sees it. A
  trailing ID3v1 tag is cut from the stream (a short tagged MP3 was refused
  otherwise; review L4).
- **Exactly one backend, through bounded I/O.** miniaudio is opened with the
  format named (no fallback across decoders) and our read and seek
  callbacks: a seek outside the file fails (where `fseek` past the end
  succeeds on a regular file, which is what let a crafted size loop), and
  every read and seek counts against a work budget of eight passes over the
  file plus 64 MiB, after which every call fails. A non-regular path (a
  FIFO, a device) is refused before it is opened.
- **Values in range.** The source rate must be 8-192 kHz and reachable by the
  converter from every engine rate; the channels 1-2; the stated length
  must fit what the file could hold (at most 512 decoded float bytes per file
  byte); the 15-minute cap applies to decoded frames as well; a whole-file
  decode that yields another length than the file states is damaged.
- **Finite, bounded samples only (H3).** The probe and every decode refuse
  a NaN or Inf sample, and any sample beyond 1024 (60 dB over full scale:
  the widened fuzzer found finite values near `FLT_MAX` that the converter
  summed to Inf), as damaged, and `le_backing_buffer_from_pcm` refuses one too,
  so nothing non-finite reaches the voice. (A guard on the output buses
  themselves, for any source, is proposed in section 8.)
- **Compiled out:** FLAC, MPEG Layer I/II, the WAV metadata parser (never
  requested, so CVE-2026-32837, the BEXT parser, is unreachable). miniaudio's
  post-init double uninit is patched (`SEGNO PATCH`, recorded in its README)
  as defense in depth, though the app no longer reaches it.
- **Fuzzing.** `src/test/fuzz_backing_decode.c` mutates whole files (bit and
  byte edits anywhere, extreme 16- and 32-bit values, chunk sizes after
  anything that looks like a chunk id, repeated spans, splices from other
  seeds, runs of 0x00 or 0xFF, truncation) over seeds of every accepted and
  refused format and container plus every fixture and reproducer, with a
  10 s watchdog per input, and keeps any violating input for replay. It
  runs in every native configuration, and the ASan CI job builds it with
  UBSan too and runs 20,000 inputs. Section 12 records the local campaign.

**Residual risk, recorded.** A decoder fault would still end the app, and
with it the audio. A child process would contain it, but forking from the app
is exactly what #710's root cause was: `Process.run` forks copy the page
tables under the RT audio thread's lock and produce audible clicks
(`loopy-click-root-cause-fork-cow`), so a decode helper would need a separate
long-lived process started at boot, which the appliance image does not have.
Decoding happens at import, before a performance, and later decodes read only
managed copies that already passed and whose digest is verified first (D7).
#1235 updates the vendored miniaudio (re-applying every `SEGNO PATCH`),
re-enables FLAC, and must re-check the three upstream defects the whitelist
works around (section 8) and re-run the fuzzer after the update.

### D3 Sample-rate conversion: an offline polyphase windowed sinc

The pitch/time plan's resampling is the wrong tool here, checked piece by
piece: its read head is a two-tap fractional read for real-time varispeed
(D1 there), whose imaging and aliasing are acceptable for a performance effect
but not for a whole file converted once; `le_stretch_render_offline` is a
phase vocoder that would smear transients for a ratio near 1; the half-band
pair converts 2:1 only. The vendored Signalsmith `InterpolatorKaiserSincN`
was the first choice and was measured in Part 2: it forces exact zeros at
integer offsets, which is only right when its cutoff is the input Nyquist, so
built for any reduction its DC gain is 1 at phase 0 and 1.09 to 2.0 elsewhere
(48 to 44.1 kHz: 4 % DC ripple, -43 dB residual). miniaudio's own resampler
is linear interpolation behind a low-order filter.

So `le_resample_offline` (`src/core/engine_decode.c`, internal, not FFI) is a
polyphase Kaiser-windowed sinc (beta 10.06, about 100 dB stop band for this
stage) of
half-width `ceil(32 / r)` input samples, `r = min(1, out / in)`, with exact
rational phases (`out / gcd(in, out)`, refused above 8192) each normalized to
unity DC gain. Its transition is 0.45 r to 0.55 r of the input rate, so
aliases fold only above `0.45 · out_rate`. Reductions below one half first
halve through `le_halfband_decimate`, whose stop band is -78 dB, so content
folding through a halving (a 192 kHz source on a 48 kHz engine) is
attenuated by about 78 dB, not 100. A source rate the phase bound refuses
from any engine rate is refused at import (D2). Equal rates copy exactly. It reads and
writes strided channels, so a decode converts straight from the interleaved
source into the interleaved output. Measured: a five-minute 44.1 kHz MP3
decodes and converts in 0.58 s at 48 kHz and 1.01 s at 96 kHz on the dev
machine; the Pi 5 figure is a hardware criterion of Part 2.

### D4 Transport, seek and End semantics (accepted 6.4, section 4's Backing row)

- **Play** loads the selection, or toggles Pause when the selection is the
  loaded file. Loading a new selection while another plays keeps the old one
  audible until the new buffer is installed, then switches at a block
  boundary with a 5 ms fade-out of the old file (`LE_BACKING_RAMP_MS 5`); the
  new file starts at frame 0 unfaded; since Part 1 as built, the old file's
  fade-out overlaps the new file's start. While the decode runs the status
  line reads `Loading <name>…` (deviation 4). A failed decode leaves the old
  file loaded and playing and reports the reason.
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
performance and the player never holds a removable volume.

- **Identity (review M3, rule 4):** the full SHA-256 of the file's bytes, as
  `sha256:<64 hex>`, computed with #1198's `le_digest_file(path, 0,
  UINT64_MAX, out)` (#1198 Part 1, on the trunk; one SHA-256
  implementation in the app, not Dart `crypto`). It is stored in `info.json` and in the session's prepared
  list, and verified before every load (a mismatch is `Damaged`, never
  played). The directory name is the first 16 hex digits, for short paths
  only; a directory whose `info.json` names a different digest is ignored.
- **Layout:** `<exportsRoot>/Backing tracks/<16 hex>/<original file name>`
  plus `info.json` (`digest`, `name`, `sourceRate`, `sourceChannels`,
  `sourceFrames`, 512 `peaks`). It stays under `exportsRoot` (review L6
  considered a sibling root) because #1177's `copyFile` writes Internal copies
  relative to that root, and reusing its `.part`, fsync and rename protocol
  is the rule-4 call. Boot salvage and the Library's `listCaptures` already
  skip directories without `performance.json`; Part 4 adds a test that a
  `Backing tracks` directory is never listed as a capture.
- **Dedupe:** importing identical bytes again reuses the existing copy (the
  study's "reuses its copy") only while that copy's own bytes still match
  its digest; a damaged copy is replaced from the source, so adding the
  original again, or #1198's "Find audio", repairs it (review of P4, M1).
  Imports of the same bytes run one after the other (L4). Two files with
  the same name and different bytes coexist. A failed copy, a refused probe or a full disk leaves nothing
  behind. A USB source is held for the copy's duration by a read hold (D8).
- **Delete:** there is no Delete for audio in the accepted design, so no
  reference check is needed yet (Library D6's note); when E7-7 adds one, it
  must check every saved session's prepared digests.

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
`Missing` row that cannot be loaded and says so; it is never dropped silently
and never matched by name. **The repair row is #1198's (review M5):** pen 36
(`b28GI1` `2 audio files to find`, `w9WB8`, `sra8u`, `LaqVi`) draws
`Evening lights.wav · Prepared audio · Backing track · Find audio` in Open
recovery; #1198's Part 14 inspects prepared backing references as
`missingBacking` items and its Part 15 draws the row, accepting a candidate
only by this plan's identity (the full digest of D7). This plan supplies the
identity and the session field (Part 5); it builds no repair UI. Level, pan, mask and End follow
the click-volume lifecycle exactly (a #1159 family: checkpoint plus session
capture plus recall replace); the prepared order and loaded id are captured
and recalled with the session only, like the pedal remap.

### D10 Engine lifetime

A **configure** (rate or cap change) frees every backing buffer with the
callback stopped (material, `le_engine_reset_material`); a **retained reopen**
at the same rate keeps the buffers but returns the transport to Stopped at 0
(runtime, `le_engine_reset_runtime`); both bump `backing_epoch`. The backing
settings (mask, level, pan, End, click pan) persist across both (Part 1 as
built). The repository sees the epoch change and:

- after a configure, re-decodes the loaded item (and the staged Next) at the
  new rate, stopped at 0;
- after either, if the backing was playing, shows "Backing stopped: the audio
  interface changed." (rule 3; review L2: a retained reopen also stops it);
- frees a decode that finishes after the rate changed (its `load` reads
  `LE_ERR_INVALID` for the stale rate) and decodes again at the new rate
  (review L3);
- leaves an item that fails to decode listed and unloaded with its reason
  (rule 2).

The repository sees the restart when the engine restarts, not at the next
press: a restart moves the looper's lifetime, the backing mix owner retires
its held value by re-applying the durable mix through the repository, and
each of those setters refreshes it. A Play pressed before any refresh handles
the restart first and waits for the reload instead of being spent on it. The
player follows whichever file the repository holds, and no state during the
reload reads as "nothing loaded" (review of P5, M1).

### D11 The appliance memory budget (review M1)

Pi 5, 8 GB, no swap (nothing in `deploy/yocto` configures one), one process
for the UI and the engine. The budget names every large consumer, its bound
and who enforces it. Figures at 96 kHz.

| Consumer | Bound | Enforced by |
|---|---|---|
| OS, compositor, Flutter app baseline | about 1.2 GB (to measure) | hardware criterion of Part 2 |
| Floor kept free for everything else | 512 MiB of `MemAvailable` | `LE_MEM_RESERVE_BYTES`: every decode checks its own peak against it before allocating (Part 2) |
| Backing buffers (loaded + staged + one in transit) | 1.5 GiB of PCM | `LE_BACKING_BUDGET_BYTES` in the engine's registry (Part 1); loads past it are refused |
| One decode in flight (source + halving planes + output) | up to 2.1 GB: 15 min of a 192 kHz stereo source on a 96 kHz engine reads 1.38 GB of source and writes 0.69 GB of output (review of #1223, M2). A 44.1 kHz source needs 1.0 GB; on a 48 kHz engine a 192 kHz source halves through planes it is read straight into, peaking at 1.73 GB | allocated once, from the stated length, after the floor check, which counts every term |
| Import | 32 KiB of decode scratch | the probe keeps no PCM (Part 2) |
| Library preview (audition voice) | 120 s: 92 MB, plus a bounded decode of the same size | the bounded decode (`max_frames`) and the floor check |
| Recording capture rings (#1198) | up to 264 MiB | #1198's ring sizing |
| Loop-stage wet cache | 192 MiB (pitch/time Part 3a's cap) | `LE_CACHE_DEFAULT_CAP_BYTES` |
| Loops (lanes x undo layers) | grows with use: one buffer is `max_loop_frames` x 4 B (11.5 MB at the 30 s default) | not bounded today; see section 8 |
| Instruments (#1197) | not stated by #1197 | #1197 must take a share of this table |

The floor check is the backstop: whatever loops and instruments have taken, a
decode never starts that would leave less than 512 MiB available, and says
"Not enough memory to load this file." The worst `Play selected` therefore
needs about 2.8 GB above the floor (a loaded 96 kHz buffer plus that decode);
source rates are capped at 192 kHz to keep it there (384 kHz would double
the source term). If the hardware criterion below fails, a streaming
converter (decode in chunks into the output, the source never whole) is the
next step. Hardware criterion (Part 2): peak RSS
while A plays, B is staged and C is imported, all at 96 kHz, with eight
tracks recorded, stays under 6.5 GB, and no xrun is logged while a 96 kHz
decode runs with loops playing (review L4).

## 4. Architecture

### 4.1 Native contract, as built (`segno_engine_api.h`, Parts 1 and 2)

The header is the reference (`#1200` blocks beside the click). In outline:

```c
#define LE_BACKING_MAX_BUFFERS 4
#define LE_BACKING_BUDGET_BYTES (1536ll * 1024 * 1024)
#define LE_BACKING_RAMP_MS 5
typedef struct le_backing_buffer le_backing_buffer;  /* interleaved stereo f32 */
le_backing_buffer_from_pcm(pcm, frames, channels, rate, &out);
le_backing_buffer_frames / _rate / _peaks / _pcm / _free;
le_engine_backing_load(e, buf, item, play);          /* ring: LE_CMD_BACKING_LOAD 88 */
le_engine_backing_stage_next(e, buf_or_NULL, item);  /* ring: 89 */
le_engine_backing_clear(e);                          /* ring: 90 */
le_engine_backing_transport(e, PLAY | PAUSE | STOP); /* ring: 91 */
le_engine_backing_seek(e, frame);                    /* ring: 92 */
le_engine_backing_set_end / _set_output / _set_level / _set_pan;  /* direct stores */
le_engine_set_click_pan(e, pan);                     /* direct store */
le_engine_backing_state(e, &state);                  /* reads, and collects returns */
/* Part 2: the app's decoder */
#define LE_BACKING_MAX_SECONDS 900
#define LE_MEM_RESERVE_BYTES (512ll * 1024 * 1024)
le_backing_decode_file(path, rate, start_frame, max_frames, &out, &info);
le_backing_probe_file(path, &info, peaks, buckets);
/* LE_ERR_TOO_LONG = -12; LE_ERR_UNSUPPORTED (-5, existing) for a file
 * outside the whitelist; LE_ERR_INVALID for a damaged one */
```

**Handoff protocol (review H1, as built).** The review's three races are
races between a control-side pointer swap and the callback's advance. The
built protocol has no control-side swap:

1. Only the audio thread changes which buffer is loaded or staged. `load`,
   `stage_next` and `clear` travel the command ring with the buffer pointer
   (the ring's release push and acquire pop order the buffer's contents),
   and the End = Next advance happens inside the callback. A load or stage
   and an advance therefore never interleave: each applies whole, in ring
   order, at a block boundary or a frame. There is no `a_backing_next` for
   the control thread to exchange and nothing it parks.
2. A buffer the callback will never read again goes back through one of
   `LE_BACKING_MAX_BUFFERS` return slots (compare-exchange from NULL, release).
   The control thread exchanges each slot back to NULL (acquire) and only
   then frees, in `le_engine_backing_state` and before every load or stage.
   A buffer is in at most one place (loaded, staged, the fade voice that owns
   it, a return slot, or the ring), and only a return-slot exchange or a
   stopped-callback release frees it, so it is freed exactly once and never
   while the callback can reach it.
3. The registry admits a buffer only while fewer than four are owned and the
   owned PCM stays within the byte budget, and every buffer in a return slot
   is owned and distinct, so a return slot is always free. The advance still
   checks: with no free slot (forced by a test) it refuses, stops and reports
   `LE_BACKING_EV_NEXT_MISSING`; it never overwrites or drops a buffer.
4. Nothing needs a per-block ack: a return slot is filled only after the
   callback's last read of that buffer (the fade voice keeps a shared buffer
   until its own ramp ends), so a stopped voice holds nothing back and a
   replace is never stuck in `NOT_READY` (that code means only "a buffer is
   in transit; retry after one block"). In transit is counted, not guessed
   (review of #1222, L1): the callback counts the buffer-carrying loads and
   stages it applied and flags while the fade voice owns a replaced buffer,
   and the registry compares those with what it posted, so a stage that fits
   once a fading buffer is back reads `NOT_READY`, never `CAPACITY`.
5. Configure, reopen and destroy release with the callback stopped,
   including any buffer still queued in the ring (which they reset).

Proof: `test_backing_handoff_races` (`src/test/test_backing_races.c`) runs
`le_engine_process` on one thread in blocks of 1 to 61 frames with End =
Next and 1-200-frame buffers, so advances land inside blocks continuously,
while the control thread performs 20,000 random loads, stages, clears,
seeks, transports and collects, checking the registry bounds after each. It
runs before the races-only exit of `run_native_tests.sh`, so CI's
`native-tests-tsan` job (`NATIVE_TESTS_ONLY=races`, `-fsanitize=thread`) and
the ASan job both run it. Checked against mutations: letting a replaced
buffer go back while the fade voice still reads it is caught by ASan
(heap-use-after-free in `backing_frame`).

**Mix point and capture.** As D5. A capture whose captured bus carried the
backing records `"backing_in_master": true` in its sidecar (review L8), so
the DAW export can say the stems lack it.

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

### Part 1: native backing voice and click pan (built: PR #1222, about 900 lines)

As built; section 4.1 is the contract and section 12 the record. Files: new
`src/core/engine_backing.c` (buffers, the control-thread registry with its
transit counts, the API), `engine_process.c` (`le_backing_apply`, the fade
voice, `backing_frame` after `click_frame`, the guarded End = Next advance,
the per-block publish, the capture marker, `click_frame` through
`le_fx_route_frame`), `engine_private.h`, `engine.c` (seeding,
`reset_material` releases everything, `reset_runtime` keeps the loaded and
staged buffers and bumps the epoch, destroy, raw posts refused),
`lockfree_ring.h` (the buffer payload), `engine_core.h`, `engine_commands.c`
(the marker reset at arm), `perf_drain.c` (`backing_in_master`),
`segno_engine_api.h`, `CMakeLists.txt` and the macOS forwarders, bindings,
`packages/segno_engine/.gitignore` (`*.o`). No `engine_voice.h` and no
block-end ack: buffers come back through four return slots (4.1 item 4).

Tests (`src/test/test_engine_backing.h`, literal ramps, exact comparisons):
`test_backing_buffer_and_refusals` (including non-finite PCM),
`_play_literal`, `_level_pan_route`, `_pause_resume_stop_ramps`,
`_seek_clamp_and_preserve`, `_end_modes`, `_replace_while_playing` (the
four-buffer bound reads NOT_READY while buffers are queued),
`_independent_of_loops`, `_output_bus_processes_it`, `_in_master_capture`,
`_excluded_from_stems`, `_lifetimes` (reopen, configure, a configure while a
Pause still fades, destroy), `_byte_budget` (CAPACITY with nothing in
transit, NOT_READY while a replaced buffer still fades),
`_advance_refused_when_returns_full`, `_marks_capture` (two captures on one
engine), `test_click_pan`; and `src/test/test_backing_races.c`, the paced
handoff stress test, under ThreadSanitizer and AddressSanitizer.

```success-criteria
GOAL: An independent, routed backing voice plays an engine-owned buffer sample-exactly with Play, Pause, Stop, seek and End = Stop/Repeat/Next, level, pan and an output mask, is processed by the output buses and captured on the captured bus, never reaches stems or loop takes, and the click gains pan.
SUCCESS CRITERIA:
- Literal-ramp oracles hold for play, level, pan, routing, ramps, seek, the three End modes, gapless Next, replace and Cut sound. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- Buffers are freed only on the control thread, after the callback hands them back through a return slot or with the callback stopped; configure, reopen and destroy leak nothing; a load past the bounds reads NOT_READY while a buffer is in transit and CAPACITY otherwise; sanitizer and telemetry-off builds pass. | verify: EXTRA_CFLAGS="-fsanitize=address -g" bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS="-DLE_CALLBACK_TELEMETRY=0" bash packages/segno_engine/src/test/run_native_tests.sh
- master.pcm contains the routed backing; stems and events.log do not; existing click tests are unchanged at pan 0. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- Bindings are regenerated and formatted, symbol parity holds, and the C++ shim repro compiles. | verify: (cd packages/segno_engine && dart run ffigen --config ffigen.yaml && dart format lib/src/generated/segno_engine_bindings.dart && git diff --stat lib/src/generated) && packages/segno_engine/tool/check_ffi_symbols.sh "$(bash packages/segno_engine/tool/build_test_lib.sh)"
- The handoff stress test passes under ThreadSanitizer (no report) and AddressSanitizer; the byte budget, the refused advance and the capture marker hold. | verify: NATIVE_TESTS_ONLY=races EXTRA_CFLAGS="-fsanitize=thread -g" bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS="-fsanitize=address -g" bash packages/segno_engine/src/test/run_native_tests.sh
NON-GOALS:
- File decoding, resampling, Dart, UI, sessions.
VERIFICATION COMMAND: bash packages/segno_engine/src/test/run_native_tests.sh
```

### Part 2: decode and resample (built: PR #1223, about 900 lines)

As built; D2, D2a and D3 are the design and section 12 the record. Files:
new `src/core/engine_decode.c` (the whitelist header parse, bounded I/O,
the probe, the whole and bounded decode, the memory floor, the polyphase
converter `le_resample_offline` and its offset form), `miniaudio_impl.c`
(`MA_NO_DECODING` dropped; `MA_NO_FLAC` and `MA_DR_MP3_ONLY_MP3` added),
`miniaudio.h` (three `SEGNO PATCH` markers, recorded in its README),
`segno_engine_api.h` (`le_backing_decode_file`, `le_backing_probe_file`,
`le_backing_buffer_pcm`, `LE_ERR_TOO_LONG`; `LE_ERR_UNSUPPORTED` reused),
`engine_core.h`, `CMakeLists.txt` and the macOS forwarders, bindings,
`run_native_tests.sh` and the ASan CI job (the fuzz driver under UBSan).
Fixtures in `src/test/fixtures/backing/` with their README: two 1 kHz sines
(MP3, FLAC), a short tagged MP3, an MPEG Layer II file, an AIFF and the five
review reproducers.

Tests (`test_engine_backing.h`): `test_resample_identity_and_guards`,
`_dc_tone_and_alignment`, `_alias_and_image`; `test_backing_decode_wav_formats`,
`_192k`, `_mp3_and_no_flac`, `_refusals`, `_bounded`, `test_backing_probe`,
`_memory_guard` (every term of the peak, the halving path included),
`_header_checks`, `_whitelist` (the reproducers and every accepted and
refused format and container), `_non_finite`, `_bounded_matches_whole`
(converted and halved), `_work_bound`; and the fuzz driver
`src/test/fuzz_backing_decode.c` in every configuration.

```success-criteria
GOAL: WAV and MP3 files decode off the audio thread into stereo float buffers at the engine rate through a band-limited converter, whole or bounded, behind a format whitelist checked before any decoder sees the file, with a streaming probe for import and a memory floor every decode respects; no input crashes, hangs or yields a non-finite sample.
SUCCESS CRITERIA:
- Identity is exact; DC, 1 kHz level, residual, alias, image and alignment meet the literal bounds for 44.1, 48, 88.2, 96 and 192 kHz sources. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- WAV variants decode to exact ramps; the MP3 fixtures decode, the short tagged one included; a bounded read equals the whole-file decode at the same positions; the probe validates and peaks with no PCM retained and refuses what the converter cannot reach from any engine rate. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- Formats and containers outside the whitelist, the review reproducers, non-finite samples, short fact chunks, chunks past the end of the file, a length mismatch, a file over the cap and a decode that would breach the memory floor are refused with their codes, and an exhausted work budget ends a decode. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- The fuzz driver finds nothing under ASan and UBSan; telemetry-off, shim repro and symbol parity pass. | verify: EXTRA_CFLAGS="-fsanitize=address -g" FUZZ_CFLAGS="-fsanitize=undefined -fno-sanitize-recover=undefined" SEGNO_FUZZ_ITERATIONS=20000 bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS="-DLE_CALLBACK_TELEMETRY=0" bash packages/segno_engine/src/test/run_native_tests.sh && packages/segno_engine/tool/check_ffi_symbols.sh "$(bash packages/segno_engine/tool/build_test_lib.sh)"
- Appliance: a five-minute 44.1 kHz MP3 decodes at the device rate in under 3 s; peak RSS with A playing, B staged and C importing, all at 96 kHz, with eight tracks recorded, stays under 6.5 GB; no xrun is logged while a 96 kHz decode runs with loops playing. | verify: manual on the console: a timing log line around the decode, VmRSS from /proc/self/status, xrun count from the callback telemetry. [HARDWARE]
NON-GOALS:
- Streaming, FLAC (until #1235), Ogg/AIFF/AAC/MPEG Layer I-II, multichannel downmix, tempo or pitch change, a decode helper process.
VERIFICATION COMMAND: bash packages/segno_engine/src/test/run_native_tests.sh
```

### Part 3: the Dart engine seam (built: `claude/backing-1200-p3`, about 840 code lines)

Files: `packages/segno_engine/lib/src/audio_engine.dart` (`BackingControl`,
composed into `AudioEngine`; `EngineResult.tooLong`), new `backing.dart`
(`BackingState`, the transport, End and end-event enums, `AudioFileInfo`,
`AudioProbe`, `DecodedAudio` and its ownership, the `AudioDecoder`
interface), new `native_audio_decoder.dart` (`NativeAudioDecoder`), new
`mock_audio_decoder.dart` (`MockAudioDecoder`), `native_audio_engine.dart`
(the FFI calls; `PumpedNativeEngine.pump(output:)`), `mock_audio_engine.dart`
(an in-memory voice), exports, and the four `AudioEngine` test fakes
(`test/helpers`, looper, session and performance repositories), which accept
the new role and load nothing.

Tests: `test/backing_test.dart` (enum codes, the state value, the mock
decoder's length rule, truncation, refusals and free count, `DecodedAudio`
ownership, every mock-engine rule: transfer, End = Stop/Repeat/Next, pause,
seek clamp, replace/restage/clear freeing, a fresh start freeing and bumping
the epoch, the byte budget, NaN refusals) and `test/native_backing_test.dart`
against the built library (decode through the runner, exact samples, a
bounded read, rate conversion length, the probe's peaks, refusals as typed
exceptions; through the pump: the decoded samples on the routed outputs, End
= Next continuing into the staged file and freeing the finished one,
refusals keeping the audio the caller's, settings and transport through the
state).

```success-criteria
GOAL: Dart reaches the backing voice through one engine role and files through one engine-free decoder that decodes off the calling isolate, with a mock that keeps the same rules and ownership.
SUCCESS CRITERIA:
- The native seam decodes through the runner, loads, plays, stages, seeks, clears and reports state through the real FFI, and the samples it plays are the samples it decoded. | verify: SEGNO_ENGINE_LIB=$(bash packages/segno_engine/tool/build_test_lib.sh) /Users/Tomas/development/flutter/bin/flutter test packages/segno_engine/test/native_backing_test.dart
- The mock obeys the same rules, and every decoded buffer is freed exactly once, by the engine that took it or by dispose. | verify: (cd packages/segno_engine && /Users/Tomas/development/flutter/bin/flutter test test/backing_test.dart)
- The package suites that fake the engine still pass; analyzer and Bloc lint are clean. | verify: (cd packages/looper_repository && /Users/Tomas/development/flutter/bin/flutter test) && (cd packages/session_repository && /Users/Tomas/development/flutter/bin/flutter test) && (cd packages/performance_repository && /Users/Tomas/development/flutter/bin/flutter test) && dart analyze --fatal-infos lib test packages && bloc lint lib test packages
NON-GOALS:
- Repository, files on disk beyond test fixtures, UI, the NOT_READY retry (Part 4).
VERIFICATION COMMAND: (cd packages/segno_engine && /Users/Tomas/development/flutter/bin/flutter test) && dart analyze --fatal-infos lib test packages
```

### Part 4: `backing_repository`: the asset store and the player (built: `claude/backing-1200-p4`, about 650 code lines)

Uses #1198 Part 1's `le_digest_file` and `le_fs_sync_dir` (on the trunk)
through their Dart seam. Files:
new `packages/backing_repository` (Very Good package template,
`analysis_options.yaml`; no `crypto` dependency),
`lib/src/backing_asset_store.dart` (`list()`, `import(sourcePath, {name})`:
the digest through `le_digest_file` in `Isolate.run`, reuse on an existing
digest, `copyFile` to `Backing tracks/<16 hex>/<name>` through an injected
`BackingCopier` with the #1177 signature, `probeAudioFile` on the copy,
`info.json` (`digest`, `name`, `sourceRate`, `sourceChannels`,
`sourceFrames`, `peaks`) written as `.part`, renamed, then the asset
directory made durable with `le_fs_sync_dir`, the directory removed on any
refusal; `resolve(digest)`, which re-digests before handing a
path to a load), `lib/src/backing_repository.dart` (desired mix and End,
`load(id, {play})`, `stageNext(id?)`, `clear()`, `play()`, `pause()`,
`stop()`, `seek(seconds)`, state polling at 20 Hz only while playing or
loading and on demand otherwise, epoch replay and post-configure re-decode
with the notice event, failure stream with typed reasons), models
(`BackingAsset`, `BackingPlayerState`, `BackingFailure`), `.github/workflows/main.yaml`
(the package's test job and a coverage floor of 95%), `.github/cspell.json`.

Tests (fake `BackingControl`, temp directories, a recording `BackingCopier`):
import digests and copies once, a load of an asset whose bytes changed is
refused as damaged, a `Backing tracks` directory is never listed by
`PerformanceRepository.listCaptures`, a second import of the same bytes reuses the
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

### Part 5: the application owner, mix families and the session (built: `claude/backing-1200-p5`, about 900 lines)

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
{`prepared: [{digest, name}]`, `loaded` (`{digest, name}`, so a missing
loaded file can still be named), `endMode`, `level`, `pan`, `outputMask`}
and `clickPan`, strict at the current schema; the next free version at
landing, assigned in landing order by the main session's ledger, with its
step in #1196's `sessionMigrationSteps`). **The step keeps the live setup**
(rules 1 and 3): a session written before the backing existed says nothing
about it, and opening it on a build without one changed nothing, so the
conversion fills `backing` (the prepared list, the loaded item, End, level,
pan and outputs) and `clickPan` from the player's live values at open, the
way schema 8 kept the former global preferences, and notes each as "taken
from the live setting". A converted session is written back, so the setup
live at its first open becomes its own and later opens recall it like any
other. Without a live player (a bare decode) the values are an empty,
silent backing and a centred click.
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
l10n. `Preview` on backing items plays through the Library audition voice
(its Part 6a), fed by a bounded `decodeAudioFile` (`maxFrames` = the audition
cap), so a preview never decodes a whole file; without Part 6a the `Preview`
control is not drawn. `Export to USB`, `Use in loop` and `Save audio` are not
drawn (section 2, deviation 2). 18/05 is reached from `Use as backing` and
from a `Backing track` button on 18/07 (deviation 3); `Play selected` shows
`Loading <name>…` while it decodes (deviation 4).

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
(18/02: the drive's folders and audio files by extension, listed by name
without parsing them; a file's duration, or `—` with its reason, appears when
it is selected and `probeAudioFile` has run on it, so listing a drive never
runs a decoder over every file; the "Copies to Internal" caption; 18/06 when
no drive), `backing_asset_store.dart` (import from a removable source runs
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

Also: the memory-budget run of D11 (peak RSS, no xrun during a decode).

Decode time and memory on the Pi 5 (Part 2), audible routing, pan and output
FX on real jacks (Part 6), footswitch roles, holds and LEDs (Part 7),
gapless Next and Repeat by ear (Part 8), FAT32/exFAT copies with eject and
pull (Part 9), and a Record performance with backing routed to Main: the
master contains it and the stems do not (also proven natively in Part 1).
Display keep-awake during backing playback (AB 7.6) has no owner yet; when
the idle-dimming owner lands it must read `BackingPlayerState.playing`.

## 8. Findings outside this plan (no product-direction question identified)

- `segno_engine_api.h:242-246` and `:2218-2226` said the click bypasses
  master gain and never appears in captures; slice 3b changed both
  (`engine_process.c:4296-4302`). Part 1 corrected them.
- The Library plan's D8 playback predicate and D9 field-table test predate the
  backing; Part 5 extends both if those parts landed first, otherwise the
  Library parts must include the backing fields when they land.
- **One reader of audio samples (review M3(a)).** As decided in D2:
  `le_backing_decode_file` decodes, natively and bounded, for the backing
  player, the Library preview (Part 6b) and #1198's recovery; `wav_codec`
  is the writer and the header and part model only. Both other plans still
  say otherwise at the time of writing (#1198: `wav_codec` is "the one Dart
  reader"; Library Part 6b: `wav_codec.decodeFloat32`). The coordinator
  routes D2's wording to them.
- **Vendored miniaudio is 0.11.21** with two published decoder CVEs
  (CVE-2024-41147, FLAC, fixed in 0.11.22; CVE-2026-32837, WAV BEXT, open
  through 0.11.25) and three defects the #1223 review found, which the
  decoder's whitelist works around: the post-init double uninit with a field
  address (patched, `SEGNO PATCH`), dr_wav's `fact` handler wrapping a
  chunk under 4 bytes into an endless seek, and the MS-ADPCM predictor
  indexing a 7-entry table with a file byte. #1235 (the update, then FLAC)
  re-checks all of them, re-applies every `SEGNO PATCH` and re-runs the
  fuzzer.
- **A non-finite guard on the output buses (proposed, review of #1223, H3).**
  The backing can no longer carry a NaN or Inf (D2a), but any source can
  still put one on a bus (a hosted plugin, a future instrument), and the
  bus FX keep it for good: the review measured a reverb and a filter staying
  entirely non-finite after the source was gone, and an Inf drives the
  limiter's gain to 0 for that frame. Proposal: in `output_bus_frame`, after
  `fx_apply_chain`, test `isfinite(l) && isfinite(r)` (two compares per bus
  per frame, nothing else on the common path); on a failure write zero for
  that frame and flag the bus; at the end of the block, reset the flagged
  bus's chain state with the same reset a chain rebuild uses, and count it
  in a snapshot field the app turns into a notice ("Output effects on Main
  were reset: they received a damaged signal."; rule 3). `master_bus_frame`
  replaces a non-finite sample with 0 before the limiter. The same check
  would serve the Track and Loop stage chains. This is engine-wide, so it
  belongs to its own issue, not to the backing parts.
- **Loop memory is unbounded.** Lane buffers and undo layers allocate on
  demand with no budget (D11); the decode floor protects decodes from loops,
  not loops from each other. The loop owner's issue, not this plan's.
- A session backup to USB (Library Part 8) carries no backing files; restoring
  it on another appliance shows `Missing` rows until the complete appliance
  backup (E7-15) carries `Backing tracks`. That follows AB 6.8's split.
- **#1198 oracle (review L7).** `test_backing_in_master_capture` compares the
  float master capture sample for sample. #1198's Part 2 replaces
  `master.pcm` with 24-bit parts; whichever lands second re-bases that test
  to a one-LSB (2^-23) tolerance.
- **DAW export (review L8).** The live master contains a routed backing; the
  stems and `project.als` cannot (the backing is not perf-logged, by AB
  3.11). Part 1 records `"backing_in_master": true` in the capture sidecar;
  Part 8 makes the Library's `DAW project` and `Export to USB` (DAW package)
  say "Backing audio is in the recording but not in the stems." when it is
  set (rule 3). Logging backing transport for the package is not done: the
  accepted design excludes backing from renders.

## 9. Defaults taken under the owner rules

- 15-minute file cap, a 1.5 GiB backing budget and a 512 MiB decode floor
  (D1, D11; rule 2, bounded memory, refusal with a reason rather than
  truncation or the OOM killer).
- FLAC refused until miniaudio is updated (D2; rule 2).
- More than two channels refused rather than downmixed (rule 3).
- A format whitelist (WAV PCM 16/24/32 and float32, MPEG Layer III) checked
  by our own header parse, source rates capped at 192 kHz and refused when
  the converter cannot reach every engine rate, and a non-finite sample
  refused as damaged (D2, D2a; rule 2: no crash, hang or poisoned audio).
- Stop during a pending `Play selected` cancels it (rule 2: the last press
  wins and leaves a known state).
- Cut sound stops the backing without a ramp (AB 3.6) and rewinds (the
  catalogue label).
- A retained reopen stops and rewinds the backing; a configure re-decodes it
  stopped, with a notice (rules 2, 3; pen 28).
- Missing assets stay listed as `Missing` (rule 5's notice, rule 2's
  recovery path; never matched by name).

## 10. Budget and review ceiling

Estimates: 850, 600, 840 and 650 (Parts 1 to 4, as built; Parts 1 and 3 over
the 700 ceiling, see section 12), then 640, 470, 640, 680, 400.
Stop for review on any change to the output-bus order, a perf-log code, a
second decoder, a second lease registry or a second selection owner. Each
part gets independent architecture, test-quality and adversarial review
before publication; CI on the published head, `/code-review` and the human
merge gate remain separate.

## 11. Engine numbering (central ledger)

Numbers come from the main session's ledger, not from scanning branches.
Backing owns commands 88-95, perf-log facts 340-343 and `LE_ERR` -12 and -13.
Taken so far: `LE_CMD_BACKING_LOAD` 88, `LE_CMD_BACKING_STAGE_NEXT` 89,
`LE_CMD_BACKING_CLEAR` 90, `LE_CMD_BACKING_TRANSPORT` 91,
`LE_CMD_BACKING_SEEK` 92 (Part 1); `LE_ERR_TOO_LONG` -12 (Part 2). A file
outside the decoder's whitelist reuses the existing `LE_ERR_UNSUPPORTED`
(-5), so no new code was needed for it. Commands 93-95, `LE_ERR` -13 and all
four facts are unused: the backing is never
perf-logged, so no fact is needed. The Session schema bump (Part 5) takes the
next free version at landing and adds its step to the #1196 migration chain.

## 12. Build record

### Part 1 (`claude/backing-1200-p1`, PR #1222)

Built as section 4.1 describes. About 850 production lines over
`packages/segno_engine`, about 180 of them the header's contract comments:
over the 700 ceiling; the voice, its lifetimes, the review's memory and
handoff fixes and the click pan did not split along a reviewable seam.
Departures from the first text, each recorded in 4.1 or D1:

- **Buffers travel through the command ring, not atomic slots** (4.1, the
  handoff protocol), so the Library audition's `engine_voice.h` helper was not
  needed; the audition keeps its own slot (it has no ordering constraint with
  transport commands).
- **New translation unit `src/core/engine_backing.c`** for the buffers, the
  registry and the control API (picked up by the `engine*.c` glob of the
  native runner and `build_test_lib.sh`; listed in CMake; two macOS
  forwarders). The audio-thread voice stays in `engine_process.c`.
- **A replace overlaps** (old fades out while the new starts at frame 0); a
  seek while playing is the same crossfade within one buffer.
- **Settings persist across configure** (seeded at create, like the click's);
  only the transport resets.
- **Raw posts of 88-92 are refused** (LOAD carries a pointer).
- **Review fixes:** the byte budget (`LE_BACKING_BUDGET_BYTES`,
  `owned_bytes` in the state), the guarded advance, the capture marker
  (`backing_in_master`, counted per block into `a_perf_backing_blocks`, reset
  at arm), and the handoff stress test.

Tests: `src/test/test_engine_backing.h` (16 cases, exact-sample oracles) and
`src/test/test_backing_races.c`. Mutations reverted one at a time, each
caught: Cut sound, Repeat, Next, the pause, resume and replace ramps, the seek
clamp, level, pan, click pan, the output gate, the retained reopen, the
epoch, restaging, perf logging, the registry bound, raw posts, the byte
budget, the advance guard, the capture marker, and (stress test under ASan)
returning a buffer the fade voice still reads.

### Part 2 (`claude/backing-1200-p2`, PR #1223, stacked on Part 1)

About 600 production lines. As D2, D2a, D3 and D11 describe; departures from
the first text:

- **The converter is the repo's own** (D3), in the new
  `src/core/engine_decode.c` with the decoder (forwarders and CMake as for
  Part 1). `le_resample_frames`/`le_resample_offline` are internal.
- **Bounded reads, the probe, the memory floor, the header checks, FLAC off
  and the fuzz driver** are the review's M1-M3 (D2, D2a, D11).
- **MP3 encoder delay and padding stay in.** miniaudio's MP3 decoder does not
  read the LAME gapless tag: the one-second fixture decodes to 47232 frames at
  44.1 kHz (ffmpeg trims to 44100), about 25 ms of leading and 45 ms of
  trailing silence. End = Next is sample-exact over the decoded buffers, so
  an MP3 set carries those gaps; WAV does not. Recorded, not worked around.
- Fixtures: `src/test/fixtures/backing/` (a stereo MP3 and a mono FLAC, the
  latter now to prove FLAC is refused; generated by the ffmpeg commands in
  its README); WAV cases are written by the tests.

Measured (dev machine; all literal oracles): DC within 1e-6 for 44.1/48,
48/44.1, 96/48, 44.1/96, 48/96 and 88.2/48; a 1 kHz tone within 0.01 dB with a
residual below -90 dB for each; an 18 kHz alias of a 30 kHz tone (96 to 48),
a 34.1 kHz image of a 10 kHz tone (44.1 to 96) and an 8 kHz alias of a 40 kHz
tone (192 to 48) each below -80 dB; an impulse lands exactly when doubling;
a five-minute MP3 decodes in 0.58 s at 48 kHz, 1.01 s at 96 kHz; 20,000
fuzz inputs under ASan, no finding. Mutations reverted one at a time, each
caught: the window, the band limit, the phase normalization, the halving, the
stated-length cap (observable through the memory floor), the phase offset,
the rate range, the file-size bound, both length-match checks, the memory
floor, the truncation flag, the bounded length, and FLAC back on.

### Review fixes to Parts 1 and 2 (the #1222 and #1223 reviews)

**Part 1** (`6cca20754`): the registry counts transit instead of guessing it
(the callback counts applied buffer posts and flags while the fade voice
owns a replaced buffer), so a stage that fits once a fading buffer is back
reads `NOT_READY` (L1); tests for a configure while a Pause still fades and
for the capture marker across two captures on one engine (L2; the two
surviving mutations are now caught: ASan reports the use-after-free in
`backing_frame`, and the marker test fails); the stray `stretch.o` removed
and `*.o` ignored (L3); the header comments (L4);
`le_backing_buffer_from_pcm` refuses non-finite PCM (defense in depth for
the #1223 review's H3).

**Part 2** (`eaa09a351`, `e06bb06a2`): the whitelist header parse, bounded
I/O and exact backend (H1, H2, M1); non-finite and out-of-range samples
refused (H3); `MA_DR_MP3_ONLY_MP3`; the `SEGNO PATCH` for miniaudio's
post-init double uninit (24 markers now, recorded in its README); rates
capped at 192 kHz, the halving path read straight into planes, and the
memory floor counting every term (M2); the probe refusing rates the
converter cannot reach from any engine rate (L1); bounded reads equal to
the whole-file decode at the same positions (L2); the missing tests (L3);
short tagged MP3s (L4); the whole-file fuzz driver. Refusals outside the
whitelist reuse `LE_ERR_UNSUPPORTED`; Parts 3 and 4 map it (`3f42d99d0`,
`8f9bcba92`) instead of guessing "unsupported" from the file extension.

Measured (dev machine): every review reproducer is refused at once, in
release and under ASan. Peak memory of a 60 s, 192 kHz stereo float WAV
decode: 117 MB at 48 kHz (the review measured 209 MB before the planes
change; the floor now budgets 2 x 11.5 M planes plus a half plane, 115 MB)
and 140 MB at 96 kHz. Fuzzing with the new driver under ASan and UBSan: a
first campaign of 6 x 150,000 inputs found one defect (finite floats near
`FLT_MAX` overflowing the converter, now refused, its input a fixture);
after the fix, 10 x 150,000 inputs (1.5 million, seeds 1-6 and 101-108)
found nothing. Native suites plain, ASan (with the UBSan fuzz run of
20,000) and telemetry-off, and the races-only ThreadSanitizer pass, all
green on the Part 2 head; the C++ shim repro compiles; bindings
regenerated and formatted.

### Part 3 (`claude/backing-1200-p3`, stacked on Part 2)

About 840 lines of Dart code (1,180 with doc comments) in `segno_engine`,
over the 700 ceiling: the mock voice and mock decoder are about 330 of it and
cannot leave the part, since `MockAudioEngine` must implement the role the
moment it joins `AudioEngine`. Departures from the first text:

- **The decoder is its own engine-free interface,** `AudioDecoder`
  (`NativeAudioDecoder`, `MockAudioDecoder`), not part of `BackingControl`,
  following `StorageIo`: the Library preview and #1198 use it with no engine
  (review M3), and a repository holds one beside its engine. Names:
  `decode` and `probe`, not `decodeAudioFile`/`probeAudioFile`.
- **`DecodedAudio` makes ownership explicit** (`owned`, `transferred`,
  `disposed`): an accepted load or stage transfers it, `dispose` frees it
  otherwise, both idempotent; the native engine refuses audio it does not
  own or that a different decoder made.
- **The `NOT_READY` retry moved to Part 4.** Every engine call is
  synchronous; waiting a block belongs to the repository that owns the load.
- **`PumpedNativeEngine.pump` can return the block's output** (`output:`),
  so a test reads what the engine played.
- Mutations reverted one at a time, each caught by its intended test: the
  native transfer, the foreign-audio refusal, the state mapping, the decoder
  refusal, the mock's advance, restage, budget and fresh-start freeing,
  double dispose, and the `tooLong` mapping.

Verified on the pushed head: `dart analyze --fatal-infos lib test packages`
clean; `bloc lint` 0 issues; `segno_engine` (404), looper (806),
session (189), performance (130) and app (3469) suites pass against a
freshly built test library; formatting unchanged. No native change.

### Part 4 (`claude/backing-1200-p4`, stacked on Part 3)

A new package, `packages/backing_repository`: about 650 lines of Dart code
(900 with doc comments). Departures from the Part 4 text:

- **`BackingCopier` is `(sourcePath, relativePath)`.** The app wires it to
  `StorageRepository.copyFile(source, StorageDestination.internal(),
  relativePath, onConflict: ConflictPolicy.replace)`; the repository does not
  depend on `storage_repository` (no repository-to-repository import).
- **The digest and the directory sync are `StorageIo`'s** (#1198 Part 1):
  `digestFile` in `Isolate.run`, `syncDirectory` after `info.json` is renamed
  into place and again on the store. Both are injectable for tests.
- **The repository takes `BackingControl` and `EngineMetering`** (the same
  engine object in production; the metering role supplies the rate).
- **Engine tokens are pruned by age, not by what the engine reports.** A
  load the engine has accepted is applied at its next block, so a read made
  in between still shows the old token; pruning by the report would lose the
  new one. The native test proves it (`native_backing_repository_test.dart`,
  over the pump).
- **`NOT_READY` is retried once after 25 ms** (about one block), then
  reported as `busy`; a load whose decode finished after the rate changed is
  decoded again once (L3); a superseded or cancelled load frees its result.
- **Refusal reasons:** a decoder `invalid` reads as `unsupported` when the
  name is not `.wav`/`.mp3`, else `damaged`; an asset with an unreadable
  `info.json` is listed as `damaged` with a placeholder digest built from its
  directory id (it can never resolve; import of the same bytes replaces it).
- **No `listCaptures` exists on the trunk yet** (it is Library Part 7); the
  test that the store is never taken for a capture is on
  `PerformanceRepository.findUnfinalized`, the boot salvage scan.
- **CI:** a `backing-repository` package job (coverage floor 95%; 96.7%
  measured without the library, 98.8% with it) and the native test in the
  `fuzz` job, which builds the library.

Verified on the pushed head: `dart analyze --fatal-infos lib test packages`
clean; `bloc lint` 0 issues; formatting unchanged; `backing_repository`
(34), `segno_engine` (404), performance (131) and app (3469) suites pass
against a freshly built test library. No native change.
- Mutations reverted one at a time, each caught: pruning by report, the
  retry, Stop cancelling a load, freeing a superseded decode, the settings
  replay, the reload after a configure, the notice, the re-decode after a
  rate change, dedupe, the copy-digest check, cleanup on failure, the digest
  check in `resolve`, and the store sync.

### Part 5 (`claude/backing-1200-p5`, stacked on Part 4)

About 900 production lines (the families and the Session block are larger
than estimated). Departures from the Part 5 text:

- **A migrated session keeps the live backing (rule 1, rule 3).** The 12
  to 13 step fills `backing` and `clickPan` from the player's live setup at
  open, the way schema 8 kept the former global preferences, not with an
  empty list and mask 0: a session written before the backing existed says
  nothing about it, and opening it on a build without one changed nothing.
  Without a live player (a bare decode) they are empty and centred. Noted
  in the conversion notes.
- **The loaded item is `{digest, name}`, not a bare digest,** so a loaded
  file that is no longer prepared can still be named when it is missing.
- **The step is keyed 13 in `sessionMigrationSteps` (`_v13ToV14`) and the
  schema is 14 on this branch,** after Reverse Part 2 landed at 13; M/D
  Part 2 also wants 14, so whichever lands second
  renumbers the key, the step and `Session.formatVersion` (the
  `v14_backing_p5` fixture is regenerated from its generator).
- **`BackingMixFamily` is one record with a field per address**
  (`BackingMixField`), like Fade, so a level controller is never
  superseded by a pan edit; `ClickPanFamily` is a scalar like click
  volume. Neither has a native receipt: the repository's setters are
  direct stores it replays after an engine restart (it now replays the
  click pan too).
- **The Session seam is a `SessionBackingPort`** passed to the settings
  coordinator (optional, like the pedal-binding callbacks, so the other
  coordinator tests need no backing); Open installs it after Fade inside
  the Session exclusion, and boot Retry installs it again.
- **New Loop is not built yet** (Library Part 5); `SessionBackingPort.stop`
  is its stop, for that part to call.
- **The copier is the app's own internal copier** (`.part`, flush, rename,
  part deleted on failure) because `InternalOnlyVolumes` refuses Internal;
  it is swapped for the storage service's `copyFile` when that stands
  behind the port.

Tests: `test/backing/application/backing_player_test.dart` (15),
`test/backing/cubit/backing_cubit_test.dart` (2),
`test/looper/application/backing_settings_test.dart` (10, including the
`BackingMix` record), a session cubit test that Open stops the backing and
installs the session setup stopped at 0, the Session block's strict
round trip, defaults and refusals, the 13 to 14 step against the v13
fixture, a v14 fixture that opens with no conversion, the settings
checkpoints, the internal copier. Mutations reverted one at a time (18),
each caught: duplicates on Add, the selection on Remove, the Pause toggle,
releasing the staged Next before a Play selected decode, staging outside
End = Next, the selection always following, the missing-item report, the
Use as backing confirmation, the stop on recall, the mix and click pan not
applied, the durable value taken whole, a centre click pan written over
absence, the install on Open, the capture on Save, the migration
defaulting, a lenient Session block and repeated digests.

Verified on the pushed head: `dart analyze --fatal-infos lib test
packages` clean; `bloc lint lib test packages` 0 issues; formatting
unchanged; the app suite (3529), `session_repository` (241),
`settings_repository` (203) and `backing_repository` (38) pass against a
freshly built test library.

### Second review round (P1 to P5), rebased on trunk `890f04936`

The whole stack was rebased onto `890f04936`; the conflicts were neighbouring
edits (#1198's `LE_ERR_NOT_FOUND` -18 and `LE_ERR_TRUNCATED` -19 beside
`LE_ERR_TOO_LONG` -12, the tuner's block in `engine_private.h`, the
bindings, regenerated at each head), and P5 adapts to the trunk's guards and
`FileDigest`. Fixes:

- **P1 L5:** the transit check reads the applied count before the fade flag.
- **P2 L5:** a bounded read that starts past the last output frame returns
  an empty buffer (`LE_OK`, not truncated), and the voice refuses to load or
  stage an empty buffer.
- **P3 L1:** the mock takes backing calls while configured but stopped, and a
  retained reopen keeps its buffers stopped at 0 with a new epoch. **L2:** a
  `NativeFinalizer` over `le_backing_buffer_free` guards a native decode
  until the engine takes it or it is disposed.
- **P4 M1:** a damaged managed copy is replaced on re-import (D7). **L1:**
  NOT_READY is retried up to eight times, 10 ms apart. **L2:** a hand-over
  refusal is busy, never damaged. **L3:** the rate is read from a snapshot
  only on a restart. **L4:** imports of the same bytes run one after the other.
- **P5 M1:** no state during a reload reads "nothing loaded", the player
  follows the repository's file, Play after an unseen restart waits for the
  reload, and the reload starts on the restart itself (D10). **L1:** a
  recalled loaded item that cannot load stays named and is saved.
  **L2 / plan D4:** Part 5's text states the live-keeping migration.
- The schema is 14 on P5 (`13: _v13ToV14`), after Reverse Part 2 took 13; M/D
  Part 2 also wants 14, so the second to land renumbers.

Verified on the new heads: the native suite plain, ASan (with the fuzz driver
under UBSan, 20,000 inputs) and telemetry-off, and the races-only pass under
ThreadSanitizer, each in its own `TMPDIR`, on P1 and on P2; bindings
regenerated with no diff; `segno_engine` (409), `backing_repository` (41,
98.6% line coverage), `session_repository` (250), `settings_repository`
(204), `looper_repository` (814), `performance_repository` (136) and the app (3499)
suite pass against a freshly built test library; `dart analyze --fatal-infos
lib test packages` clean; `bloc lint` 0 issues; formatting unchanged.
Mutations reverted one at a time, each caught: P3 the reopen release, the
running gate, both finalizer detaches; P4 the unchecked reuse, the
import run concurrently, a single retry, the damaged hand-over, the snapshot per
refresh; P5 the separate clear emit, adopting the repository's file, Play
not waiting for the reload, dropping the missing loaded item, the restart
refresh.

### Verification (Parts 1 and 2, on their pushed heads)

Recorded in the PR bodies and the main session's report: the native suite
plain, ASan and telemetry-off, each in its own `TMPDIR`; the races-only pass
under ThreadSanitizer; `dart analyze --fatal-infos lib test packages`;
`bloc lint lib test packages`; the app suite and the `segno_engine` suite
against a freshly built test library; regenerated, formatted bindings; the
C++ shim repro with the changed headers.

## 13. Hardware still owed

Decode time and memory on the Pi 5, no xrun during a decode with loops
playing (Part 2); audible routing and the backing in a real performance
capture (Parts 1, 6).

## 14. Review map (PR #1207, 2026-10-06)

| Finding | Where it is answered |
|---|---|
| H1 auto-advance race | 4.1 handoff protocol (as built: no control-side swap, guarded advance, stress test under ThreadSanitizer and ASan); Part 1 criteria |
| M1 memory | D1, D11 (budget table, enforcement), Part 1 byte budget, Part 2 floor, probe and bounded reads, hardware criterion |
| M2 untrusted files | D2a (header checks, decoded-length cap, length match, FLAC off for CVE-2024-41147, WAV metadata off for CVE-2026-32837, fuzz driver, residual risk and why no helper process); section 8 (miniaudio update) |
| M3 consolidation | D2 (one decoder, bounded form for preview and #1198), D7 (`le_digest_file`, full digest, verified at load) |
| M4 pen deviations | section 2, deviations 2-4; Part 8 |
| M5 recovery row | D9 (#1198 Parts 14-15 own it, by this plan's digest) |
| L1 merge conflict | rebased on `097e1ef68`; `.github/cspell.json` resolved as a union |
| L2 reopen notice | D10 |
| L3 rate change during a decode | D10 |
| L4 Play selected latency | D4, deviation 4, D11 hardware criterion |
| L5 schema number | Part 5 (landing order, the main session's ledger) |
| L6 store location | D7 (stays under `exportsRoot` to reuse `copyFile`; capture listing skips it, tested in Part 4) |
| L7 #1198 oracle | section 8 |
| L8 DAW export | 4.1 and section 8 (`backing_in_master`, the export says so) |

**Delta review and the #1222/#1223 reviews (2026-10-06):**

| Finding | Where it is answered |
|---|---|
| Delta D1 stale Part 1/2 text | Parts 1 and 2 rewritten to the as-built design |
| Delta D2 stop band | D3 (the half-band stage stops at -78 dB) |
| Delta D3 the D2 promise | D2 (the probe refuses rates the converter cannot reach) |
| Delta M1 D11 worst case | D11 (2.1 GB for a 192 kHz source on a 96 kHz engine; rates capped at 192 kHz) |
| Delta M2 untrusted files reopened | D2a rewritten; #1223 H1-H3, M1 below |
| Delta M3(a) one reader | D2 and section 8: `le_backing_decode_file` decodes, `wav_codec` writes and models headers; the coordinator routes it to #1198 and the Library plan |
| #1223 H1, H2, M1 | D2a (own header parse before miniaudio, bounded I/O, one backend, whitelist, `SEGNO PATCH`) |
| #1223 H3 | D2a (non-finite and out-of-range samples refused); section 8 (proposed output-bus guard) |
| #1223 M2 | D11; Part 2 (planes, full estimate, 192 kHz cap) |
| #1223 L1-L4 | D2; section 12 (review fixes) |
| #1222 L1-L4 | 4.1 item 4; section 12 (review fixes) |
