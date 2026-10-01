# Segno accepted product behavior

Implementation handoff · 9 September 2026 · Appliance UX programme, issue 919.

This is the product contract distilled from the owner's accepted iterations,
the latest design records and the current integrated prototype. It specifies
what the application must do; it does not certify that native audio, hardware or
durable storage already does it. The HTML is an executable interaction reference,
not an architecture to port literally.

## Authority and priorities

- The latest explicit owner correction wins over an older proposal, roadmap,
  source comment or existing application limitation. September 7–8 documents
  sometimes still say “proposal”, “separate history” or “not implemented” after
  a later accepted integration replaced that state. In particular, the accepted
  completion pass settles tails, rendering, direct USB recording, extended MIDI,
  touch lock and optional double-press Solo. Do not reopen those choices.
- Preserve the accepted Tracks view and the accepted FX editor. The goal is an
  instrument with clear musical consequences, not a collection of generic
  settings forms. Keep compact diagrams/artwork where useful; avoid oversized
  cards with little information, crowded explanatory dialogs and duplicate text.
- State ownership must be consistent across touch, encoder, built-in pedals,
  external switches, expression and MIDI. An editor selection is not permission
  to retarget a controller, change playback, load a file or commit a draft.
- A performance function entered by foot must be operable and escapable by foot.
  Setup may use touch/encoder; performing must not require reaching for the screen.
- Match Segno's ten-pedal faceplate, not Looper X's eight-pedal arrangement. Front,
  left to right: Record/Play, Stop, Undo, Mode, Track 1, Track 2, Track 3, Track 4.
  Clear is raised behind Undo; Bank is raised behind Mode. All ten have LEDs.
- Ship real behavior, measured state and honest failures. Do not put fixture
  devices, fake meters/waveforms, simulated successful saves, placeholder sound
  packs, guessed effect controls or browser-test controls in production. Unknown
  capability must stay unknown or unavailable with a useful reason.
- Keep each implementation slice working end to end. Retire obsolete paths when
  their replacement works; do not preserve duplicate editors, state stores or
  compatibility layers simply because the prototype accumulated them.

Sources:
`AGENTS.md`; `docs/design/fx-ux-prototype.html`;
`docs/design/2026-09-09-non-production-completion.md`;
`hardware/enclosure/segno_enclosure.py`;
`docs/design/2026-09-09-remaining-design-gates.md`.

## 1. Main view, two screens and interaction grammar

1. Normal startup/reload opens Tracks, with the saved setup retained and transport
   stopped. Review URLs are isolated demonstration fixtures, never startup policy.
   Library and Settings are reachable from the main header by named accessible
   icons. Track/Wave/Mixer choices live behind the header's view icon, not large
   permanent tabs within the track area.
2. The main display shows four tall track columns: A is 1–4, B is 5–8. Changing
   bank reveals the other four; it does not start/stop audio or silently move the
   selected track. Selection changes the editor/close-up, independently of bank
   and playback. The smaller display, physically left, follows the selected
   track's waveform, name, phrase length and position, including while main-screen
   settings or FX are open. Do not invent a second independent selection.
3. Tracks shows one full-width whole-track level, not split left/right bars.
   Wave shows continuous sample-derived waveforms with actual empty/silent
   regions, not decorative blocks. Mixer keeps stereo detail and its gain marker
   integrated over the stereo meter. All views share the same music and mix state.
4. Musical color is meaningful: playback green, recording/overdub red in the
   accepted Segno treatment, stopped/muted content pale, empty dark. Selection
   has a distinct light outline. Encoder focus is a separate amber outline.
   Retain bars and layers with explicit spacing, an active/bypassed/absent FX
   indication, and a thin bottom progress bar. Shared side dB scales and output
   clipping feedback replace per-track numeric dBFS. No per-track BPM or routine
   Playing/Empty/Recording captions at the bottom. A queued action appears
   centrally, with its action and boundary, and is not focusable.
5. Header/footer convey session name, compact CPU/clock status, BPM, signature,
   elapsed time since first recording and loop mode. These readouts must use real
   owners in production. A crown beside the name marks the first completed
   recording; later selection or a lower-numbered recording does not move it.
   Explicit timing handoff moves it. Empty sessions have none. Track, Wave,
   Mixer and the selected-track display agree; the crown is not an input control.
6. Visual Mixer exposes Mute, multiple simultaneous Solo choices, clear Solo,
   separate FX edit and track-FX bypass controls, pan, stereo peaks/clipping and
   level in dB. Double tap returns pan to centre and gain to unity. Reset mixer
   resets all eight tracks' levels and pan only, preserving mute, Solo, FX and
   audio. Backing & click opens their shared auxiliary level/pan controls.
7. Use the accepted near-black/blue-gray surfaces, light text, blue choices and
   primary actions, and amber only for focus/warnings. Musical-state and custom
   LED colors remain semantic exceptions. Settings retains ten direct illustrated
   destinations; the rejected five-group restructuring must not return. Use the
   custom Segno artwork and established filled sliders, shared typography,
   consistent horizontal padding and readable full-size geometry.
