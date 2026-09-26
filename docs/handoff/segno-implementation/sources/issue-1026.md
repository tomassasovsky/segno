# #1026 Slice 4: shared assignments and foot performance [open]

Fourth slice of epic #1009 (implementation-map.md item 4), built on slice 3 (#1016, PRs #1017, #1018, #1020, #1021, #1022, #1024).

Accepted contract: `docs/handoff/segno-app/accepted-behavior.md` section 4 (built-in, custom, external, expression and MIDI controls), `docs/design/2026-09-07-pedal-mapping-catalogue.md`, `2026-09-08-pedal-closure-pass.md`, `2026-09-06-pedal-performance-contracts.md`, `2026-09-06-external-pedals-ux.md`, `2026-09-07-external-function-assignments-ux.md`, `2026-09-07-midi-controls-ux.md`, `2026-09-07-performance-feedback-ux.md`, `2026-09-09-optional-controls.md`, and the per-function performance docs (reverse, fade, speed, length, bounce, mixer).

Scope from the map: extend the controller binding models and target resolvers, keeping the ten-pedal faceplate and the protocol seam; add separate Press/Hold, fixed track targets, multiple mappings, external single/dual/expression setup, custom LED colours and the accepted foot-operated mode exits; implement Transpose, Reverse, Fade, Multiply, Divide, Peel, Bounce, Mixer and Speed **one complete native operation at a time**.

Accept: a configurable navigation/control Hold does not also execute its Press; normal Record/Play, Stop and track selection keep their immediate-contact behaviour; bank changes follow the agreed gesture target; momentary releases and toggle states drive LEDs; fixed external Tracks 5/6 work from Bank A; and every edit has its specified Undo.

## What the code actually has today

Mapped before splitting, so the parts land in dependency order rather than by guesswork.

**Eight of the ten performance operations do not exist in the engine at all.** Reverse, Speed, Fade, Transpose, Multiply, Divide, Bounce and foot Mixer level have no DSP and no audio-edit path in `packages/segno_engine/src/core` or in `looper_repository`. Peel exists, as one of the three meanings of `le_engine_undo`. Foot level control exists for the master gain only, from the rotary encoder. Three things sit nearby and must not be mistaken for the operations: the Octaver insert's real semitone pitch-shift DSP, the record-time loop-length multiple/divisor relationship, and the offline restore worker that republishes a track's PCM as one undoable layer — which is the generic seam the destructive edits should use.

**Press and Hold are not separable today.** `ControllerMapping.resolve` returns null for anything that is not a press, so release edges never reach the action path, and every hold in the product is hard-wired per physical button inside `ControlCubit` (undo, mode, bank, stop-in-FX). Any other switch fires its short action on the press and cannot retract it.

**Targets are addressed by index everywhere.** `Track` has no stable id, so "this fixed track" and "the selected track" cannot be expressed, let alone resolved by identity.

**One control carries exactly one action.** `MappingEntry` holds a single `LooperAction`, and `withBinding` replaces by trigger. Fan-out exists only for the opaque FX targets.

**The controller vocabulary is 7-bit MIDI Note and CC.** There is no source kind for a TRS switch or an analogue expression jack, and `MidiControllerSource._parse` drops Program Change, pitch bend, aftertouch and SysEx before the repository sees them.

## Two hardware gaps, recorded up front

**Per-pedal LED colour needs protocol v4, which is planned and not built.** The state frame addresses eight track channels plus one global colour; REC/PLAY, STOP, UNDO, MODE, CLEAR and BANK have no addressable byte, and there is no colour value type anywhere in the repository — the LED vocabulary is two small semantic enums whose hues live in the sketches. `docs/plan/2026-08-25-feat-pedal-custom-mode-protocol-v4-plan.md` has the bump.

**The v2 console's ten LED pills have no driver.** The Pi-side sender was removed in PR #98 and no Pico 2 firmware exists in the repository. The app-side colour model and the protocol can be built and tested; lighting a real console pill cannot be, and stays listed as not verified.

## Parts (each its own PR, in order)

