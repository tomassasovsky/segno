# Pedal performance workflows

Part of appliance roadmap issue 919. This defines target behavior for review.
Setup A, Transpose, Mixer, Reverse, Fade, Speed and Multiply / Divide are accepted; the latest silent study simulates entry,
Mute, Custom, FX, Transpose, Mixer, Reverse, Fade, Speed, Multiply / Divide, banks and Exit from saved assignments. Audio and hardware dispatch are not
implemented. The remaining catalogue is not an approved behavior specification.

The owner accepted selected-track length editing with First/Last retention and
recovery, then requested [separate Multiply and Divide functions](2026-09-07-length-performance-ux.md).
The revised pages remove the intermediate chooser; their completed visual review
is pending. The earlier combined page is superseded.

## Owner decisions

- A function entered through a footswitch must be operable and escapable using
  footswitches alone. Touch and encoder may provide equivalent controls, but
  neither is required to complete the performance task.
- The screen shows the current pedal meanings, target and result. Entering a
  function must not merely open a touch settings page.
- **Exit** is an acceptable label when it means returning to normal track
  controls. It does not stop audio, clear tracks or quit the application.
- Mode defaults to **Press: Mute / Hold: Custom**, explicitly chosen by the owner.
- A configurable footswitch needs independent **Press** and **Hold** assignments.
  These may enter different performance functions. The owner gave a short press
  entering one function and a hold entering another as the intended pattern.
  The single Mode-function setting in the prototype is therefore incomplete.
- Use Segno's ten-pedal faceplate, not the Looper X pedal arrangement. The roles
  of the two physical displays remain undecided.
- Until a pending hold fires, its target follows the newly selected track.
  Execution consumes the gesture; release cannot trigger a second action.

The customization screen is preparation: choosing what each pedal will do.
The resulting performance workflow is a separate journey that must also be
designed. Its visual language should use the accepted sparse physical-pedal
layout, with the current action visible at each pedal position.

## Press and Hold: revised entry contract

One physical pedal can have two independent assignments. Mode defaults to
**Press: Mute / Hold: Custom** in normal track control. The owner chose these
defaults after reviewing the initial FX/Custom example. The design must not restrict
function-entry assignments to a single Mode dropdown. Keep the physical
ten-pedal selector; do not revive the rejected per-track Press/Hold settings
form or duplicate these assignments under individual audio tracks.

For navigation entries, short press and hold are mutually exclusive: holding
must not briefly enter the Press function before entering the Hold function.
A short press can be resolved on release, while a hold fires once at the hold
threshold and consumes the following release. Pending-hold feedback belongs
at the physical pedal position. Define the threshold and feedback in the
interactive prototype before considering the gesture complete.

Keep an explicit Exit path in each entered function. Review the scope of a
pedal's entry assignments versus its function-specific roles: normal track
control, the custom menu and the active performance function are different
contexts. Do not silently make an active function's Exit impossible to reach,
or execute a newly assigned command on release after changing context.

The current global hold settings, custom-slot assignments and Mode setting
must be reconciled into one clear ownership model before implementation; no
two settings may independently define the same physical gesture in the same
context. Record/Play and other rhythm-sensitive commands need a separate timing
decision: delaying every command until release to accommodate a hold would
change when recording starts. The navigation rule above does not approve that
transport change. The owner's pending-hold track-target rule still applies.

The revised setup UI now exposes separate Mode Press/Hold controls and two
direct assignment buttons in each editable custom pedal. Choosing one opens
the same anchored function chooser, titled with its physical pedal, bank and
gesture. “None” leaves the gesture unassigned. Mode stays fixed to Exit within
Custom mode; Bank remains the bank selector. The four transport pairs are
shared across banks, while each bank owns four independent track-pedal pairs.

Press and Hold changes remain in the same draft until Save; Cancel and Back
discard both. Clearing resets both gestures across both banks in the draft.
Encoder selection returns to the exact gesture button after choosing or closing.
Changing either Mode entry does not edit the other or the custom assignments.

