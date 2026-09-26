# Audio and state parity implementation plan

Status: concrete implementation plan and source audit, 2026-09-08. Production
application, repository, engine and firmware files were not changed. This plan
extends the accepted September 6–8 design work and the consolidated appliance
roadmap; it is not a second delivery programme or an assertion of audio parity.
The coordinator owns issue/stage/autonomy tracking. Hardware listening and timing
work retains `autonomy:blocked-verify`; independently testable data/logic slices
can follow the existing issue's established authority.

The engine foundation should be retained. The shortest complete route is to make
one musical state and one content-history contract survive a staged session
commit, then build transforms, backing and rendering on that state. Replacing the
engine, continuing to patch unrelated histories or shipping another Settings
surface would prolong the same inconsistencies.

## Evidence and current gaps

Evidence was re-read from the shared checkout at production revision
`aaf042655b5059d9aff7c647a02249c1d019de84`, the current prototype, the supplied
User Guide 1.0.0 printed pages 33–35/47–48, and the existing engine audit. Native
source inspection is distinct from the new browser and symbolic checks below.
No native or Flutter suite was freshly executed for this plan.

| Contract | Current concrete evidence | Required correction |
|---|---|---|
| Recording Undo/Redo | `engine_commands.c:1177`/`:1235` reject recording and overdubbing; the layer-retire path already queues Undo while a completed layer drains. | Accepted Undo during an initial take or overdub must finish/cancel that captured content coherently, preserve a recoverable partial layer and return to playback/empty as appropriate. Redo restores audio without re-entering record. |
| Clear all | `lib/control/cubit/control_cubit.dart:947` loops over track clears, resets mutes and UI; `undoClearAll` at `:1006` scans remaining per-track clear markers and allows partial restoration. | One group identity with all affected content, timing and changed transport states; one Undo/Redo restores/reapplies the group atomically, preserving earlier histories and later unrelated settings. |
| Prototype history | The September 8 correction now routes capture, length, Peel, Bounce, Import and Clear through `stage-transport-study.js` and persisted `rig.editHistory`. Feature-local recovery stacks were removed. | Carry this tested symbolic contract into native content revisions. Mode, view or bank changes must not decide which history Undo sees. |
| Durable history | `SessionRigLane.layers` already carries oldest undo → live → redo PCM. The corrected prototype reloads real per-track/shared edit entries by ID and does not reconstruct history from visible layers. | Persist native revision references and group entries with explicit bounds. Loaded layers alone cannot reconstruct an undone recording, Divide, Peel or Bounce. |
| Musical recall | `lib/session/session_mapping.dart:148` maps mode/crown/one-shot/lanes/FX but omits manifest tempo, signature, click, quantize and count-in fields. `SessionRig` has no members for them. | Add the complete typed musical state; restore it in the same engine transaction as audio and update caches/settings only after success. |
| Independent-clock recall | `engine_session.c:272` rejects Free/Song commit; `engine_process.c:2613` repeats the guard, resets grid/divisor/start iteration and marks imported tracks Playing. | Restore each track's actual clock and relationships, including no primary, without forcing a shared base. Explicit stopped-load policy must replace auto-playing import. |
| Partial load failure | `LooperRepository.applySession` clears every live track before importing layers, then throws on a rejected import/commit. | Decode, validate, reserve and stage before replacing the audible rig. Failure/cancel must leave the prior rig and current identity intact. |
| Mode semantics | Native `segno_engine_api.h:109–125` explicitly describes Song as the same independent transport as Free. The accepted card says “One section at a time.” Native Multi still accepts whole-loop multiples; the accepted card says equal length. | Implement the accepted Multi/Song/Band policy and explicit mode-relative scheduling, preserving Free/Sync strengths. Do not mark five names as five completed journeys. |
| Per-track decay | `engine_commands.c:1695` writes one engine-global feedback atomic; `engine_process.c:4420` reads it once for every lane. | Per-track decay, converted once to a keep factor, with pass history capturing the earlier-audio state before decay. |
| One-shot | `advance_track_clock_frame` at `engine_process.c:3139` stops at Free/Song wrap; shared-clock modes do not call it. | Per-track Once works in all five accepted modes, including reverse and multiple/division boundaries. |
| Tempo following | Current tempo commands lock with content; Signalsmith 1.1.0 exists only in the dated benchmark under `src/test/bench`. | Implement follow-tempo and pitch-preserving playback with clear ratio composition, latency accounting and appliance capacity/listening gates. |
| Pre/Post and outputs | `track_effect.dart:226` declares dry, stageless recording. Native Master FX precedes `mix_monitors_frame`; click is injected after the master/performance tap. Track FX routing depends on lane audibility. | Printed Pre playback representation, tail-preserving Post, and true per-output processing after all routed sources, including live inputs/backing/click. |
| Bounce/export | Prototype stores a recipe and uses exact rational LCM of stored decimal beat lengths, with an explicit 1024-beat bound. Session `_mixdown` sums raw unmuted lane PCM at gain over sample-count LCM. `perf_render.c` explicitly excludes monitor inputs, hosted-plugin processing and pre-arm tails in its wet reconstruction. | A defined render graph and duration/tail policy, immutable source revisions, worker rendering and transactional destination commit. Existing mixdown/render functions are ingredients, not a completed audible Bounce. |
| Import/backing | Native layer import serves restore into empty state. Backing has no independent production player. The new Library prototype changes symbolic metadata. | Managed decoded media, real track import/resampling/timing, independent streaming backing transport, seek and route/capture integration. |

