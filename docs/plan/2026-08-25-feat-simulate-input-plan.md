# Simulate input — a mapping proves itself without the controller (#519)

Status: **design pinned in the pen (including the per-row case this issue
flagged as undrawn), mechanism decided here, implementation unstarted.** The
plan-gate was two questions: how a synthetic event enters the pipeline, and
what a per-row simulate does. The pen (via #603/#636, owner-confirmed on
master 2026-08-20) answers the second; this plan argues the first and asks the
owner to ratify it.

## Current state (verified against master, 2026-08-25)

Nothing can inject a synthetic controller event:

- `ControllerRepository`
  (`packages/controller_repository/lib/src/controller_repository.dart`)
  subscribes to its `sources` in the constructor; `_onInput` is private; the
  only public inputs are binding/mapping setters and the learn API.
- The only real source is `MidiControllerSource`
  (`packages/midi_client/lib/src/midi_controller_source.dart`), built by
  `createNativeMidiSource`
  (`packages/midi_device_repository/lib/src/native_midi_source.dart`).
- `ControlCubit` already holds the repository
  (`lib/control/cubit/control_cubit.dart:125,167` — `_controller`), so the
  drive side has its seam.
- The UI has no Simulate anywhere: the status card in
  `lib/control/view/midi_tray_body.dart` (~line 315) renders `midi_status` +
  the `midi_traffic` waiting/receiving line, and `_MappingRow`'s action row
  carries Relearn/Remove only. #516/PR #517 shipped every other part of the
  Control face and deliberately left this button out.

## The pinned design (from the pen)

- The open mapping's action row on `CONTROL / midi-sweep` and `midi-switch`
  carries its own **Simulate** pill — accent style, first, before Relearn /
  Remove.
- A **sweep** row simulates a LO → HI → LO ramp through the row's own curve,
  slow enough to watch the target move. A **switch** row sends a
  press/release pair through its own threshold and behaviour (Toggle flips
  once, Momentary holds and lets go).
- The status row's global **Simulate input** routes where a real event would
  land: a listening learn capture first, else the open row, else dimmed.
- The synthetic event enters through the `ControllerSource` seam **in the
  shape a real CC delivers — nothing downstream can tell the difference.**
- Recorded in `c/control-midi` / `c/midi-sweep` / `c/midi-switch`.

Pencil was unreachable this session; build step 0 is re-reading those three
screens for the pill geometry and the dimmed state. Nothing new needs drawing.

## Decision for the owner

**D1 — how the event enters.** Two candidates:

- **(a) `SimulatedControllerSource`** in `controller_repository`: a
  `StreamController<RawControllerInput>`-backed `ControllerSource` with a
  `push(RawControllerInput)` method, constructed at bootstrap and passed in
  `sources` alongside the MIDI source; the handle reaches `ControlCubit` the
  same way the repository does.
- **(b) a public `ControllerRepository.simulate(RawControllerInput)`**
  delegating to `_onInput`.

Recommend **(a)**. It is literally the pen's sentence — the event enters
through the `ControllerSource` seam — with zero repository API growth; the
repository provably cannot distinguish it (same `_onInput`, same learn
capture, same smoothing ramps, same `_learnIgnore` filtering); and it works
with no MIDI device attached, which is the entire point of the feature. (b)
is one line shorter to wire but grows the controller-truth boundary's public
surface with a test-shaped method the pen explicitly says this must not be.

Two derived calls the plan settles (flag if either feels wrong):

- **Timing** lives in `ControlCubit`, not the source: the cubit turns "simulate
  this row" into a timed CC sequence (injected ticker, like the repository's
  own `smoothing`/`smoothingTick` pattern, so tests drive a fake clock).
  Sweep pace: LO→HI over ~1.5 s, HI→LO the same — a taste number; the pen's
  "slow enough to watch" is the requirement, the constant is tunable.
- **Learn capture wins by construction**: a push while `isLearning` is
  captured exactly as a real input (that is what routing "to a listening learn
  capture first" means), no special-casing needed — the repository already
  does this in `_onInput`.

## Implementation outline

1. **`SimulatedControllerSource`** (new, `packages/controller_repository` —
   deliberately not `midi_client`; it has no MIDI dependency):
   `push(RawControllerInput)`, broadcast `inputs`, `dispose` closes. ~30
   lines.
2. **Bootstrap wiring**: where `ControllerRepository`'s `sources` list is
   assembled, add the simulated source; expose it to `ControlCubit` via
   constructor.
3. **`ControlCubit`**: `simulateMapping(String key)` — resolves the row's
   binding, then:
   - `ContinuousBinding`: emit the row's captured trigger as CC values
     ramping 0→127→0 on the ticker (the binding's own LO/HI/curve apply
     downstream, as they would to a real pedal — the cubit does NOT
     pre-apply the curve; the repository owns that math).
   - `DiscreteBinding`: one value above threshold, then one below (Momentary:
     hold between them for a beat of the ticker; Toggle: the pair flips once).
   `simulateStatusRow()` implements the global routing: learning → single
   representative push; else open row → `simulateMapping(openKey)`; else
   no-op (button renders dimmed).
4. **UI** (`midi_tray_body.dart`): Simulate pill first in `_MappingRow`'s
   action row per the pen; global button on the status card, dimmed when it
   has nowhere to route. Keys: `midi_simulate_<key>`, `midi_simulate_global`.

## Verification plan

- `controller_repository` test: a `SimulatedControllerSource` push produces
  the identical `ControllerBindingEvent` stream a real input does — pin the
  feature's core claim that downstream cannot tell; a push mid-learn is
  captured.
- `ControlCubit` tests under a fake ticker: sweep emits the full LO→HI→LO
  sequence through the repository; switch respects Toggle vs Momentary; the
  global route order (learning / open row / dimmed).
- Widget tests: pill order in the action row; dimmed global button; tapping
  simulate on a sweep row visibly moves the bound value (via the cubit fake).
- Goldens for the two row states; regen + eyeball.
- `dart analyze` + `bloc lint` clean (cubit methods return void).

## Acceptance criteria

- With no controller attached, tapping Simulate on a sweep row moves its
  target through the mapped range and back; on a switch row it fires the
  bound action per the row's behaviour.
- The global Simulate input feeds a listening capture, else the open row,
  else is visibly inert.
- Nothing downstream of `ControllerRepository` gained a test-only branch.
- The pills match the pen's placement and style.

## Non-goals

- A hidden debug/flag hook — this is shipped UI, first-class.
- Simulating the Segno pedal's own protocol (the on-screen pedal simulator
  exists; `_learnIgnore`/B8 filtering stays untouched).
- Pickup/catch takeover modes or new smoothing behavior — B9 as shipped.
- MIDI output or loopback devices.