- [x] 4a. Press and Hold as separate actions (PR #1027) (app + controller repository): a hold target beside the press target on every binding, holds driven by data rather than four hard-wired switches, a hold that does not first execute its press action nor act again on release in the newly opened mode, one cancellation point for every pending gesture on invalidating navigation, disconnect or configuration, and the take-lock applied to releases as well as presses.
- [x] 4b. Targets by identity (PR #1027) — the selected-track scope and target following. Several actions on one control moves to 4f (external buttons) and 4g (MIDI), where the accepted design puts it.
- [x] 4c. Pedals setup, Layout A (PR #1028) (app): the hardware map visible while editing the chosen pedal's Press and Hold together, fixed actions dimmed, the four track pedals edited as one group with A/B assignments, Save/Cancel drafts, Clear custom assignments with Restore inside the draft, and the shared action catalogue the built-in, external and MIDI pickers all draw from.
- [x] 4d. Custom controls, the fourth mode (PRs #1029, #1030) (app + pedal repository + firmware): protocol v4 unreserves the mode field's fourth value, and the mode the Custom map dispatches in lands on it — `_runAction` as the one interpreter of the shared catalogue, LEDs reporting which switch carries an assignment, and the accepted MODE default (Mute on the press, Custom on the hold). It closed the gap 4c opened: the foot has its path back to arming a performance recording. Tracked upstream as #763, whose direction was approved 2026-08-26.
- [x] 4e. LED colour (PR #1032) (pedal repository + firmware + app): protocol v4 with an addressable colour per pedal, a colour value type and a custom palette that can be added, edited and reused, momentary LEDs lit only while contact is held against toggle LEDs that stay lit, and colour configurable on all ten including the fixed-action pedals.
- [x] 4f. External pedals (PRs #1035, #1036, #1039, #1041, #1043, #1044, #1045) (controller repository + app): CTRL 1/2 as Expression, Single or Dual switch with independent hit targets, fixed Track 5/6 actions from Bank A, "Track N pedal" and "Select track N" as separate named actions, expression calibration including reversed wiring and drafted until saved, expression targeting several controls with individual heel/toe endpoints, and each external button mapping several controls with On/Off or Held/Released semantics.
- [ ] 4g. MIDI Learn formats (midi client + controller repository + app): Note, CC, 14-bit CC, NRPN, Bank+Program and relative CC as explicit captured formats rather than guesses from one byte, device and channel identity, source-overlap rejection even when disabled, and Control enable pausing remote assignments while preserving them and releasing held contacts.
- [ ] 4h. Reverse (engine + repository + foot): per-track playback direction toggled at the current position, speed and pitch unchanged, stopped stays stopped, the LED showing reverse and a small marker surviving Exit.
- [ ] 4i. Speed (engine + repository + foot): absolute half, one, two, four and eight times over the whole recorded loop with pitch coupled, repeated two times staying two times, Normal restoring only that factor, live inputs, backing and click unaffected.
- [ ] 4j. Fade (engine + repository + foot): a tap fading a track out or in, a tap mid-fade reversing continuously, a hold selecting its duration, a shared four-second default with optional per-track 0.5 to 30 second overrides, the saved Mixer level kept separate, and fades continuing after Exit.
- [ ] 4k. Transpose (engine + repository + foot): selection across banks, Undo and Clear moving one semitone, a hold on either resetting selection, range 12 semitones each way with timing unchanged, a global bypass that preserves stored pitches and selection, and Exit retaining changes.
- [ ] 4l. Multiply and Divide (engine + repository + foot): separately assignable on one selected track, Double repeating its material, First half or Last half retaining that region with no intermediate chooser, pitch and speed unchanged, omitted material recoverable through history, and incompatible mode lengths rejected rather than other tracks altered.
- [ ] 4m. Bounce and Peel (engine + repository + foot): sources selected across banks then a destination then an explicit Bounce or Replace and bounce, Keep or Clear sources and the tail choice visible, selection alone doing nothing, one Undo restoring the whole operation, and Peel wired to its own foot action rather than riding the undo stack silently.
- [ ] 4n. Foot Mixer, performance feedback and the optional controls (app): one channel at a time with Tracks driving loop playback level and Inputs live monitoring only, a hold muting without losing level, Undo and Clear stepping level and holds resetting unity, Bank paging four and a hold on Bank switching Tracks and Inputs, eighteen-input paging, the accepted feedback on both displays, touch lock and double-press Solo.

## Gates

Native suites in all five variants plus AddressSanitizer, telemetry-off and the C++ header shim; ffigen regeneration and formatting after any API edit; package and root tests at the CI coverage floors; `dart analyze` in each touched package; bloc lint; cspell; the existing control fuzzer and the firmware protocol suite; `/code-review` clean and CI green before ready-to-merge.

Physical footswitch and LED evidence is mandatory by the map and is out of reach here: the console's ten LED pills have no driver and the standalone pedal has LED hardware for only seven of its ten switches. Both stay listed as not verified.






---
## comment 2026-09-12T04:28:53Z

**4e is up as #1032**, stacked on #1031.

The open question #1031 left — how a configured colour combines with a fixed-action pedal's own signal — is answered by the design source rather than by a new decision. `accepted-behavior.md` section 4 puts it plainly: LEDs represent function state, and colour is configurable on all ten. The two pen scenes show it working: `03 / Pedals / LED colors` has every indicator dark on an idle rig in the normal mode, and `04 / LED colors — Toggle active` has MODE lit in its configured white and Track 1 lit in its configured blue while FX is engaged. The accepted prototype builds every indicator the same way — one colour from the palette, one boolean from the rig.

So state decides lit, the palette decides the hue, on the plate and in both sketches. `PedalStateFrame.isLit` is the one definition and `indicatorFor` is its firmware twin, held token-identical between the two sketches by the drift gate.

**The consequence is worth a decision of its own.** A lit track indicator no longer says whether the track is playing or recording — both are now that switch's own colour — and the default palette is white on all ten, so a performer who never opens the editor loses the green/red reading and gains nothing for it. If a live take should keep a hue of its own, that is a one-line precedence rule on top of what shipped, and better decided before a unit is flashed than after.

Still not verified: anything physical. The console's ten pills have no driver and the standalone pedal has indicators for seven of its ten switches.

Remaining in the slice: 4f external pedals, 4g MIDI Learn formats, 4h Reverse, 4i Speed, 4j Fade, 4k Transpose, 4l Multiply/Divide, 4m Bounce/Peel, 4n foot Mixer and performance feedback.

---
## comment 2026-09-12T05:36:31Z

**4f is three PRs, and the first is up as #1035** (stacked on #1034).

It covers the switch half: the jack model, the External pedals screen, and each button's Press and Hold — or its one On change, when the switch latches — from the shared catalogue. A jack keeps every type's assignments side by side, because plugging a dual pedal in for one song must not cost the single one what it carried.

The artwork is the study's generated art at 284 KB in WebP rather than the 2.6 MB the PNGs weigh. The switch centres are measured in the source raster, so the hit targets stay on the switch at any size.

**What the other two carry:**

- **Expression.** Calibration including reversed travel and a minimum span, and a list of destinations each with its own heel and toe. Out of the type picker until then: a type that opened an empty panel would be worse than one not offered yet.
- **The Controls panel and dispatch.** One button driving any number of FX activations and parameter values with On/Off or Held/Released, and the controller repository learning a source kind for a jack. It speaks MIDI Note and CC today, so nothing reaches these assignments yet and the contact indicator has nothing to report.

One thing worth recording from building it: `docs/design/pedal-hardware-widget.js` and most of `docs/design` are untracked, so a worktree cannot see them. That is what made part 4c draw the footswitch as a rounded rectangle, and #1034 fixes both the drawing and the four files it needed. The other 226 MB of that directory is still only in the working copy.

---
## comment 2026-09-12T17:03:25Z

## Part 4f, piece three: expression

[PR #1039](https://github.com/tomassasovsky/segno/pull/1039) — the wire numbers, the taught travel, and what a
sweep writes. Review-clean.

**An expression pedal arrives as an absolute Control Change**, one number per
jack, carrying the raw reading. Same two CTRL jacks a switch plugs into, same
link, different wire shape: a switch sends a Note, a pedal sends a CC. Both
protocol copies hold the numbers and the C contract suite pins them.

**7 bits of raw travel, and the cost of that stated rather than hidden.** The
inbound half of this link is 3-byte MIDI only, since segno's capture drops SysEx.
A higher-resolution position needs MIDI's 14-bit MSB/LSB pair and a
half-assembled value held between two messages, which moves the wire contract out
of the codec and into whatever holds that state. 128 raw steps is what a
commercial expression input delivers; the cost lands at the bottom of the
calibration range, where a span near the accepted 10% minimum leaves about 13
distinct positions. The accepted design leaves resolution and smoothing
unspecified, so nothing it settled has been overridden — but if the bench shows
stepping, the answer is a 14-bit pair on the wire, not anything the app can do
with 7 bits.

**Calibration is why the wire sends raw at all.** A pedal's electrical range and
its travel are not the same thing, and a pedal can be wired the other way round,
so the app is taught both ends. Reversed travel needs no special case. A travel
under the 10% minimum positions nothing rather than turning pot noise into a full
sweep. A jack calibrated but not yet assigned anything is not empty, on the same
rule the switch hardware already follows.

**Dispatch reuses part 4b's continuous model** rather than growing a second one:
one normalized target, resolved against the live rig, skipped when what it named
is gone and never repointed at whatever replaced it. Both continuous sources now
write through one method, because master gain has a second reader in the cubit
and a write that skipped the accumulator would make the next encoder detent jump.
Not gated on the take lock, which every switch path is: that lock stops a take
starting behind the power-off route, and sweeping a filter starts nothing.

## What 4f still has open

**The screen.** Expression stays out of the type picker until it exists: a type
that opened an empty panel would be worse than one not offered yet. That PR
carries the position readout, the calibrate view, the destination and parameter
picker, and the heel/toe editors — and with them the accepted rule that movement
during calibration does not dispatch, which needs UI state that has not been
built. A rule with nothing able to set it would be dead code today.

**The Controls panel.** One external button driving any number of FX activations
and parameter values, with On/Off or Held/Released conditions.

## One thing found on the way out

The inbound MIDI capture is not device-scoped, so the pedal path reads the wire
numbers off whichever single input is open, and a console board and a MIDI foot
controller cannot both be captured. Pre-existing and broader than 4f — a
keyboard's Note 4 already presses Track 1 — so it is now
[#1040](https://github.com/tomassasovsky/segno/issues/1040) rather than a decision taken here. It needs a product
call: is a third-party controller meant to work alongside the board or instead of
it.


---
## comment 2026-09-12T17:41:21Z

## Part 4f: expression is complete

[PR #1041](https://github.com/tomassasovsky/segno/pull/1041) is the screen, on top of [#1039](https://github.com/tomassasovsky/segno/pull/1039)'s wire and dispatch.
Both review-clean. The type picker now offers Expression, because there is
something behind it.

**Four bodies, one page, one draft.** The accepted design draws the calibration
and both pickers as whole views rather than panels, since the lists behind them
are as long as the rig is. Back steps through them, and Save appears only on the
main body.

**The meter and the number say different things.** The meter shows the raw
reading whether or not the pedal has been taught anything, so a performer can see
the jack is alive. The number shows the position in the taught travel and shows
nothing until there is a travel to measure against. A jack that has reported no
position reads as not connected, which is only honest because the protocol header
now obliges the board to report each jack once at link-up.

**Teaching is a draft of a draft.** Use calibration stages, Save commits, a
travel under the minimum is refused where the performer is standing, the captures
are discarded when the link drops, and sweeping to teach the ends writes nothing.

**Choosing reuses part 4b's targets** rather than growing a second catalogue. A
track's fader and the effects on its whole-track chain are one destination. The
kinds are the Effects page's own. A control already swept is offered and refused,
not hidden. Repointing keeps the endpoints.

## Two things the pen draws that are not built, and why

**The 52 x 68 illustration on each mapping and destination row.** The study's
icons come from the extracted Looper X factory images, which were already
rejected for shipping over resolution and visible branding, and no surface in
this app draws effect icons. This one needs a decision: generate a set of
unbranded destination and effect illustrations the way the three pedal pictures
were generated, or accept text-only rows. I have left it text-only.

**Double-tap to reset an endpoint, and encoder editing of a value.** Both are in
the accepted design and neither exists anywhere on this console: no slider
implements a double-tap reset, the app's shipped idiom for that is an explicit
button, and settings pages have no encoder-focus model at all. They belong to a
change to the shared slider and to that model, not to this screen. Worth its own
issue when the encoder story is taken up.

## What is left in 4f

**The Controls panel.** One external button driving any number of FX activations
and parameter values, with On/Off or Held/Released conditions. That is the last
piece of this part.


---
## comment 2026-09-13T05:10:06Z

## Part 4f is complete

The Controls panel shipped in two PRs on top of the expression screen, both
review-clean:

- [#1043](https://github.com/tomassasovsky/segno/pull/1043): what a button's controls **do**.
- [#1044](https://github.com/tomassasovsky/segno/pull/1044): the panel that edits them.

**Two facts about a button feed its controls.** ON / OFF is logical: each completed
press flips it, a latching switch sets it to its contact, and it survives a
restart under its own settings key, apart from the setup, because Cancel on the
setup screen must not undo a stomp. HELD is physical: the contact is closed right
now. An effect is active On, Off, Held or Released; a parameter switches between
two values on On / Off or Held / Released.

**The accepted rules, each tested and mutation-checked.** With no Hold, a press
flips the button on contact; with a Hold, only a completed short press does, and
running the Hold does not. Held and Released follow the contact without waiting
for the hold threshold, and are refused on a latching switch. Writes are
edge-triggered: saving, opening the screen or connecting writes nothing. A button
the active type does not have writes nothing, so an Off control cannot turn a
missing source into an active effect. Disconnect and Save end a hold and apply
Released, and the foot has to lift before it counts again. A new parameter starts
at its current value on both sides.

**One departure from the design's storage.** The design keeps an effect's
activation rule on the rack. This app has no rack activation rule, and every other
source that toggles an effect carries its binding on the source, so this one does
too. The behaviour is the same; if a rack-owned rule is ever built, this binding
moves onto it.

**Shared now:** one control row and one list for every list on the External
pedals screen, which keeps the open row in view without fighting a performer's
scroll, and the design's overflow arrow, which no list had.

## Still open from 4f, all recorded above

- **Per-row illustrations** on mapping and destination rows need an owner call:
  generate unbranded icons, or keep text-only rows.
- **Double-tap reset and encoder editing** of a value exist nowhere on this console
  and belong to the shared slider and an encoder-focus model.
- **[#1040](https://github.com/tomassasovsky/segno/issues/1040):** one MIDI input is captured at a time, which needs a product call.

Next is **part 4g, MIDI Learn formats**.


---
## comment 2026-09-13T10:47:40Z

## Row pictures: decided and built

Owner call: the rows use the **Looper X factory illustrations for now**, the ones
the Effects page already draws from `fx_catalogue`. No generated artwork.

[PR #1045](https://github.com/tomassasovsky/segno/pull/1045) draws them on every External pedals list: a parameter or effect
shows its pedal, a chain that is exactly one rack shows the rack, and faders and
the master show nothing, as the pen draws them. This closes the open item from the
expression screen and the Controls panel.

Still open from 4f: double-tap reset and encoder editing of a value (shared
slider and encoder-focus work), and [#1040](https://github.com/tomassasovsky/segno/issues/1040).

Next: part 4g, MIDI Learn formats.


---
## comment 2026-09-13T11:03:42Z

## Part 4g: plan

The accepted design (`2026-09-07-midi-controls-ux.md`, `2026-09-09-optional-controls.md`, pen sections 26 and 53) is a rebuild of MIDI control, not an addition to it: one mapping is one source with any number of targets, mappings can be disabled, the source carries its device, channel and explicit format, and it is edited on a new Settings → MIDI controls page. Three PRs, each leaving the product working:

1. **[#1047](https://github.com/tomassasovsky/segno/pull/1047) — done.** Program Change captured natively; `MidiProtocol` / `MidiSource` / `MidiDecoder` read the five formats explicitly and state overlap. Also closes a learn-hygiene gap: the CTRL jacks' Notes and CCs were learnable.
2. **The mapping engine** (`controller_repository`, pure): mappings with parameter and action targets; absolute pickup, relative stepping, momentary and toggle buttons, Program triggers; overlap refused even against a disabled mapping; Control enable pausing dispatch and releasing held values; reconnect clearing contact, pickup and latch state without synthesizing actions; Learn in an explicit format that ignores note-off. No UI yet; nothing reads it.
3. **The page and the switch-over** (app): the MIDI controls page as the pen draws it, the cubit dispatching the engine's writes and actions, and the old `ContinuousBinding` / `DiscreteBinding` model and the Control tray's mapping editor removed rather than kept beside it.

One constraint carried from #1047's review: the engine reads the undebounced message stream, because 14-bit and NRPN pairs repeat faster than the 30 ms footswitch debounce.

The design lists several devices at once. The app captures one MIDI input at a time (#1040), so a mapping from a device that is not the open one simply does not dispatch; device identity in the source keeps that correct whichever way #1040 is decided.