The original four symbolic defects are now covered by behavioral acceptance in
`node docs/design/verify_audio_state_reconciliation.cjs` (10/10 contracts):

- Overdub → Divide → Undo restores length first and the overdub second.
- Peel, Multiply, Bounce, Import and Clear use the same ordered history; a feature
  Undo cannot jump past a newer edit. Group entries survive JSON save/reload and
  cannot overwrite newer edits on another affected track.
- Later mixer/FX changes survive recovery. Grouped Clear restores the prior
  playing/stopped states and the stored musical phase; elapsed time is not rewound.
- Song has one section; Band preserves the primary bed and at most one other
  section through direct play, Start/Stop all and MIDI Start/Continue.
- Fractional imported duration and source/retained-region identity survive length
  edits and recovery without whole-beat array rounding.
- Multi/Sync/Band compatibility guards refuse invalid length changes atomically.
  Unresolved automatic Sync/Band capture against an existing primary requires an
  explicit compatible record length. An early press waits for that fixed boundary.
  Stop at an incompatible partial boundary is refused with a continue/Undo notice;
  the partial take is not silently resized or discarded. A canceled partial take
  remains in Redo, but incompatible recovery is refused until a compatible mode
  is chosen. These restrictions are open timing-policy work, not mode completion.

**September 8 owner correction and implemented prototype:** the restriction above is superseded
for partial takes within an established Multi cycle. A four-bar loop may contain
only one bar of recorded audio and silence elsewhere. Recovery must preserve
captured content and its cycle position separately from the shared loop length.
Redo restores playback in Multi without changing modes or stopping other tracks.
[Recording recovery evidence](../design/2026-09-08-capture-recovery-ux.md) now demonstrates and verifies this in the symbolic prototype; native implementation remains outstanding.
Native capture/recovery guards still need the corresponding implementation and sample-level verification. The symbolic prototype correction is complete.

The shared history is stored in `rig.editHistory`; a fresh session clears it
explicitly, while transport reset reloads it on demand. Initial demonstration
layers have no fabricated earlier edit history. Production persistence bounds,
atomic media/session transactions and audio callback behavior remain unimplemented.

The existing transport behavior suite passes with the canonical edit adapter;
its general timing cases use Free mode and the new acceptance suite separately
covers mode-specific compatibility. Mapping still passes seven standalone
contracts plus Chrome/Firefox integration. The integrated audio-state suite also
passes both browsers for real dispatch, chronological recovery, persisted Redo,
grouped Clear and Multi compatibility. Import failure/metadata checks are included
in that suite after the final one-save host integration. The media agent is updating older
journey assertions to the corrected Stage navigation and shared-history model;
those checks must be reported by their actual final results, never inferred.

## State ownership and the restore contract