The stored single-action prototype assignment model was removed, with no
migration or compatibility path. Previously saved pedal-study assignments reset
to the new defaults; other loop and FX data retain their existing model. The
new model persists both gestures. Browser configuration checks pass in Chrome
and Firefox, including bank isolation and drafts during unrelated saves.

Runtime gesture arbitration, performance entry/Exit, and the actual functions
are still design/implementation work. Saving two assignments does not establish
that the hardware executes only one action during a hold. The global normal-track
hold choices remain separate from custom-mode assignments; they do not apply
while a custom pair owns that physical gesture.

## Proposed shared behavior

These details are proposals, not additional owner decisions.

Mode is always Exit in the custom menu and its function workflows. Exit returns
directly to normal track controls; it does not require stepping back through
nested menus. A workflow with an uncommitted operation cancels that operation on
Exit. Immediate musical adjustments remain applied when leaving their workflow.

Bank changes the four track-pedal positions between A and B. Each function shows
whether those positions address tracks or FX states. Track identities and FX
assignment identities are distinct even when both use four pedals in two banks.

Preserve a direct Stop action in performance workflows. Avoid copying Looper X's
use of Stop as a numeric adjustment without accounting for Segno's separate
Mode, Clear and Bank pedals. A held pedal must not fire a newly assigned action
when entering or leaving a function; release it before accepting its next press.

## Performance workflow contracts

### Transpose

Transpose changes the musical pitch of recorded tracks in semitones while
preserving their timing. It is independent of the Audio & tempo choice that
couples pitch to playback speed, and does not transpose the live input.

Owner-accepted complete foot journey:

1. Press the custom pedal assigned to Transpose. Enter a performance panel with
   the currently selected track targeted and each visible track's semitone value.
2. Track 1–4 toggle which tracks are targeted. Bank exposes the other four tracks;
   selected targets remain selected across banks. Nothing is applied to an empty
   track, and its unavailable state is visible at its pedal position.
3. Use two clearly labeled pedals for **−1 semitone** and **+1 semitone**.
   The physical positions are Undo for down and Clear for up. Record/Play
   and Stop retain their normal transport roles; Mode remains Exit.
4. Each step adjusts all targeted tracks by the same delta, retaining differences
   between their starting values. With no targets, adjustment does nothing and
   both adjustment positions show their unavailable state.
5. Press Exit to resume normal track controls. The resulting pitch remains.

The new [interactive Transpose study](fx-ux-prototype.html?review=performance-transpose)
implements this owner-accepted journey. Hold Undo or Clear for 800 ms
to reset all selected tracks to zero; release after a reset never also steps
pitch. Short taps step on release so Press and Hold remain exclusive. Selection
is temporary: entering targets the current recorded track, or the first track
with audio if it is empty. Selected tracks remain selected across bank changes.
The summary shows the selected tracks from both banks; LEDs mark the selected
pedals in the visible bank. Bank and Exit retain their accepted physical places.

The accepted range is −12 to +12 semitones. If any selected track would
cross a limit, the whole group stops in that direction, preserving relative
pitch offsets. Reset remains available by holding either pitch pedal. With no
selection, both pitch pedals are disabled. Empty tracks cannot be selected.
One press produces one step; holding does not auto-repeat. Track selection may
change during a pending pitch gesture; the selection at activation is used.

Pitch updates persist in the prototype rig and survive Exit and reload. The
original recordings are not rewritten by this UI study. Record / Play still
addresses the current transport track, shown beneath that pedal; selecting
transpose targets does not retarget recording. Stop addresses all loop tracks.
The browser emits recording intent and stops its simulated playback flags;
actual transport, sound processing, smooth transitions, overdub behavior and
session recall on the appliance remain implementation work. In particular,
pitch offsets must be independent of playback-speed coupling in Audio & tempo.

Looper X source confirms a semitone up/down workflow, but does not establish
these exact pedal positions, reset gesture, range or group-limit policy. These
are owner-accepted Segno product decisions, including the layout, pedal actions,
range, reset and shared-limit behavior. They are not claims of reference-device
parity or completed production implementation.