8. A slider double tap resets its meaningful default; no redundant Default
   button. Encoder press enters a draft, turn adjusts, press commits and Back
   cancels. Changing target/editor cancels unfinished edits; unrelated saves do
   not commit them. Focus scrolls into view, stays inside unclipped bounds, is
   trapped in the active dialog and returns to the opener. Fixed/readout controls
   never enter focus. Rename/password entry uses a fixed bottom keyboard sheet:
   no scrolling, outside-tap dismissal or drag dismissal; explicit Done/Cancel.
   Empty or whitespace names display Track N, Input N or Output N without changing
   identity. FX parameter overflow uses a constantly visible, separated scrollbar,
   not the superseded floating arrows.

Sources:
`docs/design/stage-display-study.js`;
`docs/design/2026-09-07-stage-display-roles-ux.md`;
`docs/design/2026-09-09-primary-crown.md`;
`docs/design/2026-09-08-design-consistency-review.md`;
`docs/design/virtual-instruments.css`.

## 2. Loops, timing and audio-edit history

1. Five modes remain: Multi shares one loop span; Sync allows integer multiples
   or divisions of a primary cycle; Song plays one independent section at a
   time; Band keeps its rhythm/primary beneath changing sections; Free permits
   independent loops. Preserve all eight tracks and their original material.
2. Loop settings uses compact mode cards with small diagrams and one shared
   Tracks / Defaults / 1–8 selector for field-level settings. A custom value equal
   to the default remains Custom. Use default removes only that field's override.
   In Multi, length comes from the shared default; independent length overrides
   remain stored but inactive. Changing future-recording length never resizes a take.
3. Record/Play operates the selected track. The second-press choice determines
   Record → Play → Overdub or Record → Overdub → Play, including automatic fixed
   completion. Start is Pedal or Sound; Sound requires arming then a signal from
   a chosen recording source. No selected source yields a repair reason rather
   than an invented input. Count-in and Sound arming are mutually exclusive.
4. Keep Tempo, time signature, click behavior and count-in together. Tempo has
   whole-BPM and 0.01-BPM adjustment. Count-in is Off/1/2/4 bars, shared for a
   simultaneous launch from stopped, and canceled by Stop. Adding while music
   runs uses the chosen grid. External clock adds no extra local count-in.
   Quantization choices are Immediately, Loop start, bar, half, quarter, eighth
   and sixteenth note, with per-track ownership. A queued action belongs to its
   track; selection cannot move it. Repeating/canceling the request or Stop
   clears the corresponding queue and its cue.
5. Loop/Once and overdub Decay are independently inherited per track in all five
   modes. Once finishes the current pass and stops that track, not the other
   tracks or shared clock. Decay 0 preserves earlier layers; each overdub pass
   retains `1 − decay/100` of existing audio before adding the new layer at full
   recorded level. Decay 100 replaces earlier audio, including with silence.
   Ordinary playback does not decay. Preserve layer recovery, not only a mixed file.
6. Audio & tempo independently owns Follow tempo and pitch preservation. Following
   On changes playback with song tempo and offers Unchanged pitch or Follows speed.
   Following Off preserves original-time playback and shows unchanged pitch; the
   stored pitch-follow preference returns when reenabled. Manual Speed and
   Transpose are independent contributions, not resets of these preferences.
7. Loop span and recorded material are separate. One bar recorded inside a
   four-bar Multi loop stays at its actual position, with three silent bars.
   Redo restores that sparse material and shared phase while other tracks keep
   playing. Never repeat it four times, resize it or switch the session to Free.
   Preserve captured seconds separately from musical beats and wrapped regions.
8. Sync/Band capture follows a musical primary cycle independent of that track's
   audible Speed, Reverse, Once or Follow setting. A late Auto start may create
   leading silence; finish queues the end of a whole primary cycle. A source's
   Once stop does not abort that capture cycle. An optional first-Auto-take tempo
   estimate with click off/internal clock preserves measured seconds; the later
   half/current/double bar review is optional, recoverable and never interrupts
   the performer at completion.
9. Mode changes use existing cards and actual established spans. Stopped compatible
   changes apply directly. Playing changes require Stop loops and switch; Cancel
   keeps everything. Capture/queues block commit. Multi requires equal spans;
   Sync/Band require integer primary relationships; Song/Free retain independent
   spans. No implicit trim, repetition, stretch or deletion makes a mode fit.
   Configuration changes stay outside audio Undo. Timing-source handoff has the
   same stopped/explicit-stop boundary; clearing a Sync/Band primary with other
   audio requires a compatible successor. Clearing the last take clears primary.
10. One audio-edit history per track includes recording, each overdub pass, length
    edits, Peel and Clear. Undo during overdub removes the in-progress layer and
    returns to playback; Redo can recover it. Undo may remove the original take
    and leave empty; Redo of a recovered first take plays immediately. Peel
    removes only the newest overdub and protects the original. A new audio edit
    retires its Redo branch. Mixer/FX configuration changes stay outside this
    history and survive audio recovery. Do not ship separate per-tool histories.