Keep presentation → Bloc/Cubit → repository → data/engine boundaries. `AudioEngine`
remains the seam for repository tests. `SessionRepository` owns validated media
and bundle I/O; `LooperRepository` owns live audio intent, engine transactions and
restart replay. The application mapping above both repositories translates the
session model into the domain rig. Controllers emit the same typed commands as
touch; they do not mutate engine state directly from presentation.

The canonical session state must include the following current and target fields.
Do not introduce a second shadow model in individual pages.

| State family | Fields / restore rule |
|---|---|
| Grid | `tempoBpm`, `tempoSource`, `tsNum`, `tsDen`, `quantizeDiv`, origin/loop bars and first-take inference state. Restore “unset” as unset; do not substitute the old rig's tempo. |
| Recording defaults and overrides | Record→Play/Overdub, pedal/sound start, count-in bars and scope, length Auto/1–64, start/end quantization and inheritance. Empty tracks' overrides also round-trip. |
| Click | `clickMode`, `clickOutputMask`, `clickVolume`, pan/balance and selected-output sends. A saved audible click must not restore to the native zero-route default. |
| Mode/relationships | Mode, primary track including `-1`, actual length frames, base/shared grid where applicable, Sync multiple/divisor, phase anchor/iteration where musically relevant, Song/Band active section, per-track Once. File length and clock length must agree. |
| Content/history | Stable track/lane IDs, immutable original/processed audio revisions, ordered per-pass edits, retained regions, grouped Clear/Bounce entries, valid redo branches, history bounds and missing-file references. |
| Mix and processing | Track/lane gain, pan or stereo balance, mute, solo set, whole-track FX bypass, input/part/track/all-tracks/output rack instances and chain identity/order/enables/Pre/Post placement. A processing cache is derived data, never the only surviving recording. |
| Transform state | Reverse, pitch amount plus its enabled/bypass state, whole-loop speed, fade default/per-track duration and settled envelope level, follow-tempo/preserve-pitch with original tempo metadata. Do not revive an in-flight wall-clock fade on load. |
| Media/performance | Backing prepared order, selected managed media, seek position/end policy/mix/sends; imported source identity, format and timing policy; session name/folder and generated content waveform references. Load stopped. Performance recorder's active file lifecycle remains independent. |
| Device-global state | Physical-device identity, MIDI global enable/channel/source mappings, external pedal type/calibration/source assignments, display/network/update settings, input/output hardware aliases and capacity. Session recall cannot restore an obsolete physical device or transient held contact. Rack-specific control bindings refer to stable session target identities; absent targets remain explicit. |

The prototype currently copies most of `rig` into session snapshots and excludes
only selected hardware fields. It still includes pedal settings, expression
configuration and MIDI configuration. That broad-copy policy must be reconciled
with the device-global contract above; it is not proof of intended ownership.
Existing production `pedalBindings` is already a session payload. Decide which
bindings are musical target associations and which describe physical sources,
then keep only one owner per field. Preserve already-approved source ownership;
this is a concrete remaining schema decision, not permission to silently move
settings between lifetimes.

## Dependency-ordered implementation slices

Each slice must leave a runnable instrument and have its own issue/PR gate under
the existing roadmap. Remove replaced paths in the same slice. No migration or
fallback layer is required for obsolete prototype/session representations; reject
unsupported bundle versions clearly before any live mutation.

### 1. Canonical musical state and staged session commit

Files: `packages/session_repository/lib/src/models/session.dart`,
`packages/looper_repository/lib/src/models/session_rig.dart`,
`lib/session/session_mapping.dart`, `lib/session/cubit/session_cubit.dart`,
`packages/looper_repository/lib/src/looper_repository.dart`,
`packages/segno_engine/lib/src/audio_engine.dart`, and native
`engine_session.c`, `engine_process.c`, `engine_snapshot.c`,
`engine_private.h`, `segno_engine_api.h`.

Add the grid/clock/empty-track fields above to the existing session/rig types.
Replace `commitSession(baseFrames)` with a validated complete staged-state commit
that represents shared or per-track clocks and `primary=-1`. Preserve the
existing layer import/retire ownership machinery where it fits; stage into an
isolated session allocation, not the live empty tracks. Reserve peak memory and
storage before clearing anything. Keep the old audio/metadata alive until one
callback-boundary commit acknowledges the new state; release retired resources
on the control/worker side. Queue-full, invalid PCM, missing asset, allocation
failure, cancellation or device loss leaves the old rig intact. Publish new
repository caches and session identity only after acknowledgement. Load all
tracks stopped, with explicit local positions, rather than inheriting the native
import's Playing state.