`verify_transpose_performance.cjs` covers foot entry, multi-track selection,
cross-bank groups, offset-preserving steps, reset/Exit/focus-loss cancellation,
empty/no-selection states, shared limits, transport intents, persistence and
1920 × 1080 layout in Chrome and Firefox. It is silent browser evidence, not an
audio-quality or hardware test.

### Mixer

The owner accepted [Mixer with Tracks and Inputs](2026-09-07-mixer-performance-ux.md).
It adjusts one channel at a time. Inputs controls live-monitor volume only;
Tracks controls recorded-loop playback. Bank pages four channels and holding
Bank changes Tracks / Inputs. Holding a channel toggles mute without resetting
its level or Auto monitoring policy. Undo/Clear step volume or reset it on hold;
Exit preserves gains and mute states. This replaces the initial group-selection
proposal. The detailed contract separates browser state from audio implementation.

### Reverse

The [Reverse performance study](2026-09-07-reverse-performance-ux.md) implements
one press per direction change, state LEDs, banked track access and Exit. The
owner approved immediate position-preserving reversal and a small Reverse marker
in normal Tracks, with Mixer unchanged. The complete layout is now owner accepted.
Audio continuity and reversed-overdub behavior remain native implementation and
listening-test requirements.

### Fade

The owner-accepted [Fade study](2026-09-07-fade-performance-ux.md) defines independent track
fade envelopes, progress feedback, smooth retriggering and a complete foot
journey. The owner approved the full layout, shared-default duration with per-track
overrides, tap/hold roles, seconds range and recovery behavior. Mixer volume and mute stay independent; fading does not rewrite audio.

### Speed

The owner-accepted [Speed study](2026-09-07-speed-performance-ux.md) defines whole-loop
tape-speed choices with explicit pitch and duration feedback. Absolute rates
avoid compounding; Normal returns to 1× without resetting Transpose or tempo
following. The owner accepted the full foot journey and retained Tracks readout.

### FX

FX enters the performance bank of eight logical FX assignments. It does not open
the rack parameter editor as its required next step.

1. Press the custom pedal assigned to FX. Show four FX assignments in their
   physical track-pedal positions, their active states and the sounds they control.
2. Track pedals 1–4 operate the visible FX states. Bank switches A/B to reach all
   eight assignments. These are assignment states, not a limit of eight racks.
3. The existing normal/inverse latched and held/released rules determine which
   racks respond. A pedal can affect several sounds on different destinations.
4. Record/Play and Stop continue to control the loop. Exit returns to normal track
   control without resetting latched FX states.

Before implementation, settle the unused Undo/Clear roles in this function and
test release after bank changes or Exit. Every held FX activation must receive
its matching release, even if the visible bank or mode has changed; this is
separate from the owner's rule about selecting the target of a pending track
hold. A screen transition must never leave a momentary sound stuck on.

## Remaining assignment catalogue: intended outcomes for review

This inventory distinguishes outcomes from complete contracts. These entries
still need physical pedal mappings, unavailable states, timing, recovery and
exit behavior before their performance screens are considered designed.