11. Clear All and Bounce are grouped edits: one Undo restores every touched track,
    its content/length/layers and the applicable previous playing/stopped states.
    Captures interrupted by Clear All return as stopped recoverable material,
    never a resumed microphone capture; canceled arms stay idle. Newer dependent
    audio edits must be undone before an older group, rather than overwritten.
    Audio, history and relevant timing metadata publish together.
12. Failed capture publication freezes the measured take and offers Save held
    take/Stop retry; Undo retains exact Redo material. Do not continue accruing
    fake time, rearm, or allow New Loop/recall/restart/restore to discard it.
    Clock loss closes measured partial material and cancels queued starts;
    playback obeys the chosen keep/stop policy. Unavailable audio blocks audible
    recovery. Cut all sound must still silence even when saving fails.

Sources:
`docs/design/loop-ux-study.js`;
`docs/design/stage-transport-study.js`;
`docs/design/2026-09-08-capture-recovery-ux.md`;
`docs/design/2026-09-09-timing-completion.md`;
`docs/design/2026-09-07-loop-mode-transitions-ux.md`.

## 3. FX, channel processing and routing

1. FX has Live inputs, Recorded tracks and Outputs. Preserve individual recorded
   input parts and the All tracks recorded-mix destination. All tracks is not
   the output bus. Output FX process every source actually routed there,
   including live inputs, loops, backing and click.
2. A rack is an editable horizontal pedal chain with plain connecting lines,
   no arrows; single effects use their own direct editor. Module power belongs
   to the title/power button only, with a visually clear active/bypassed card.
   Do not recreate the duplicate Off/On parameter row. Keep per-pedal parameter
   scrolling, separated persistent scrollbars and horizontal chain scrolling.
3. Add effects preserves the full rack/single catalogue. Ed's Rack receives the
   accepted wide artwork treatment; My presets has matching original artwork.
   Adding returns to the intended input/track and opens the effect directly.
   New instances are independent and initially bypassed. Reorder can be canceled.
   Save preset asks for a name; recall creates an independent instance. Replacing
   a preset never rewrites already instantiated copies.
4. Pre/Post is a direct switch for live inputs and individual recorded tracks or
   parts: “Recorded into loop” / “Can ring after Stop.” Outputs and All tracks
   omit it because their stage is fixed. Inputs default Pre; recorded destinations
   default Post. Placement is not part of the reusable sound preset. Reorder
   stays within a stage; explicit placement moves the instance to the destination
   stage's end without losing identity, channels, parameters or assignments.
5. Pre becomes part of the take's playable representation; preserve dry originals
   and recoverable edit state. Live-input edits change live sound/future takes,
   not old takes. Recorded Pre edits prepare a replacement from originals and
   keep the working sound until it succeeds; never process the old wet audio again.
   Post processes downstream playback, and ordinary Stop lets its existing tail
   finish. Live monitoring remains an independent source.
6. Accepted tail distinctions: Stop/Clear stop new recorded feed but drain Post
   and output tails; Mute gates that track while its player continues and already
   mixed shared tails drain; bypass sends new audio dry and drains old wet tails.
   Cut all sound immediately stops audible sources and clears existing tails.
   Printed Pre stops with its recording. Do not implement every action as the
   same transport stop or blanket FX flush.
7. Rack input choices preserve stereo or select left/right/mono; rack output
   preserves stereo with Balance or averages to Mono with Pan, then applies rack
   level. Track Mono averages recorded stereo before downstream track processing;
   source channels stay recoverable. Keep part, track, rack and output controls
   distinct, all sharing actual targets with other control surfaces.
8. Recording inputs chooses sources per track and locks affected sources while
   armed/capturing. Instruments appear alongside physical inputs. Physical stereo
   pairs retain ordered left/right identities; choosing either includes both.
   Pair/unpair preserves routes and recordings. Use reported stereo grouping,
   not guessed adjacency when repairing a different interface. Mono Pan/stereo
   Balance affect live input and future capture; unlink restores prior mono pans.
9. Recording trim is capture gain, independent from analog preamp and live Mixer
   level. Lower software trim cannot repair clipped source audio. Hear live is
   Off/Auto/On; Auto follows armed/capturing tracks using that source. Input Mixer
   mute is an additional gate, not an edit to that preference. Output routing
   alone does not open monitoring or start playback. Explain no route, Auto-off
   and Mixer mute rather than presenting a working-but-silent control.
10. Output setup has independent level, mute, Stereo/Mono and Balance per output
    destination. Mute retains level. Mono sends the same averaged mix to both
    jacks and disables Balance; Stereo restores the retained balance. Renames
    preserve identities, routes and mappings and remain appliance aliases.