Tests: extend `test/session/session_mapping_test.dart`, existing layered/FX
round-trip tests, repository fake-engine failures and native session tests. Save
A at a nondefault signature/tempo/click/quantize/crown, mutate to B, load A, then
restart the engine; both live snapshots and caches must equal A. Repeat for all
five modes, empty uncrowned sessions, Sync divisions, absent FX and empty-track
overrides. Reject one bad last lane without clearing the seven valid current
tracks. Verify PCM hashes and audible first frames, not just enum equality.

### 2. One recorded-content history and atomic group recovery

Depends on slice 1's revision/commit representation. Files: native
`engine_commands.c`, `engine_process.c`, `engine_private.h`,
`layer_staging_ring.c`, `perf_log_ring.h`; `LooperRepository`; `ControlCubit`;
controller action models and session history serialization.

Use the existing per-track audio-layer stacks as the foundation. Add typed content
edits for capture, clear, retained-region/length, Peel and rendered replacement.
An entry holds the affected revision references and only the state changed by
that edit. A group ID references every affected track's same Clear/Bounce event.
Undo a group only when it is the next eligible entry on every affected track;
otherwise expose “Undo newer edits first.” Redo is cleared by a new content edit
on an affected track; mix/FX/selection changes do not clear it. Remove the partial
`undoClearAll()` scan and the separate feature histories once routed here.

For active overdub Undo, close the partial pass through the existing fade/drain
path, freeze the before/after audio including decay, then undo once. Preserve
completed earlier passes. Initial-take Undo preserves a nonzero captured take in
Redo and leaves the track empty; Redo starts that take immediately as a loop.
For Multi with an established cycle, preserve that cycle's length and the take's
recorded region; unwritten regions play silence. Do not use captured sample count
as the loop length, repeat or stretch the take, or require a mode-change dialog.
Recovery before the defining cycle exists remains a separate timing decision.
Avoid an extra empty pass at an exact wrap. Pending-arm cancel and zero-sample
capture must produce explicit no-audio outcomes, without invented redo audio.

The [active Clear All prototype](../design/2026-09-08-capture-recovery-ux.md)
now freezes nonempty partial audio, cancels pending arms and publishes one
recoverable group. Undo restores completed transport states and formerly
capturing tracks as stopped/playable; canceled arms stay idle. A failed write
preserves live content, captures, queues and history. This is a demonstrated
proposal for review, not blanket acceptance of native timing or durability.
Native publication must reserve recovery resources before clearing. Musical
phase restoration never rewinds wall-clock time or restarts capture.

Tests: record, overdub twice, partial overdub, Undo/Redo; initial take canceled
then Redo-to-play; overdub→Divide→Undo→Undo; Peel→Multiply→Undo→Undo; Clear All
with mixed playing/stopped tracks, then change a fader and Undo; group conflict
on one affected track; pool exhaustion and command-ring pressure. Check all
lanes' PCM, decay and revision identities. Add performance-log replay comparisons
for the same capture/edit event sequence.

Include a four-bar Multi primary and a secondary take canceled after one bar:
Redo preserves the four-bar duration, original audio placement and silent
unwritten regions while the primary continues without phase or transport reset.

### 3. Mode-relative clocks, first-take inference and Once

Depends on slice 1; slice 2 supplies capture cancellation semantics. Files:
`loop_clock.c`, `tempo_grid.c`, `engine_process.c`, `engine_commands.c`,
`TempoControl`/`LooperModeControl`, repository mode commands and the owning Loop
Bloc/Cubit. Remove the destructive “clear then switch mode” path in
`lib/looper/view/looper_mode_change.dart` after compatible-only switching works.

