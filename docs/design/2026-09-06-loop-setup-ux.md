# Loop setup interaction study

Design work under appliance roadmap issue 919. The owner tested the revised FX
journey, described it as intuitive, and requested continued UX work. This slice
extends the same submenu, touch and encoder patterns to recording setup. The
owner rejected generic form pages and asked for the personality of musical gear,
then cautioned that a full visual preview was too much for mode selection. It is
a browser simulation, not production engine integration or hardware validation.

[Open Loop settings](fx-ux-prototype.html?review=loop-settings).

## Design authority

The owner explicitly confirmed that these designs define the target product's
features, behavior and UX. Looper X is a reference, and the roadmap must follow
the reviewed target. Current Segno code establishes implementation gaps and
reusable work, not limits on what can be designed.

Earlier examples carried current engine restrictions into the prototype. The
MIDI fixed-length/count-in restrictions, blanket recording locks and content
lock on mode changes are not approved target rules merely because they appear
in the current code. Review each against the intended musical behavior and
define transition/recovery behavior before retaining a restriction. Earlier
references below describe the study's history; they do not override this decision.

For the next Playback & overdub slice, define per-track Loop/Once and decay in
all five modes. The existing Free/Song-only auto-stop and global feedback
coefficient are implementation gaps, not restrictions to copy into this UI.

| Entry | Current interactive scope |
|---|---|
| Loop mode | Multi, Sync, Song, Band and Free, with one sentence describing the track relationship |
| Recording | Record → Play → Overdub or Record → Overdub → Play; immediate/count-in start versus waiting for sound after arming |
| Tempo & click | Direct whole-BPM slider, tap tempo, time signature, click policy and count-in length |
| Length & quantize | New-recording defaults and per-track length/timing overrides in one editor |
| Playback & overdub | Per-track Loop/Once and 0–100% overdub decay, with independent default inheritance |
| Audio & tempo | Per-track tempo following and pitch preservation, with defaults and effective original-speed state |

The hub shows the current choice beside each submenu. Loop mode keeps five
choices with compact static diagrams; the cards are slightly narrower and
shorter while text stays at the shared size. The owner accepted the diagram
approach and requested that final size reduction.

Recording has two compact rows: how recording starts (Pedal or Sound), and what
the second pedal press does (Play or Overdub). The separate pedal simulator,
large pictogram cards and reset controls were rejected and removed.

Tempo, time signature, click behavior and count-in remain on one page. A tempo
area has priority, followed by aligned Hear click and Count-in rows. The owner
rejected competing panels and the proposed submenu split, clarifying that this
was a layout problem. Small beat lights respond to taps, not an audio clock.
The owner accepted Recording and timing as the provisional baseline before
moving on to loop length and quantization.

All pages use the shared 1920 × 1080 canvas, 56 px sliders, at least 64 px buttons,
24 px control labels and visible encoder focus. Display roles remain undecided.
The diagrams add no controls, playback simulation or encoder stops.

Tempo is edited directly. Encoder press starts an adjustment, turning changes it,
press commits, and Back/Escape restores the opening value. Double tap restores
the tempo prepared at the start of this demo. A pedal event cannot persist an
unfinished tempo draft. Touch and encoder use the same value. Naming and FX
editing remain in their own journeys.