11. Bounce and Save selected audio share a finite common-cycle/chosen-length
    rendering recipe. Include selected recorded material regardless of stopped,
    mute or Solo status, its levels and runnable Post processing; do not reapply
    printed Pre. All tracks FX is optional. Live inputs, backing, click and output
    FX are excluded. Once contributes once then silence. Wrap/Cut controls the
    render boundary. The result resets destination processing so it is not printed
    twice. USB export copies a finished file; it does not rerender the session.
12. Try preset temporarily auditions a compatible same-family/control-layout
    preset while preserving IDs, bypass, placement, routing and assignments.
    Keep commits; Cancel, navigation or starting capture restores the exact
    baseline. Failure keeps trial and baseline available. Unrelated saves do not
    persist audition values. Different layouts explain why they cannot be tried.
13. Exact Looper X racks, constituent effects and parameter sets are mandatory;
    sound may differ. Preserve all recovered parameter keys, including the twenty
    entries formerly filtered by name. Unverified source scales/preset values are
    evidence, not permission to claim factory defaults or invent a generic schema.

Sources:
`docs/design/2026-09-06-fx-ux-design.md`;
`docs/design/audio-routing-study.js`;
`docs/design/selected-render-policy.js`;
`docs/design/2026-09-09-non-production-completion.md`;
`docs/design/2026-09-09-fx-reference-completion.md`.

## 4. Built-in, custom, external, expression and MIDI controls

1. Pedals lives in Settings alongside Loop settings. Layout A is the sole accepted
   setup layout: hardware map remains visible while editing the chosen pedal's
   Press and Hold together. In Track controls, fixed Stop/Undo/Clear/Bank actions
   are dimmed and unavailable; the four track pedals edit as one group. Mode
   defaults to Mute on Press and Custom on Hold. Custom fixes Mode to Exit and
   Bank to paging; shared transport assignments do not duplicate across banks,
   while the four track positions have A/B assignments.
2. Save/Cancel applies to setup drafts. Clear custom assignments covers both banks
   and gestures, preserves fixed controls and LED colors, and offers Restore
   within the draft. Unrelated saves cannot apply unfinished assignments.
3. Press/Hold are separate actions. Holding a navigation/control pair must not
   first execute its short action or act again on release in the newly opened
   mode. Normal Record/Play and Stop retain their immediate contact behavior.
   Before a target-following hold fires, follow the newly selected track/current
   bank position; after it fires, release remains attached to that completed
   gesture. Resolve fixed targets by identity, never visible slot/name. Cancel
   pending gestures on invalidating navigation, disconnect or configuration.
4. LEDs represent function state: momentary lights only while active contact is
   held; toggle stays lit until toggled again. Color is configurable on all ten,
   including pedals with fixed actions. Custom colors can be added, edited and
   reused; changing color never resets active state. Selection feedback in setup
   must not masquerade as a saved performance latch.
5. Performance functions retain the same physical map and a foot Exit. Their
   musical meanings are fixed below; exact current pedal captions are in the
   shared performance module, not copied from Looper X hardware.

| Function | Accepted behavior |
| --- | --- |
| Mute | Stays on the normal track columns. Track pedals mute/unmute without stopping playback; Mode restores normal controls. |
| FX | Four visible logical assignments plus Bank for four more; stateful activation, clear current actions and Exit. |
| Transpose | Select tracks across banks; Undo/Clear lower/raise one semitone; hold either resets selection. Range ±12; timing unchanged. Global bypass preserves stored pitches and selection. Exit retains changes. |
| Mixer by foot | One channel at a time. Tracks controls loop playback level; Inputs controls live monitoring only. Track/channel hold mutes without losing level. Undo/Clear step level; hold resets unity. Bank pages four; hold Bank switches Tracks/Inputs. Eighteen-input paging is supported. |
| Reverse | Each track pedal immediately toggles direction at its current position. Speed/pitch stay unchanged; stopped stays stopped. LED shows reverse; a small normal-Tracks marker remains after Exit. |
| Fade | Tap a track fades out/in; tapping mid-fade reverses continuously. Hold selects its duration. Shared four-second default, optional per-track 0.5–30 second overrides. Undo/Clear adjust, holds restore inheritance; hold Bank selects Defaults. Saved Mixer level and transport remain separate; fades continue after Exit. |
| Speed | Whole recorded loop uses absolute ½×, 1×, 2×, 4× or 8×; speed couples pitch. Repeated 2× stays 2×. Normal restores only that factor. Live inputs/backing/click are unaffected. |
| Multiply / Divide | Separately assignable. One selected track: Double repeats its material; direct First half or Last half retains that region. No intermediate chooser. Pitch/speed unchanged; omitted material is recoverable through history. Reject incompatible mode lengths rather than alter other tracks. |
| Peel | Remove the latest overdub layer, preserve the original, disable if none remain, recover through audio history. |
| Bounce | Select sources across banks, then destination, then explicit Bounce/Replace & bounce. Keep/Clear sources and tail choice are visible; selection alone does nothing. One Undo restores the whole operation. |
| Backing | Select prepared recordings by foot without interrupting current playback, then Play/Pause, Stop, seek/jump, page and Exit. Exit does not stop backing. |
| Tuner | Select physical inputs by bank, mute only the selected live input/pair temporarily, adjust A4 420–460 Hz/reset 440, and Exit. Detector is before FX; tracks and capture stay independent. No signal clears the old reading. |
| New Loop / Record performance | Preserve-and-start-fresh and start/finish recording work directly by foot, including failure retry. |