| Mode | Concrete target and test |
|---|---|
| Multi | One shared length. Later tracks close at the same length; accepted explicit length transform must retain compatibility or be refused before mutation. Play all eight without drift. |
| Sync | Explicit primary, equal/integer-multiple/permitted-division relationships and primary-relative phase. A new track ends on a legal boundary and its restored divisor actually changes playback, not just the readout. |
| Song | One selected section plays at a time, with independent section lengths and no shared-clock requirement. Starting section B ends A's feed at the defined transition; downstream tails may continue. The current native Free-equivalent behavior must change. |
| Band | The primary bed remains while at most one nonprimary section plays. Sections obey the accepted primary relationship/quantization. Changing section must not stop/restart the bed or double-trigger its first frame. |
| Free | Independent actual frame lengths, positions and starts. No hidden shared base is created during record, import, load, Undo or clear. |

Implement a pure compatibility decision over actual musical relationships;
commit it only while stopped and with no pending capture. Equal lengths permit
Multi. Sync/Band need a valid primary and exact supported ratios; do not silently
trim/stretch audio to fit. Song/Free retain their independent durations. Keep
audio and history on compatible conversion and refuse incompatible conversion
with the same reason from touch, MIDI and foot.

Reconcile first-take behavior with the guide's four-cell matrix: Auto+click-off
infers tempo and bars; Auto+click-on preserves tempo and infers bars; fixed
bars+click-off infers tempo from the ended take; fixed bars+click-on closes at
the known bar count. Preserve accepted Record→Play/Overdub rather than blindly
copying the guide's “starts overdubbing” wording. Verify the native existing
inference implementation before changing it. MIDI receive owns timing, so its
fixed-length/quantize rules must be explicit. Count-in before playback/overdub
is not settled by the first-recording-only mock; decide the intended scope and
then test every entry path. Fine tempo values retain hundredths without rounding
away a received/derived tempo.

Once stops each track after its own complete cycle in every mode, including
reverse, Sync multiples/divisions and imported material; it does not stop the
primary bed when a Band section finishes. Use frame-boundary assertions with
nonzero sample markers and event-log replay.

### 4. Mix buses, printed Pre, Post/output tails and meters

Depends on slice 1 and the FX descriptor/processor plan. Files:
`engine_process.c`, `engine_fx.c`, `engine_cache.c`, `engine_snapshot.c`,
`track_effect.dart`, `FxAddress`/chain models, routing and monitor repositories.

Retain lane/source identity and chain slot IDs. Define the canonical graph:
conditioned input → independent live/record branches; retained original and
prepared Pre representation → loop player → part/track Post → all-tracks bus;
then sum every source routed to each output (tracks, live monitors, backing,
click) → that output's FX → output gain/limiter/meter. A source routed to another
output must never enter this output's effects. Master/all-tracks remains a
recorded-only bus, distinct from final output processing.

Pre edits prepare a replacement representation from originals on a worker and
swap at a safe boundary. Keep the previous audible sound until preparation
succeeds. Post processing continues on silence after Stop; its tail must reach
the output even when every source lane is stopped. Mute, FX bypass, Clear and
all-sound cut each need a specified tail policy rather than sharing a flush.
Live monitoring remains independently audible. Capture inherited input Pre/Post
recipes once per new lane and preserve their stable independent identities;
later input edits must not alter recorded takes or apply printed audio twice.

Add the solo set without destroying mute/gain. Add mono pan versus stereo balance,
per-output gains, click/backing gains/pan and whole-track FX bypass. Mixer reset
changes only its promised gain/pan fields. Publish independent L/R meters and
peak state with bounded snapshot transfer; the two displays observe one state.

Tests use an impulse/sine through known delay/reverb: Pre stops with the player;
Post decays after Stop; output reverb contains simultaneous live+recorded+click+
backing inputs, excludes unrouted sources, and is applied once. Test stereo
routing/pan/balance, solo/mute combinations, default bypass, reset and clip/peak
indication. Real latency, noise floor and hardware headroom remain bench gates.

### 5. Per-track decay and playback transformations

Depends on slices 2–4. Thread typed track parameters through engine snapshots,
repository restart caches, session state and shared mapping descriptors.
Translate decay to feedback once (`keep = 1 - decay / 100`). Decay applies once
per completed or partial overdub pass to the prior audio; ordinary playback does
not decay. Undo restores the pre-pass samples and previous decay outcome.