| Current label | Proposed outcome and foot-operated journey |
|---|---|
| None | No assignment for this gesture; it has no effect. |
| Track | Return to the normal track performance view and controls. |
| Wave | Switch the performance display to recorded waveforms while keeping normal foot controls available. |
| Multi, Song, Sync, Band | Choose a loop behavior. These are mode changes, not per-track effects. Define existing-audio conversion and a pedal-only confirmation path without silently clearing audio. Review why Free is missing before accepting this group. |
| Mute | Enter a banked track view; each track pedal toggles that track's audibility. Define playback position and monitored-input treatment explicitly. |
| Bounce | Owner accepted: select sources, choose destination, then commit, with explicit replacement, Keep/Clear sources, tail choice and grouped recovery. See the [Bounce contract](2026-09-07-bounce-performance-ux.md). Native render composition and shared history remain implementation work. |
| Multiply | Repeat the selected track to double its length, with direct Undo. See the [length contract](2026-09-07-length-performance-ux.md). Separate-mode visual review and native audio work remain. |
| Divide | Direct First half / Last half actions for the selected track, with hold Undo. Track selection and Bank retain their roles. |
| Backing track | Select and play prepared backing material by foot, including next/previous and stop. Define its relationship with session transport. |
| New loop | Create a new loop through a pedal-only journey while preserving recoverable current work. Define whether audio continues during preparation. |
| Tuner | Owner accepted: select an input, tune with temporary live mute, adjust A4 reference by foot, then Exit to Tracks. See the [Tuner contract](2026-09-07-tuner-performance-ux.md). Pitch detection remains simulated. |
| Peel | Select the track by foot and remove its latest overdub layer. Define recovery and what happens when only the first recording remains. |
| Record / Play | Perform the configured record/play/overdub sequence on the intended track. Define when a custom-menu command remains in that menu or returns to tracks. |
| Stop | Stop its explicitly defined target. The choice must say whether it affects the selected track or the full loop; define timing and downstream FX tails. |
| Undo | Proposed: reverse the latest recorded-content edit on the selected track. Owner accepted original-recording recovery, one layer per Undo, canceling the first take to empty, removing an in-progress overdub with return to playback and Redo recovery, and restoring the state before Clear All. See the [Undo/Redo discussion](../brainstorm/2026-09-07-undo-redo-brainstorm-doc.md) for remaining scope and recording cases. |
| Redo | Proposed: move forward through the same track history, with hold exclusive of tap. Owner accepted immediate playback when restoring a canceled first take. See the [Undo/Redo discussion](../brainstorm/2026-09-07-undo-redo-brainstorm-doc.md). |

## Reference