The reference for structure is Looper X
[UX04–UX09](../research/sheeran-looper-x-1.0.2/ux-paths.md#ux04--record-a-first-loop)
and its [looping features](../research/sheeran-looper-x-1.0.2/features.md#f02--five-looping-modes).
The five mode descriptions are proposed product semantics based on that
reference; they are not a claim that all those modes work in Segno today.
The [mode-change contract](2026-09-07-loop-mode-transitions-ux.md) now supersedes
the earlier content lock. Compatible choices apply immediately while stopped;
playing loops require explicit Stop loops and switch. Actual track lengths
determine incompatible choices. No audio conversion is offered.

The recording choices correspond to `RecordOptionsCubit.recDub` and
`autoRecord`. Waiting for sound requires a Record press on an empty track;
it is not an always-listening recording trigger. The sensitivity threshold and
interaction with count-in/quantized execution are not represented as recovered
controls. This is a configuration study, not a live transport trace.

Tempo bounds (30–300 BPM), 17 time signatures and count-in choices (Off, 1, 2, 4
bars) follow `TempoCubit` in this checkout. This differs from the Looper X guide's
documented upper tempo bound. Click choices follow `ClickMode`: off, defining
first recording, any recording/overdub, or playing/recording. Output routing and
click gain remain separate from when the click sounds.

Lock examples are explicit fixtures:

- [Recording active](fx-ux-prototype.html?review=loop-recording-locked) disables recording behavior changes and explains why.
- [MIDI clock](fx-ux-prototype.html?review=loop-midi) owns tempo and disables count-in. An empty loop can still choose a time signature.
- Mode changes check actual recorded durations and require recording and queued
  actions to finish first. Existing audio alone does not lock all choices.

Configuration is stored separately from the FX objects inside the demo's browser
state. Review links reset their fixtures on reload. Loop-mode checks now share recorded parts, durations and playback state with the
main session. Older configuration-only examples remain illustrative fixtures.

## Remaining journeys

This is the first Loop settings slice, not the complete settings surface:

- Tempo-change transition and resource/quality failure paths, plus the wider loop-transform journey.
- Fractional tempo entry and precise tap/count-in interactions on the appliance.
- Pedal-menu customization, audio/MIDI connections, session creation and recall.

These need distinct controls and engine mapping. They are not folded into Audio
hardware setup or represented as working by this study.

## Verification

`verify_loop_journeys.cjs` checks configuration isolation, navigation, tempo
commit/cancellation/reset, signature selection, and disabled/reenabled controls.
It captures seventeen views and checks the shared canvas, aligned horizontal edges and minimum target sizes.
The FX regression suites separately cover adding, ordering, preset copying,
replacement, removal, scrolling and pedal/encoder behavior. Native Pen screenshots
are reviewed independently of browser captures. No audio was recorded or heard.

## Length and quantization: current proposal

The owner authorized this next slice after accepting the provisional Recording
and timing layout. [Open the fixed-length example](fx-ux-prototype.html?review=loop-length-fixed).
It adds one Loop settings submenu, **Length & quantize**, for defaults used by
new recordings. Existing recorded audio is not resized by editing these values.

- **Auto** lets the performer finish the take; **Bars** shows a direct 1–64 bar
  stepper. Touch minus/plus changes by one. Encoder press on the value begins an
  edit, turn adjusts it, press commits, and Back cancels. Returning from Auto to
  Bars remembers the last bar count within the study.
- **Record timing** uses one explicit choice: Immediately, Loop start, 1 bar,
  1/2 note, 1/4 note, 1/8 note or 1/16 note. The fractions mean note values, not
  fractions of the whole loop or signature-dependent beats. Its short sentence
  describes record/overdub requests; it does not claim that every pedal action
  uses that setting. The defining first recording follows Recording settings; its count-in or sound
  trigger remains separate from waiting for an existing musical grid.
- Fixed length stays independent of audible click in the proposed product.
  Its automatic end follows the selected Play/Overdub behavior. These are
  intentional engine changes, not claims about current native behavior.
- Recording locks these edits. The external-clock fixture keeps the recovered
  fixed-length restriction explicit while leaving quantization selectable.
  Clocked fixed length is not presented as a working capability in this slice.

The source inspection also confirmed that sound activation and count-in are
mutually exclusive. Choosing Sound now clears count-in; enabling a count-in
restores pedal start. The retained Recording page makes the effective start
behavior visible in its one contextual sentence.

### Implementation evidence and follow-through

| UI intent | Current code evidence | Required implementation work |
|---|---|---|
| Absolute bar count | `segno_engine_api.h` track length preset API supports Auto and 1–64 bars for the defining recording; global `default_multiple` uses whole base-loop multiples for other captures | Create one explicit ownership model for new-recording defaults, shared length in Multi, and per-track overrides; never label base-loop multiples as bars |
| Fixed length without audible click | Native preset × click matrix auto-finishes only with click enabled and a known tempo; click-off derives tempo from the take | Separate length scheduling from click audibility; define no-tempo, early finish, resource-capacity and mode-specific behavior before engine binding |
| Automatic Play/Overdub choice | Current fixed non-defining captures auto-finish into overdub independently of `rec_dub` | Make the chosen outcome consistent for manual and automatic finish, with native regression coverage |
| Immediately / loop start / musical grid | `QuantizeCubit` controls the arm gate; `TempoCubit.quantizeDiv` selects a division; `engine_process.c` consumes the live subdivision ratio | Map a single product setting atomically to gate and division, and clear obsolete alternative UI paths. Off must not accidentally mean a loop-start wait |
| Per-track timing | Native per-track override is a boolean; musical division is global | Implement optional per-track timing enums with field-level inheritance; the proposed UI allows divisions to differ per track, beyond the current boolean override |
| Sound / count-in | `le_engine_set_count_in` contract and record-arm path define exclusivity | Keep the two settings and published state consistent, including pending-arm cancellation |

The first version covered defaults. The per-track extension below uses the same
editor; neither is a transport simulator. Sync/Band primary-track constraints, Free mode behavior, content locks,
capacity failures and the first-loop versus later-track distinction still need
explicit integration. Native API comments include older phase notes; the live
subdivision consumer in `engine_process.c` was inspected rather than treating
those old comments as evidence that quantization is absent.

The initial browser checks covered twelve views, including Auto, fixed length,
recording-locked and MIDI-clock variants. They exercise the bar edit commit and
cancel paths, bounds, retained values, all seven timing choices, count-in/sound
exclusivity, and the proposed independence from audible click. These are author
checks of a UI simulation; they do not validate audio scheduling or hardware.

The owner tried the Length & quantize study, accepted it as okay, and asked to
continue. The owner then authorized per-track setup, followed by the Playback &
overdub slice below.


## Per-track length and timing

[Open the per-track example](fx-ux-prototype.html?review=loop-track-custom).
Defaults and all eight tracks use one canonical editor. The owner rejected nine
large navigation cards, accepted a compact selector, and requested more
horizontal padding with consistent alignment. The page now uses a 100 px inset
for its title, selector and both settings sections on the 1920 px canvas. The
selector uses a static Tracks label, then Defaults followed by eight numbered
64 px touch targets. The owner chose that order and removed the New recordings
label. The Defaults button aligns with the controls below in both selection
states; no negative margin or selection-background offset is needed. A named track shows
its full name to the right; each track control also has its complete accessible
name. Names exceeding the available line are truncated in the visual readout.

Each field displays its actual selected value, with **Default** or **Custom**
beside its label. Editing length only overrides length; timing continues to
follow its default. Selecting **Use default** removes that field's override, so
later default changes propagate again. A custom value equal to the current
default remains custom. Auto is an explicit value and can override a fixed
bar-count default.

Encoder edits preserve both the opening value and its ownership. Back cancels;
press commits. Switching tracks cancels an unfinished bar edit on the previous
track. A pedal-triggered browser save cannot accidentally commit that preview.
Committed overrides survive reloading the ordinary demo URL. Review links reset
their examples, as in the FX study.

In Multi, tracks show the shared default length and disable independent length
controls with **Shared in Multi** beside the label. Record timing can still be
customized. Independent-mode lengths remain stored but inactive while Multi is
selected; returning to an independent mode restores them. This is an empty-loop
configuration example, not permission to switch mode over existing audio.
Recording and MIDI restrictions retain their prior behavior. Track selection
remains available while edits are locked so the performer can inspect values.

The study now proposes per-track timing divisions, not just boolean quantization.
Production work must implement that ownership model, mode-specific scheduling,
capacity handling and session serialization before these controls are wired to
the engine. Stored new-recording lengths do not resize an existing take. Sync and
Band alignment constraints and their primary-track roles still require explicit
engine integration; the study does not claim to validate that audio behavior.

Additional checks exercise inherited-value propagation, matching explicit
values, independent Auto, per-field reset, target-switch cancellation, isolated
tracks, Multi shared length, recording/MIDI locks and persistence without drafts.
The five added views cover inherited, custom, shared-length, recording-locked
and MIDI-clock states. Chromium and Firefox are checked separately.


A later native text review corrected the Pen import itself across the 39-screen
study. Button labels had been moved to the top by an overbroad fitting rule.
The native copy now preserves browser line anchors, centering, weight and letter
spacing; it uses matching Arial metrics through Arimo. The accepted browser
layout and interactions were unchanged. See the
[native typography review](fx-ux-previews/pen-sizing/review.md#native-text-alignment-correction).

## Playback and overdub: target behavior

[Open the per-track example](fx-ux-prototype.html?review=loop-playback-custom).
The owner authorized this slice and clarified that the designs specify the
product we want. There is one **Playback & overdub** submenu, using the accepted
Tracks / Defaults / 1–8 selector, 100 px inset and direct filled slider.

- **Loop** repeats until stopped. **Once** plays to the track's end and stops
  that track. Both choices are available in all five modes. Enabling Once during
  a pass finishes that pass; it does not restart the track or its clock.
- Once ends an active overdub at that boundary as well. It does not stop other
  sounding tracks or the shared clock, change the selected Song section, or
  automatically launch another section. A subsequent launch from the automatic
  end starts at the beginning. A manual mid-pass stop follows the ordinary
  transport resume policy, which remains to be defined in the Stage journey.
  These are proposed target semantics; shared-clock/Sync/Band implementation
  must honor the explicit stop without automatically restarting that track.
- **Overdub decay** is 0–100%. Zero, shown as **Off**, keeps earlier audio at its
  previous level. Each overdub pass retains `1 - decay / 100` of existing audio
  before adding the new input. At 25%, the original audio retains 75%, 56.25%,
  42.1875% and 31.640625% after four passes. New input is not attenuated by decay
  on its first pass. At 100%, the new pass replaces the previous audio, including
  with silence. Normal playback does not cause further decay.
- Playback and decay inherit independently from Defaults. A matching explicit
  value remains Custom. **Use default** removes that field's override. Double
  tapping the decay slider restores inheritance on a track and resets decay to
  Off when editing Defaults. The persistent labels are Keep layers / Replace
  layers; the short sentence explains the effective amount.
- These controls remain available during playback, recording and overdubbing.
  Changing a setting does not stop transport. The production implementation
  needs smooth, predictable live updates. Recording-state changes cancel an
  unfinished encoder draft consistently with the existing prototype grammar.
- Encoder press edits decay, turning changes it by one percentage point, press
  commits, and Back cancels. Changing tracks cancels the former track's draft.
  Draft values are excluded from unrelated saves; committed settings survive
  reload at the ordinary prototype URL. Review URLs reset example data.

The extracted Looper X [one-shot/decay journey](../research/sheeran-looper-x-1.0.2/ux-paths.md#ux09--change-one-shot-decay-and-time-stretch)
provides the feature reference. The percentage direction and detailed rules
above specify Segno's target; they do not assert Looper X's exact DSP law.

| Target | Current implementation evidence | Work needed to fulfill the design |
|---|---|---|
| Independent Loop/Once in all five modes | `le_engine_set_one_shot` stores a per-track flag in every mode; `advance_track_clock_frame` only auto-stops Free/Song | Define per-track end boundaries and stop/relaunch behavior for the shared-clock modes; retain the setting through clear, save/restore and undo |
| Per-track decay, live controls, independent inheritance | `le_engine_set_overdub_feedback` takes one global coefficient and applies it only during overdub | Add per-track ownership and inherited defaults; map decay to feedback, preserve layered audio/undo and define smoothing, capture/replay and session recall |
| Target UI independent from current limitations | Earlier study fixtures copied MIDI/recording/mode locks from current code | Reconcile those fixtures against intended musical behavior; record justified product rules and implementation gaps separately |

`verify_loop_playback.cjs` passes in Chromium and Firefox. It exercises field
inheritance, explicit matching overrides, all five modes, live overdub edits,
slider endpoints, touch/encoder parity, cancellation, reset, scope changes,
draft-safe persistence, reload and FX isolation. It checks all eight tracks are
visible, aligned rows, 1920 × 1080 geometry and minimum touch targets. Existing
Loop checks pass in both browsers and the FX journey regression passes.
These are author-side UI checks, not audio or appliance validation.

## Audio and tempo: reviewed configuration

[Open Audio & tempo](fx-ux-prototype.html?review=loop-audio-tempo-pitch).
The owner reviewed this page, said it looked great, and redirected the next
slice to FX Pre/Post placement and output effects. The page uses the same
compact selector and 100 px inset. Follow tempo is Off/On. With following On,
Pitch is Unchanged/Follows speed. Each field independently inherits Defaults;
matching explicit choices stay Custom and Use default restores inheritance.
With following Off, Pitch becomes an Unchanged readout, not a disabled choice.
The saved pitch preference returns when following is reenabled. Resetting an
inherited field returns encoder focus to its effective choice. Defaults are
Follow tempo On and pitch Unchanged.

This adds no second tempo editor. Song BPM stays in Tempo & click. Choices apply
to the selected track's recorded material; live-input monitoring is unaffected.
The target permits configuration in all five modes and during playback/capture,
including opting out when the song follows MIDI clock. Source QML makes Looper X
following mandatory under MIDI receive; this is an intentional Segno departure.

The [official user guide, page 35](https://cdn.inmusicbrands.com/sheeran/looper-x/Sheeran%20Looper%20X%20-%20User%20Guide%20-%20v1.0.0.pdf#page=35)
separates Sync Audio to Tempo from pitch-preserving Time Stretch and describes
half-speed to double-speed stretching. Segno's labels express the consequences.
The page models settings, not transformed audio or measured stretch quality.
At a recorded tempo of 84 BPM and song tempo of 100 BPM, following requests a
100/84 speed ratio. Preserving pitch keeps notes unchanged; following speed
couples pitch to that ratio. Following Off retains original playback speed and
pitch. It can consequently drift from the changing song grid.

Before audio integration, define phase-continuous switching, original-tempo
metadata and imported audio with unknown tempo, capture/overdub mapping into
original material, mode/shared-length interactions, resource/quality failures,
undo, session recall and performance replay. In particular, opting out must not
silently truncate audio to a newly shortened master grid. These unresolved
transport contracts are implementation planning work; the configuration choices
are not proof that those audio paths exist today. The current public engine API
inspection did not identify a binding for this target; the roadmap's stretching
slice and measured appliance work remain required.

`verify_loop_audio_tempo.cjs` passes in Chromium and Firefox for per-field
inheritance, retained versus effective pitch, all five modes, MIDI opt-out,
live overdub edits, touch/encoder selection, focus recovery, reload, the existing
tempo-editor return path and FX isolation. The Loop and Playback regression
checks also pass in Chromium. Minimum targets, aligned controls, all eight
tracks and the shared 1920 × 1080 geometry were checked. Browser and native Pen
review remain separate from acoustic and physical display validation.

Additional reference clarification: Looper X labels decay as Feedback, with
100% keeping old audio intact. Segno's reviewed Decay label runs in the opposite
direction: Off/0% keeps it intact, and increasing decay removes more per pass.

## Pedals: owner-directed revision

The owner rejected the first per-track Press/Hold form and state preview and
requested an approach closer to Looper X. That prototype module and its test
were removed, and its four Pen frames were replaced. It is not an accepted
per-track customization requirement.

The replacement separates shared pedal behavior from custom-mode assignment:

- **Pedals:** Hold Record / Play (Undo recording or Peel layer), Hold track pedal
  (Arm overdub or Clear track), Mode pedal (Mute, Tuner, FX or Custom), entry to
  Customize, and whether new loops keep or reset custom assignments.
- **Custom pedals:** select the function on a pedal to open a compact chooser.
  Changes remain a draft until Save. Cancel and Back discard that draft; closing
  a chooser returns to its pedal. Clear assignments affects the draft across
  both banks and is recoverable through Cancel. Editing a custom layout does
  not change the selected Mode function. MODE remains Exit in Custom mode.
- The Record/Play sequence stays on the existing Recording page. There is no
  second independent sequence setting or duplicate per-track defaults editor.

### The physical layout is Segno's

Looper X is the interaction reference, not the physical layout. The owner
explicitly corrected this distinction. The verified faceplate has ten pedals:

| Rear pair | Position |
|---|---|
| Clear | Above Undo |
| Bank | Above Mode |

Front row, from the player's left: **Record/Play, Stop, Undo, Mode, Track 1,
Track 2, Track 3, Track 4**. All ten appear in the editor. MODE is a fixed,
non-editable Exit tile, excluded from encoder focus. BANK changes the displayed
bank on its own tile. The four transport assignments are shared between banks;
the four physical track pedals have separate A/B custom assignments. Physical
track labels remain 1–4 in either bank. This is ten physical pedals, not ten
independent editable function slots.

Evidence: `hardware/enclosure/segno_enclosure.py`, `_ROW1` and `PEDALS`, and
`hardware/segno_enclosure_design.md`, section 2. The faceplate PDF was also
rendered and inspected. The screen retains the actual relative positions;
it is not a manufacturing scale drawing. Neither CAD nor firmware was changed.
Physical display roles remain open despite older hardware documentation naming
roles for them.

### Hold targeting: explicit owner decision

The owner chose **follow the newly selected track**. Until the hold action
fires, a change of selection changes its target. Resolve the track identity at
execution time. After the hold action fires, further selection changes and
release must not fire it again. A bank change that does not change the selected
track does not invent a new target. The old proposal to freeze the original
track was superseded. The hold action itself must not silently change mid-gesture
because setup was edited. Disconnect cancels a pending gesture.

This is a target interaction contract. The configuration prototype does not
execute pedal gestures or audio, and does not claim that the production resolver
implements it. Thresholds, pending-hold feedback, press/hold arbitration,
quantized actions and current-track selection need end-to-end hardware tests.
Arm overdub requires a stopped track with audio. Clear and Peel require explicit
undo/recovery behavior in the implementation; a choice label alone does not
implement that history.

### Reference and verification

Official Looper X guide pages 36–37 show shared hold settings and a custom pedal
menu with an anchored assignment picker, Save, Cancel, Clear, and fixed Exit.
Unmodified embedded screenshots are saved in the reference atlas as
`global-general-official-guide.jpg`, `loop-customize-pedal-official-guide.jpg`,
and `custom-pedal-menu-official-guide.png`, with provenance sidecars. The guide
is version 1.0.0; the extracted QML independently corroborates the interaction,
not every native option or gesture transition.

`verify_pedal_setup.cjs` passes in Chrome and Firefox for setting selection,
encoder focus, all ten positions, fixed Mode, bank isolation, shared transport
slots, Save/Cancel/Clear, persistence, and draft preservation during unrelated
FX/capture events. Chooser entries cover the Looper X function families plus
Segno transport actions; they are assignment definitions, not proof that every
function is implemented. No audio, physical controller, or session-creation
lifecycle is exercised by this browser study.

Historical routes `loop-pedals`, `loop-pedals-custom`, `loop-pedal-actions` and
`loop-pedal-hold` are superseded. The accepted A layout now lives in Settings →
Pedals in the main prototype (`pedal-setup`). Loop settings has six destinations.

### Performance behavior requires its own definition

The owner identified that assigning function names does not define their
behavior. A function entered with a footswitch must be fully operable and
escapable by foot; opening a screen that then requires touch is insufficient.
The label Exit is accepted for returning to normal track controls. See the
[pedal performance contracts](2026-09-06-pedal-performance-contracts.md) for
the owner decisions, initial Transpose/FX proposals and remaining catalogue.
The existing setup prototype is not proof that those performance journeys exist.

The owner subsequently required independent Press and Hold function assignments
on a footswitch, such as entering FX on press and Custom on hold. The revised
prototype now exposes both Mode entries and both gestures on each editable
custom pedal, using the same physical layout. This replaces the single-action
assignment model; the rejected per-track form is not reinstated. Mode is still
Exit within the custom context and Bank switches its four track-pedal pairs.
See the performance contract for the verified configuration journey and the
still-open runtime arbitration, context and transport timing decisions.

The later `loop-mode-hold` and `loop-pedals-bank-b` study routes are also
superseded by the accepted Pedals layout. Earlier Pen frames are marked
superseded. The accepted setup keeps the physical map visible while editing a
pedal's Press and Hold, with shared track actions and explicit fixed controls.
See the [locked pedal decision](../brainstorm/2026-09-06-pedal-setup-layout-brainstorm-doc.md)
for current routes, persistence and verification.