Implement reverse read direction with continuous position and declicking; fade
as a sample-clock envelope separate from saved gain and mute; and speed/pitch
using retained originals. Define composition explicitly: whole-loop speed is a
varispeed factor; follow-tempo contributes an independent tempo ratio; preserve
pitch compensates the tempo factor; recorded transposition contributes its own
semitone factor. Add pitch bypass preserving stored amounts instead of erasing
values. Do not accidentally apply global Speed again to a rendered bounce.

Reuse the vendored Signalsmith benchmark and existing `#263` stretch programme.
The dated 1.1.0 benchmark measured a desktop host at 480-frame blocks and reported
about 100 ms cheaper-preset algorithm latency; it is not appliance proof or a
promise of quality at every ½×–8× speed. Configure all FFT/buffers off callback,
account for its latency in scheduling/capture/meters, and measure the actual
maximum lane/FX load on the appliance. The reference's pitch-preserving stretch
range is ½×–2×; the accepted 4×/8× Speed choices are varispeed and do not authorize
an untested pitch-preserving range. Use the dependency's documented input/output
latency and flushing behavior rather than compensating by visual offset alone.

Multiply/Divide must alter retained content/region and length metadata together
across all lanes, preserve originals, and create one history step. Existing
record-length presets are not a replacement. Group transforms preflight every
member so a limit or capture failure cannot partially change a selected set.

Tests: per-track independent decay, canceled partial passes, empty/base protection,
reverse wrap, fade interrupt/reverse without level jumps, all-track mixed fade
states, pitch limits/bypass, speed ratios and repeat→divide recovery. Pitch/tempo
checks measure rendered frequency, duration and phase; listening covers attacks,
voices, sustained chords and long tails. State tests alone are insufficient.

### 6. Managed audio import and independent backing playback

Depends on slices 1, 3 and 4; tempo-fitting import depends on slice 5. Reuse the
existing WAV codec/engine conversion utilities for the supported PCM baseline.
Verify the chosen decoder's actual supported types before advertising compressed
formats. Decode/resample, derive channel layout and extract per-file waveform on
a worker. Import from USB into managed internal media with checksum/size/capacity
validation; publish the file and catalogue reference together. Cancel/remove
storage without an orphan live track or half-file.

The empty-track destination survives browsing. The final import commit applies
actual frames, per-lane audio, label, initial history, original tempo and the
selected timing policy together. “Original timing” and “Fit to loop” must be
musically different; fit either produces a verified processed representation or
remains unavailable with a truthful reason. Tempo estimation is optional metadata,
not a fabricated result inferred solely from filename or duration.

Add an independent backing decoder/player using bounded streaming buffers.
Play/pause/stop, ±10-second seek, previous/next, Repeat/Next at EOF, unload and
prepared-order edits use stable managed-media identities. Previous/next loads
stopped; seeking preserves play/pause and clamps safely. Backing gain/pan/sends
use the shared mix model. Audition is a separate owned stream with defined stop
and route behavior. Capturing backing into a performance must use the chosen
recording tap, not a second uncontrolled file player.

Tests: sample-rate conversion duration/pitch, mono/stereo mapping, exact seek at
start/EOF, missing/corrupt media, USB loss during copy and during internal-copy
playback, cancellation/storage full, simultaneous loop/backing/preview priority,
reopen/restore and waveform-to-seek alignment. Physical storage throughput and
audio underruns are device gates.

### 7. Bounce, session mixdown, performance capture and export

Depends on slices 1–6 and processor capability resolution. Extend the existing
worker render infrastructure around the same graph/snapshot contracts used for
live sound. The render input is an immutable set of audio revisions, transforms,
FX descriptors/state, sends, tempo policy and explicit duration/tail policy.
Revalidate source revisions at commit; if they changed, discard/retry the result
without replacing current audio. Worker cancellation and disk/memory failures
must leave destination/sources/history untouched.

Resolve the remaining render policies before publishing a “complete” Bounce:

- For aligned musical loops, a bounded common-cycle render can use exact musical
  lengths. Free/Song, Once, mixed follow-tempo settings and unequal phases need
  an explicit selected duration/phase rule. Do not use unbounded sample-count LCM.
- Keep sources creates a stopped neutral destination; Clear sources preserves
  the accepted start behavior and forms one group with destination replacement.
  Selective source mute/transport inclusion, source mix and track processing must
  follow one declared recipe; the current prototype's “render regardless of
  transport/mute” recipe is an implementation proposal, not sonic approval.