The [official Looper X guide, Functions section](https://cdn.inmusicbrands.com/sheeran/looper-x/Sheeran%20Looper%20X%20-%20User%20Guide%20-%20v1.0.0.pdf#page=15)
documents foot-operated function workflows. Transpose uses track pedals for
selection and other pedals for semitone changes. FX, Bounce, Fade and Reverse
have their own operating contexts. Segno adopts the complete foot journey as
the reference pattern. The Transpose mapping is owner accepted for Segno's
faceplate; unfinished workflows remain proposals. Neither establishes current
Segno audio implementation.

## LED state and color (owner clarification)

Each physical indicator has a configurable color. Illumination represents the
assigned function's active state: momentary on while held, toggle on until the
next activation turns it off. Releasing a toggle leaves its state unchanged.
Editing focus/selection does not change either the function or its indicator.

The LED observes confirmed function state after Press/Hold arbitration, including
state changes from other controls. It must not independently flip on every raw
press. Shared/inverse FX assignments observe the logical switch state rather
than assuming every controlled rack shares one bypass state. The choice of
state source when Press and Hold control different persistent functions remains
to be defined; no arbitrary priority is implemented in this study.

The main prototype demonstrates colors and momentary/toggle state through its
shared FX rig and Stage view. It has no audio or firmware dispatch. Colors currently
attach to the ten physical LEDs across banks; assignment-specific color rules
are not yet settled. Fixed footswitch actions and LED color editability are
separate concerns.

### Reusable custom colors

The owner requested a fully customizable palette. The LED page now supports
adding and editing custom colors with Hue, Saturation and Brightness controls.
Each saved custom entry is reusable across physical pedals. Editing that entry
updates pedals which use it; it does not change active, held or toggle state.
The color editor confirms into the setup draft, and the existing Save/Cancel
controls commit or discard that draft. Custom colors survive a reload. Touch,
encoder editing and cancellation use the shared control conventions.

## Interactive performance slice: entry, banks and Exit

The accepted A layout is integrated into the main **FX prototype**. Settings →
Pedals edits saved Press/Hold assignments and LED colors; **Stage** reads them.
This remains a silent interaction prototype without audio or physical controller
integration. FX performance uses the main editor's rack graph and logical pedal
states. It has no separate example-FX state model.

The implemented journey is normal Tracks → Custom → FX → Tracks, with a Mute
view to demonstrate the default Mode short press. Mode hold opens Custom without
briefly entering Mute. The prototype uses a proposed 800 ms hold threshold;
that value still needs physical foot testing. The [gesture-feedback proposal](2026-09-07-performance-feedback-ux.md) adds a thin
progress line below the physical pedal and brightens its existing Hold caption.
Encoder focus keeps its separate outline; LEDs remain state indicators.

Custom uses the saved assignments in each bank. Mode remains Exit. The default
Track 2 assignment enters FX. Four FX states appear at the track pedal positions;
Bank reaches the other four. Each assignment derives Toggle, Hold, or Toggle + hold from the racks mapped
to that logical pedal. Normal and inverse rules share its logical state. Their state is visible through the same hardware
indicators, using colors from the saved setup.

A toggle stays active across release, bank changes, leaving FX and returning.
A momentary activation captures its logical FX target when pressed; release
reaches that target after a bank change. Exit releases active momentary functions
and preserves latched states. A context change consumes held navigation gestures
so their release cannot trigger the new context's command. Cancellation or focus
loss cannot leave a momentary state on.

Mute uses the track pedal positions to toggle the corresponding prototype track's
muted state across both banks. Exit preserves those choices. Record/Play, Stop,
Undo, Clear and the remaining custom-function workflows are not operated in this
slice; their dimmed preview state is an explicit review limitation, not a target
product restriction. In particular, the proposed direct Stop requirement above
still stands and must be implemented when simulated transport is added.

Chrome and Firefox verify saved assignment entry, short/hold exclusivity,
Mute/Custom/FX/Tracks transitions, cancellation, bank behavior, LEDs, and release
after bank changes or Exit. Tests do not establish firmware timing, audio state
recall, touchscreen comfort, or DSP effect behavior.

## Main prototype persistence and review

The accepted setup and performance layouts live in `fx-ux-prototype.html`.
Pedal settings have one owner in the saved rig, separate from Loop settings.
Save commits the entire pedal draft; Cancel or leaving the setup discards it.
The LED palette never changes function state, and Stage uses saved colors.
Reload releases pending gestures and momentary states. Muted-track flags are
stored in the prototype rig; audible mixing is not implemented by these flags.

Accepted review routes: `pedal-setup`, `pedal-custom`, `pedal-leds`,
`pedal-leds-active`, `performance-tracks`, `performance-custom`, `performance-fx`
and `performance-mute`, plus `performance-transpose`, `performance-transpose-bank`,
`performance-transpose-empty` and `performance-transpose-limit`. Review URLs deliberately use repeatable fixtures;
normal navigation in the prototype saves to browser storage.

`verify_pedal_setup.cjs` and `verify_pedal_performance.cjs` exercise both Chrome
and Firefox, including reload, draft isolation, actual rack activation,
Press/Hold arbitration, state-driven indicators and release after bank/Exit.


## External pedals

The [External pedals study](2026-09-06-external-pedals-ux.md) now supplies the setup flow for both control jacks. Expression ranges, single/dual switch assignments, and fixed Track 1–8 targeting share one entry under Pedals. The owner requested an FS-6-style pairing for Tracks 5 and 6 while Bank A stays on Tracks 1–4. This is a fixed destination contract; no bank switch or touch interaction is required by the performance intent. The browser verifies target events, while production transport and dual-contact hardware remain open.


### September 8 surface and Mixer refinements

Normal prototype launch and reload enter the main Tracks view. The owner
accepted the current Track view. The separate Mixer draft now preserves track
name, bars, layers, FX state, level meter and progress beside its level, pan and
mute controls; this visual revision remains for review.

FX parameter overflow uses persistent separated scrollbars. The previously
accepted floating-arrow indicator is superseded by the owner's latest request.
Shared cards/dialogs and MIDI use the blue-gray palette; custom LED colors and
transport-state colors retain their independent meanings.