6. External pedals configures CTRL 1/2 as Expression, Single or Dual switch using
   the accepted generic high-resolution artwork. Dual buttons have independent
   hit targets/actions; fixed Track 5/6 pedal actions work while built-ins remain
   on Bank A. Track N pedal selects and advances that track's Record/Play; Select
   track N only selects. These must be separate named actions.
7. Expression may target multiple controls with individual heel/toe values and
   reversed ranges. Calibration supports reversed wiring, is drafted until saved
   and does not dispatch while measuring. Targets are fixed by default; no implicit
   follow-selection. Saving/reconnecting waits for new movement rather than jumping.
   Stable effect/module/parameter identity survives reordering and renaming.
8. Each external button can map multiple controls, including effect activation
   and individual parameter values. Each mapping has On/Off or Held/Released
   semantics/endpoints. Momentary and physically latching hardware are explicit.
   External assignments are edited in External pedals only, not added back to
   FX Activation. Instrument note/chord and sustain actions use this same system.
9. MIDI Learn uses the selected device, channel 1–16 or All, explicit source
   identity, and multiple actions/parameters with independent ranges/pickup.
   Source overlap is rejected even when disabled; no name-based retargeting.
   Control enable pauses remote assignments while preserving them and releasing
   held contacts. Instrument note input is independent of Remote control enable.
   Reconnect requires fresh input; it never replays notes/latches.
10. Standard Note/CC/Program, 14-bit CC, NRPN, Bank+Program and relative CC are
     explicit Learn formats, not guessed from one byte. Continuous formats drive
     parameters; button/Program actions have explicit trigger semantics. Raw CC
     footprints conflict across formats on overlapping channels. Held instrument
     Press requires Hold=None; Held MIDI notes require momentary Note/CC on Press.
     Invalid combinations explain the conflict and cannot save.
11. Direct actions distinguish entering a view from changing audio. Selected,
     fixed and all-track scopes are explicit and resolved once. Shared targets
     cover mixer, FX, loop defaults/per-track fields, backing/click and instrument
     parameters. Clear All is one grouped edit, not eight Clear calls. Missing
     targets stay unavailable with Change control/Remove, never silently bind by
     matching labels. Repair reviews endpoints before applying the source draft.
12. Optional touch lock and double-press Solo start Off. Touch lock leaves pedals,
     MIDI and encoder working and has an explicit accessible unlock/hold gesture.
     Double Solo applies only to Tracks mode; Hold wins and never also solos.
     Treat prototype millisecond thresholds as explicit tested baselines to verify
     on hardware, not permission to remove the accepted gesture distinctions.

Sources:
`docs/design/pedal-action-catalogue.js`;
`docs/design/pedal-ux-study.js`;
`docs/design/pedal-performance-study.js`;
`docs/design/expression-ux-study.js`;
`docs/design/2026-09-09-optional-controls.md`.

## 5. Virtual instruments as independent inputs

1. Settings → Audio routing → Instruments edits sound, controllers and live
   monitoring. There is no separate instrument recorder. Add an instrument,
   choose its source in Recording inputs, then use normal Tracks Record/Play.
   Sound-armed recording responds to that source even with Hear live Off.
2. Instruments have persistent identities, their own voices/audio buses and
   fixed controller routes. Selecting a different editor does not redirect notes,
   release another instrument or change playback. Simultaneous instruments,
   channel splits and deliberate layers work. New instruments begin with their
   controller enables Off; example USB channels are not device defaults.
3. Played by independently enables MIDI and Computer keys. MIDI uses the shared
   device inventory, All/specific channel and optional range. Keyboard input
   retains incoming pitch/velocity across all 128 notes. Pads may have explicit
   remaps alongside normal keyboard notes. On-screen octave paging only changes
   the visible touch keyboard; it never restricts a 61-key controller.
4. Computer mappings are explicit editable/removable rows, including defaults.
   Computer and MIDI editors are separate. Learn the source and choose any note
   or chord by playing MIDI, numeric note entry or optional touch keyboard. Parent
   Cancel discards nested MIDI edits. Numeric/range fields support encoder entry.
5. Pedals & controls displays actual shared bindings and links to built-in,
   External and MIDI setup. Notes/chords, Sustain and family sound parameters
   are available through those shared target/action owners; no duplicate local
   pedal assignment editor. Parameter changes have the same range/default from
   touch, encoder, expression or MIDI.