- Cut tails ends at the boundary with an appropriate declick. Wrap requires a
  defined warm-up/convergence and folding method, tail budget, clipping policy,
  nonlinear/stateful processor treatment and cancellation bound. An infinitely
  ringing processor cannot make the job unbounded.
- Dry stems, audible session mix, and performance capture are distinct products.
  The selected export must match its stated tap and include the correct monitor,
  backing, click, output FX and limiter behavior. Hosted processors may not
  silently render as dry passthrough while being called equivalent.

Files: `perf_render.c`, `perf_drain.c`, session/performance repositories,
`packages/daw_export`, audio import commit and history contracts. Remove the raw
LCM mixdown as the implementation of an “audible mix” once graph rendering owns
that action; retain a clearly named dry-stem operation if it has product use.

Tests compare live captured PCM and offline replay for known deterministic
processors and every new transform/history event. Include pre-arm sustained FX,
render source revision race, mixed duration/phase, active recording refusal,
Replace/Keep/Clear recovery, long-tail cancellation, saturated output and USB
export verification. File existence or a completed progress bar is not enough.

### 8. Library preservation, backup and performance-facing integration

Depends on slices 1, 2 and 6; wet previews/exports depend on 7. Integrate the
accepted Library ownership rather than introducing another Save screen.
Scratch/autosave, named copy, duplicate/delete/rename/folders, select versus load,
content-derived preview and foot Save/previous/next all call the same transactional
repository methods. A failed save/load preserves the current playable session
and gives foot-operable Retry/Cancel/Exit feedback. Save succeeds only after
media and metadata are durable; reboot/power-loss recovery uses complete bundles.

Whole-session backup includes every managed dependency and processing/source
schema. Complete appliance backup additionally includes the explicitly selected
device-global settings; it is not a session with a larger filename. Validate
archive paths, versions, checksums and available space before publication; reject
unsupported schemas before replacing anything. Do not restore device identities
or hardware capabilities blindly from another appliance.

Final controller integration uses the shared direct catalogue and typed targets
already exercised in the prototype: fixed/selected/all actions, global MIDI enable,
Omni, exact-device Learn, held release on loss and per-source ownership. Hardware
mode pages use ten pedals/eight tracks/eight FX assignments with fixed foot Exit.
No production action is enabled solely because its prototype name exists.

## Remaining decisions and device gates

The accepted behavior above stays fixed. These unresolved details are specific
implementation inputs, and must not be silently reclassified as accepted differences:

- Clear All during partial capture/queued recording: frozen audio, pending-arm
  restoration and exact safe phase policy, while preserving whole-loop recovery.
- Group history capacity, durability across reload/power loss, and deterministic
  eviction/refusal when pool/storage cannot preserve the promised recoverable
  operation. Existing clear can degrade under pool exhaustion; decide truthful
  feedback instead of displaying an unconditional Undo promise.
- Exact permitted Sync/Band divisions and conversion behavior for independently
  timed material; count-in playback/overdub scope; interplay of sound start and
  external clock. The supplied guide is evidence, not an internally complete
  timing specification.
- Device-global source bindings versus session-specific target associations;
  imported-content history root/replacement policy and session-load phase reset.
- Bounce free-time/Once duration, source mute/solo inclusion, tail wrapping and
  hosted-processor capability. FX descriptors must not invent native scales.
- Algorithm latency, pitch-preserving ratio/quality envelope and maximum
  simultaneous lane/FX/output load on the real appliance.
- Physical stereo routing, independent Phones, output groups and USB-device
  capability are appliance decisions. A generic output fader or desktop launch
  cannot close those rows.

## Required removals

- Remove the obsolete content-clearing mode-switch workflow once compatible
  conversion is shipped; keep one mode mutation owner.
- Replace the base-only session commit and clear-before-import application path;
  do not leave a fallback that silently drops Free/Song clocks or musical fields.
- Replace partial `undoClearAll` scanning and isolated feature histories with
  ordered per-track/group recovery; do not keep a second special keyboard path.
- Consolidate legacy loop-top quantize/track multiples and the accepted
  subdivision/length defaults/overrides into one explicit musical contract.
- Replace dry-only/frozen-input-chain semantics where they contradict printed
  Pre/Post/output placement. Preserve reusable identities, chain enables and
  original media, not obsolete ownership assumptions.
- Remove duplicate old/new Settings, Library and control dispatch surfaces as
  each accepted owner becomes complete. The existing cleanup audit enumerates
  their paths; no compatibility UI or migration scaffolding is required.

## Success Criteria

These are the future implementation gate, not results of writing this plan.
Extend the named existing suites with the scenarios above before using them as
evidence. `flutter` means the working SDK command documented in PROGRESS; source
directories must be explicit and dependencies resolved in a fresh checkout.

```success-criteria
GOAL: Every accepted audio/state action sounds, restores and fails coherently through one repository/engine contract on the appliance.

SUCCESS CRITERIA:
- All five modes round-trip actual audio clocks, grid, crown/un-crown, empty-track overrides and FX, and rejected/canceled loads preserve the prior rig | verify: flutter test test/session
- Interleaved recording/partial passes/Peel/length edits and grouped Clear/Bounce recover exact content and changed musical state without undoing later mixer settings | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- One-shot, decay, mode transitions, pan/solo, Pre/Post/output-tail behavior and offline replay meet sample-level scenarios in this plan | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- Native ownership remains correct under sanitizer and disabled telemetry builds | verify: EXTRA_CFLAGS="-fsanitize=address -g" bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS="-DLE_CALLBACK_TELEMETRY=0" bash packages/segno_engine/src/test/run_native_tests.sh
- Controllers and media/library paths preserve error/reconnect/persistence behavior and required package coverage | verify: manual Run every affected root/package CI test job and preserve its configured coverage floor; inspect that Bloc lint scanned lib, test and packages
- Eight tracks and configured lanes/FX remain within measured callback budget, with verified latency, no stuck held actions, and audible Pre/Post/backing/click/output behavior | verify: manual 1. Run the instrumented appliance workload and physical MIDI/USB reconnect matrix. 2. Capture calibrated audio and compare render/live outputs. 3. Listen to the transform/tail corpus and record accepted limits. 4. Reboot and restore saved sessions in all five modes.

NON-GOALS:
- Replacing the existing engine or changing accepted UI layout and pedal defaults
- Claiming Looper X sonic equivalence from family names, normalized preset numbers or screenshots
- Adding backward compatibility, schema migrations or a second settings/history owner

VERIFICATION COMMAND: flutter test test/session && bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS="-fsanitize=address -g" bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS="-DLE_CALLBACK_TELEMETRY=0" bash packages/segno_engine/src/test/run_native_tests.sh
```

Every production slice also runs the applicable analyzer, explicit-path formatter,
`bloc lint lib test packages`, affected package tests and CI coverage. Current
floors include root 90%, looper repository 95%, session repository 89%, performance
repository 99%, pedal repository 96%, controller repository 82%, and DAW export
100%; verify them against the current workflow before implementation. API changes
regenerate FFI bindings, run symbol parity and the C++ shim check from PROGRESS.
Pedal/codec changes require both firmware trees' test runner. Complete current-head
code review and the established CI/autonomy gates remain required before shipping.

## Related source and decisions

- [Recheck feature ledger](../research/segno-looper-x-comparison/2026-09-08-recheck/features.tsv)
  and [engine audit](../research/segno-looper-x-comparison/engine-audit.md).
- [Accepted Undo/Redo decisions](../brainstorm/2026-09-07-undo-redo-brainstorm-doc.md),
  [Bounce contract](../design/2026-09-07-bounce-performance-ux.md),
  [FX placement/ownership direction](../design/2026-09-06-fx-ux-design.md), and
  [mapping parity correction](../design/2026-09-08-mapping-parity-correction.md).
- [Existing stretch spike](2026-07-22-time-stretch-spike-findings.md) and the
  vendored dependency README under `packages/segno_engine/src/test/bench`.
  The dated desktop GO result is engineering input, not an appliance conclusion.
- [Appliance roadmap](../roadmap/README.md) owns execution order and tracking;
  this plan supplies the audio/state implementation contract for its existing
  delivery slices.