6. Sustain supports Held and Latch and independent contributors. Released notes
   ring until all relevant sustain sources release; repeated strikes remain
   distinct voices. Explicit CC64 remapping must not also act as sustain. Pitch
   bend, modulation and channel pressure reach synthesis. Device loss/disable,
   mapping retirement and Cut all sound release the appropriate voices without
   affecting unrelated devices. Reconnect never resumes stale held notes.
7. The accepted catalogue is nineteen defined Segno synthesis patches in Keys,
   Organs, Synths, Bass, Strings, Drums and Percussion, with distinct art and three
   meaningful family parameters. It is not a three-instrument product limit or
   an assertion that sampled factory content is delivered. Temporary audition
   previews a candidate without changing the saved sound or unrelated instruments;
   Apply commits, Cancel restores. Unavailable sounds offer install/retry/another
   sound, and failure preserves the prior setup.
8. Display active notes, sustain, controller state and why live sound is silent
   (Hear live, Auto, Mixer mute, no output, missing sound or audio-start failure).
   A successful retry clears the failure. Sound parameter drafts remain audible
   through incoming MIDI/re-renders but stay out of unrelated saves.
9. Remove requires confirmation and is blocked during capture from that instrument.
   It removes the live instrument and future routes/FX while preserving already
   recorded loop audio/source labels. Last removal leaves Add instrument. Session
   recall restores definitions/mappings/routes; New Loop retains setup. Recovery
   never asks for a physical jack to reconnect an internal instrument.

Sources:
`docs/design/2026-09-09-instrument-ux-review.md`;
`docs/design/virtual-instruments.js`;
`docs/design/instrument-runtime.js`;
`docs/design/instrument-catalogue.js`;
`docs/design/2026-09-09-virtual-instruments-ux.md`.

## 6. Library, sessions, recording, storage and recovery

1. Library is reachable from Tracks, with Sessions and Audio. Selecting a session
   previews it; Open loads explicitly, preserves outgoing work and confirms any
   playback interruption. Restored transport starts stopped. New Loop automatically
   preserves the current session, clears recorded tracks/history and retains the
   useful sound/tempo/pedal/instrument setup. It resets track performance transforms
   such as mute/fade/reverse/transpose/global Speed; prepared backing remains stopped.
2. Automatic names make naming optional. Rename is metadata-only. Save/checkpoint,
   Save as and Duplicate have distinct identity semantics. Delete protects the
   current session and never destroys shared audio still referenced elsewhere.
   Search and one-level folders organize sessions/audio without loading anything.
   No artificial session-slot limit is implied by fixture lists.
3. Session preview shows only populated tracks, real waveform/length/layer/mute/FX
   information and explicit Listen. Audition does not load the session, is isolated
   from the live rig and ends on navigation or performance/capture. It is not an
   arrangement timeline. Missing waveform data is explicit, never borrowed audio.
4. Audio browses Internal/USB, selects, previews and prepares backing independently.
   Prepared order has numbered rows and Move Up/Down, including across pages.
   Selecting a different backing file leaves the current one playing until Play.
   Play loads selection or toggles pause; Stop rewinds; Exit preserves playback.
   Seek addresses the loaded file even when another is selected. End is Stop,
   Repeat or Next; Next stops after the last file, never wraps. Clear backing
   unloads its player but keeps the file and prepared list membership.
5. Ordinary USB import/prepare makes a managed internal copy, independent of drive
   removal. Import into an empty track carries that destination through browsing,
   preview and timing. Use file tempo, Adapt to loop tempo and Leave unchanged are
   explicit. Unknown tempo requires confirmed bars for tempo-dependent choices,
   never an invented BPM. External clock requires Adapt and usable clock. Final
   import checks source, destination, storage and clock together, preserves the
   original and starts the imported track stopped.
6. Save selected audio uses the shared render contract, not the performance
   recorder. Record performance captures everything routed to its output over
   elapsed time, independently from loop Stop/Undo/Clear. Internal or direct USB
   is chosen before Start. Final output volume/mute is excluded by default;
   Follow output volume explicitly changes that recording policy, frozen per take.
   Start/Stop is foot-accessible and the recording indicator persists elsewhere.
7. Long performances remain one Library item backed by ordered parts. The accepted
   prototype baseline is stereo 24-bit PCM at the applied rate, 2 GB parts, 1 GB
   reserve and a warning at 60 seconds remaining. Compute time from actual capacity
   and frozen format; unknown capacity cannot claim available time. Low space or
   slow writes stop at complete recorded frames and preserve recovery. Checkpoints,
   cancellation and discard must account for the real allocations exactly.
8. Export finished internal audio/presets to USB keeps the original and offers Keep
   both/Replace for conflict. Cancel, absent/wrong drive, insufficient space,
   invalid source and write errors preserve existing content. Session backup is
   a compact Library action; USB session entries restore independent copies.
   Complete appliance backup separately reviews sessions, recordings, backing,
   presets and settings; Restore and restart explicitly replaces appliance data.
9. Recall restores musical setup: audio/layers/history, timing, FX, routes,
   input pair/trim, mix/performing state, instruments, pedal colors/actions,
   expression ranges, musical MIDI assignments and prepared backing. It preserves
   current physical interface/format/latency, input/output aliases, CTRL hardware
   type/calibration, real connections, global MIDI enable/sync settings, catalogues,
   performance recordings and appliance preferences. No held contacts or running
   gestures are restored. Files retain stable identities across copies/references.
10. Recovery opens from the pending Library transaction. Missing/damaged recorded
    audio identifies track/layer and accepts only exact original/intact backup
    identity/integrity/format/duration, including Undo/Redo dependencies. Same name
    is not enough. Preserve sparse regions and established spans. Missing backing,
    physical input/output ports, CTRL/MIDI connections and effect/parameter targets
    have distinct repair choices. Stereo repair preserves ordered roles and refuses
    occupied or incompatible ports; instruments are not hardware ports.
11. Repair choices update a candidate only. Review connections uses concise For /
    Use connection and an affected-route count; exact details stay on the chooser.
    Target replacement reviews endpoints in short pages, then a simple From/To
    summary and assignment count. Source IDs and scales remain explicit; no guessed
    mapping by label. Apply/open rechecks media, hardware, target, source snapshot
    and duplicates. Cancel leaves the current rig; failed publication keeps retry
    and must not claim unchanged state if rollback itself failed.
12. Native publication must make audio/files, session metadata, history and storage
    allocation one recoverable operation. A restored package must include actual
    referenced audio and history, not only displayed counts. Session change,
    backup/restore, capture, transfer, eject, device change, calibration and restart
    must honor each other's active guards at commit, not only when a dialog opens.

Sources:
`docs/design/session-library-study.js`;
`docs/design/session-field-ownership.js`;
`docs/design/audio-library-study.js`;
`docs/design/2026-09-09-recovery-expansion-delivery.md`;
`docs/design/2026-09-09-non-production-completion.md`.

## 7. Appliance settings and external sync

1. Device assumes one connected interface and puts its identity/capabilities,
   sample rate, buffer, measured latency and audio health first. Interface
   selection is secondary. Supported choices come from actual capabilities.
   Apply changes a draft, with explicit stop confirmation during playback and a
   capture guard; failure keeps the prior configuration. Channel editors stay
   under Routing. Driver-reported buffer time is not measured round-trip latency.
2. Measure latency first tries a supported isolated automatic path. If unavailable
   or unsuccessful, show spare-output-to-input cable instructions and explicit
   test controls. Never probe arbitrary audible outputs or label estimates as
   measurements. Preserve the previous valid result until replacement succeeds;
   cancel/disconnect keeps it, configuration change invalidates it. Interface
   loss quiets real meters, stops transport and preserves partial-take recovery;
   reconnect is explicit, never an automatic restart or substitute interface.
3. MIDI Sync shares device inventory with Controls. Internal or selected external
   source owns tempo; local tempo/Tap cannot fight external clock. Waiting,
   Synced and Clock lost remain visible. Follow Play/Stop is independent and
   defaults Off. Start resets, Stop retains resume positions and safely ends
   capture, Continue resumes the stopped set. Repeated Stop retains that set.
   Loss offers Keep playing at the last tempo or Stop loops; reconnect follows
   clock but does not start stopped music. Song Position is accepted only stopped
   with no capture/queues, belongs to Sync and is not a Learn target.
4. Send Clock/Play-Stop is per output with no echo to the selected clock input.
   Internal generated clock has −10…+10 ms sender offset, zero reset. External
   relay preserves received timing. DIN Thru forwards physical input once and
   excludes its own forwarded/output traffic; it suspends duplicate generated/
   relayed DIN clock. Control filtering is separate from Thru.
5. Network has one compact connected row with IP address and a full-width list of
   other networks; no giant status card. Join/password retry, saved profiles,
   auto-connect, change password, forget, radio off and reconnect are explicit.
   Failed/canceled joins preserve a prior working connection. Wi-Fi association
   versus internet reachability are different. Network loss must not interrupt
   local recording, loops, FX, physical MIDI or Library. Secrets are not telemetry.
6. Displays lists the left Track display first. Each has brightness and touch
   calibration; shared idle dimming never blanks during performance. Playback,
   backing and capture keep both awake; touch/encoder/pedals wake idle screens.
   Calibration gathers targets, then tests before Keep; cancel, timeout, disconnect
   or failed save preserves the old profile. Encoder cancellation remains possible
   with bad touch alignment. Production profiles bind the correct physical panel.
7. Storage shows actual Internal/USB capacity and shared transfer state. Eject is
   unavailable during USB work; successful OS unmount alone allows Safe to remove.
   Cancel/failure retains the drive; reconnect cannot be consumed by an old callback.
   Prepared internal copies continue independently. Direct USB recording owns its
   removable target explicitly and has same-drive/exact-part recovery.
8. Power finishes recording, stops playback and durably saves before shutdown or
   restart. Stay on/Retry preserves recoverable material on failure; no discard
   shortcut. Transfers/eject guard it. Safe to switch off and Restarting have
   centered icon/text, and Restarting has no ellipsis. Restart reopens stopped.
9. Updates separates availability check, explicit Download, internal staging,
   and explicit Install and restart. USB invalid/removed packages cannot turn
   valid by blind retry. Once staged, the drive is unnecessary. Installation uses
   safe-save-before-restart and real boot-health rollback; failures retain the
   running version. About shows actual version/identity and complete installed
   notices, omitting unknown facts. Controller release and protocol are separate;
   last-flashed version is not a fresh controller identity report. Unsupported
   controller flashing must not appear supported because a fixture can simulate it.

Sources:
`docs/design/audio-device-study.js`;
`docs/design/midi-sync-study.js`;
`docs/design/network-study.js`;
`docs/design/display-settings-study.js`;
`docs/design/2026-09-08-appliance-parity-correction.md`.

## 8. Genuine remaining gates, not reopened approvals

| Gate | What is actually missing | Implementation consequence |
| --- | --- | --- |
| Exact Looper X parameter parity | Verified type/domain/units/curve/choices/conditions for 239 rack keys, reset defaults for all 300 keys, and native schemas for 26 Single FX. Recovered preset values or constructor arguments are not full control contracts. | Preserve identities/evidence and pursue authorized reference material. Do not invent controls, omit them silently, claim exact parity or ship “Scale unverified” as a finished product. This is an evidence blocker, not another taste decision. |
| Computer-facing USB audio / Transfer | Actual Pi 5/enclosure device-mode data capability and whether this separate product feature is wanted. The power USB-C path does not establish it. | Do not confuse USB-stick import/export/direct recording with computer USB audio or mass-storage export. If adopted, first establish hardware feasibility and exclusive storage ownership. No fake mode switch. |
| Independently addressable Phones and hardware controls | Real interface/board capability for Phones, analog gain, phantom power and similar controls. | Expose only genuinely controllable hardware. “Monitor output” is not automatically Phones. No need to block normal routing implementation while this capability evidence is absent. |
| Current-console controller updater | Verified RP2350 update capability, bootloader/transport and physical interrupted-flash recovery. Existing AVR tooling targets a different pedal product. | Keep unsupported honest; reuse lifecycle lessons, not the wrong flashing command. Hardware verification precedes an enabled production updater. |
| Native operating limits and sound delivery | Actual codec/stretch/render limits, CPU/polyphony budgets, storage durability, measured timing/latency, MIDI hardware compatibility and packaged/licensed playable content. | Implement and measure against the accepted UX; simulation bounds are not automatically production limits. The 19-patch instrument design is accepted. Original Looper X factory audio is explicitly not required; independent Segno sounds are permitted. |

No further instrument UX decision is needed. Tails, recording output policy,
partial-take Multi recovery, primary identity/crown, five modes, ten-pedal layout,
independent instruments and shared assignment ownership are already settled.
Any newly discovered conflict must be reported with the concrete affected
journey and evidence; do not generalize it into a redesign of approved screens.

Sources:
`docs/design/2026-09-09-remaining-design-gates.md`;
`docs/design/2026-09-09-fx-reference-completion.md`;
`docs/design/fx-reference-evidence/missing-sources.json`;
`docs/design/2026-09-08-appliance-parity-correction.md`;
`docs/design/2026-09-09-instrument-ux-review.md`.

## Verification journeys for the application handoff

For each delivered slice, prove the useful task plus the relevant failure branch
through real UI and state owners. Browser checks are behavioral examples, not
native audio/physical proof.

| Journey | Required permutations |
| --- | --- |
| Record → overdub passes → Divide → Peel → Undo/Redo | Empty/populated, A/B bank, shared sparse timeline, stopped/playing/capturing, storage failure, reload; preserve unaffected mix/FX. |
| Add sound → map control → perform → save/recall | Physical/MIDI/external/encoder, held/latch, source disable/loss/reconnect, target rename/reorder/removal, unfinished draft, failed save. |
| Independent keys + pads → record instrument → remove/recall | Different channels/ranges, deliberate layer/remap, sustained/repeated notes, monitoring Off, active-capture removal guard, missing sound. |
| Library select → audition → open/import/restore | Selection versus commit, exact source/target change, missing/damaged media/ports, cancel, wrong/reconnected drive, full disk, rollback failure. |
| Performance capture → low space/unplug → recover/export | Actual ordered audio parts, frozen format/output policy, exact recorded endpoint, one Library identity, no double-charged capacity. |
| Settings while music runs | Explicit interruption only where required; recording guards, cancel/retry, touch lock, physical Exit, restored focus and both-screen consistency. |

Sources:
`docs/design/verify_stage_recording_journey.cjs`;
`docs/design/verify_capture_recovery.cjs`;
`docs/design/verify_instrument_complete_journeys.cjs`;
`docs/design/verify_appliance_backup_browser.cjs`;
`docs/design/verify_timing_completion.cjs`.
