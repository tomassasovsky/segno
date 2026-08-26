# Custom pedal mode + protocol v4 — scope and the direction calls (#763)

Status: **plan for the owner's direction call.** The protocol cost of a fourth
mode is already known and small; the open question is entirely a product one —
what a custom switch may be bound to. This document pins what exists (most of
"custom mode" already shipped under another name), argues the wire change down
to its minimum, and puts exactly four decisions in front of the owner.

## Current state (verified)

### The wire has one free-looking slot, and it is deliberately not free

The interaction mode is a 2-bit field since v3: low bit in flags bit 0, high
bit in bit 1 of the active-bank byte. The fourth value (`0b11`) is
reserved-and-rejected on decode by **both** codec copies:

- `packages/pedal_repository/lib/src/pedal_codec.dart` — `decodeFrame`
  rejects `modeIndex >= PedalMode.values.length` (and the doc comment at the
  top names value 3 as reserved);
- `firmware/segno_pedal/pedal_protocol.c` — `pedal_decode_frame` rejects
  `mode >= PEDAL_MODE_COUNT` the same way, with the byte-for-byte mirror in
  `hardware/firmware/segno_pedal_32u4/` held identical by the
  `firmware/test/run_tests.sh` drift gate.

So a fourth mode **cannot ride v3**: every deployed v3 decoder rejects the
whole frame. That is the entire reason "custom mode" implies "protocol v4",
exactly as #442's plan comment recorded ("the v3 mode field's fourth value is
reserved and rejected on decode, so it is not a free slot").

### The pedal is a thin client, so "custom" is almost entirely app-side

`firmware/segno_pedal/segno_pedal.ino` opens with the load-bearing sentence:
the pedal holds **no** looper state — it renders LEDs from the last good frame
and sends raw Note/CC events. What a footswitch *does* has never lived in
firmware; `ControlCubit` interprets every press. A "fully user-defined mode"
therefore needs from the wire only (a) a fourth mode value so the pedal's MODE
LED can *say* custom, and (b) nothing else.

### Most of the machinery already shipped as FX-mode bindings

The switch-behavior scope cut from the FX screen redesign (named in #763's
body as never-tracked) has in fact largely landed since, as parts of the FX
v3 train (verified on master):

- `lib/control/binding/pedal_binding.dart` — `PedalBindingKey` keys a binding
  per button, per bank for track buttons (A3); MODE and Bank are structurally
  unbindable (B12); `BindingBehavior` toggle/momentary is shared with discrete
  MIDI controllers via `controller_repository`.
- `lib/control/binding/fx_binding_target.dart` — sealed targets: a whole
  chain or one slot, canonical-JSON encoded, `tryParse` never throws.
- `lib/control/cubit/control_cubit.dart` — `_pressBinding` runs
  toggle/momentary with the B1 momentary discipline (`releaseAllMomentary` on
  mode exit / binding change / disconnect), and a stale target is a no-op
  (R25).
- `lib/control/control_projection.dart` — a bound switch's LED reports its
  own target (`boundChains`), costing **zero wire bytes**: the same
  `trackLeds` byte means something different per mode and the firmware renders
  it verbatim (R8).

What does NOT exist: a mode where this is the *whole* story. In FX mode every
unbound control has a contextual default (track buttons stomp track chains,
Stop is FX panic, Rec/Play/Undo/Clear deliberately inert —
`lib/looper/model/interaction_mode.dart`), and the binding vocabulary is FX
only. There is no fourth `InteractionMode` member, no custom binding set, no
persistence key for one, and no way to bind a switch to anything that is not
an FX chain/slot.

### Version plumbing is ready for a fourth version

- `PedalRepository.targetProtocolVersion`: unknown ⇒ v2 floor (R6,
  test-pinned), simulator ⇒ `protocolVersionMax`, an explicit version wins.
- `PedalCubit._applyFirmwareVersion` is the single seam every version source
  routes through (manual picker today, identity-reply discovery later).
- The firmware already reports `PEDAL_PROTOCOL_VERSION` in its identity
  reply's revision byte 0 — but segno's 3-byte input capture cannot receive
  SysEx, so discovery stays manual until an inbound SysEx path exists
  (recorded in `PedalBindStatus`'s doc comment; #331 closed with that seam
  still deferred).

### Where console board v2 sits

#752 collects the firmware contract the fab-ready Pico 2 board imposes; no
Pico 2 firmware exists in the repo yet, and the Pi-side UART `PedalTransport`
was an explicit non-goal of the board v2 plan. Both will consume the same
plain-C protocol unit (`firmware/segno_pedal/pedal_protocol.{h,c}`). That is
what "v4 lands once" means concretely: bump the shared unit + fixtures now,
and the Pico 2 bring-up speaks v4 from its first compile — no second protocol
change when the board arrives. #369 contributes nothing to v4 either way: the
indicator-chain work needs **no wire change** (see its companion plan).

## Decisions for the owner

### D1 — what can a custom switch be bound to? (the product call)

- **Option A — FX targets only, clean slate.** Custom = FX-mode bindings with
  the contextual defaults removed. Cheapest; but it is FX mode minus
  features, and #442 promised "fully user-defined".
- **Option B (recommended) — FX targets + a closed vocabulary of named app
  actions.** The sealed target type grows a second arm: actions the app
  already exposes as one-shot commands (undo, redo, clear-all, stop-all,
  tap-tempo, track arm/select). Rack-load targets join the same vocabulary
  when #535 ships — the encoding is canonical-string like `FxBindingTarget`,
  so the arm is additive. This is what "custom" plausibly meant in #442, and
  every action already has a tested dispatch path in `ControlCubit`.
- **Option C — full controller parity** (encoder rebinding, arbitrary MIDI
  out). Overreach: the pedal is a looper surface, not a generic MIDI
  controller, and nothing in #442 asks for it.

### D2 — wire shape of v4

- **Option A (recommended) — zero growth.** v4 = version byte 0x04 + mode
  value 3 accepted. Payload stays 17 bytes; the six console pills and the V1
  pedal's seven indicators are all driven by bytes the frame already carries,
  with per-mode meaning (the R8 precedent: FX mode already re-reads
  `trackLeds` without a new byte). Custom-mode LED feedback for bound track
  switches rides `trackLeds` exactly as FX bindings do today.
- **Option B — per-button LED payload growth** (10 explicit LED bytes). Pays
  wire bytes for feedback no hardware can show: V1 has no transport
  indicators, and the v2 faceplate deliberately dropped them (#792 — six
  pills: TRACK1–4, CLEAR, BANK). Rejected.

Degrade policy (part of D2, either option): encoding a custom-mode frame at
target ≤ v3 writes the mode as **play** (mute) — the same B10 projection FX
mode uses, chosen because mute is the inert-safe render. This only affects the
MODE LED on an un-reflashed pedal; button *behavior* is app-side and works in
custom mode regardless of what the pedal displays.

### D3 — negotiation and migration

- **Option A (recommended) — manual now, discovery later.** The existing
  firmware-version picker gains v4; unknown stays at the v2 floor (do not
  touch `PedalCodec.protocolVersion`); the simulator speaks max and renders
  custom immediately. Identity-reply discovery remains deferred until an
  inbound SysEx path exists — and the future v2-console UART transport should
  be built SysEx-capable from day one so discovery is free there.
- **Option B — build the inbound SysEx path first.** Sequencing a transport
  rework in front of a product feature, for a handshake the manual picker
  already covers. Rejected for now.

Migration: none. Bindings persist as canonical strings already; the custom
binding set is a new persistence key, absent ⇒ empty. No stored data changes
meaning.

### D4 — where custom sits in the mode cycle

Recommended: MODE stomp cycles rec → mute → fx → custom → rec; custom is
excluded from boot defaults exactly as FX is (R12 — booting into an unbound
custom mode is a dead surface). Alternative (skip custom in the cycle while
its binding set is empty) adds a modal cycle length for marginal benefit;
noted, not recommended.

## Implementation outline (PR slices)

1. **Protocol v4, codec-only** — `pedal_codec.dart` (accept/encode mode 3 at
   v4, `protocolVersionMax` → v4, degrade paths), `pedal_protocol.{h,c}` +
   32u4 mirror (`PEDAL_PROTOCOL_VERSION_V4`, `PEDAL_MODE_CUSTOM`), new golden
   fixtures (`custom_mode_v4.syx`, plus a v3-degrade fixture), contract-test
   arms in `firmware/test/test_pedal_protocol.c`. Fully verifiable here;
   `autonomy:auto` material.
2. **Firmware render** — `modeColor()` gains a fourth arm in both sketches
   (the run_tests.sh color-mapping gate holds them identical); pick the color
   in lockstep with `_modeColor` in `lib/pedal/view/pedal_plate.dart` — amber
   is the free slot (red/green/blue are taken; `GlobalColor.amber` already
   exists on both sides). Host-testable; physical color check is
   blocked-verify.
3. **App domain** — `InteractionMode.custom` (+ token, R12 boot exclusion,
   cycle), `PedalMode.custom`, the custom binding set (model + persistence +
   `ControlCubit` dispatch: bound ⇒ run binding, unbound ⇒ inert), projection
   (`projectFrame` mode + custom-mode `projectTrackLed` arm), invariant-spec
   rows. `autonomy:merge-gate` — behavior taste.
4. **Action targets (D1 option B)** — the sealed action-target arm + dispatch
   + labels. Separate slice so slice 3 ships on FX targets alone if D1 lands
   as option A.
5. **Assignment UI** — custom-mode tab on the existing assignment surface
   (`lib/pedal/view/pedal_assignment_page.dart`). `merge-gate`.

Deferred, tracked elsewhere: rack targets (#535), identity discovery /
inbound SysEx, Pico 2 firmware + UART transport (#752's successors).

## Verification plan

Runnable here, per slice:

- `bash firmware/test/run_tests.sh` — drift gate over both protocol copies +
  golden round-trip of every fixture, new v4 fixtures included, plus the
  sketch color-mapping gate for the new `modeColor` arm.
- `/Users/Tomas/development/flutter/bin/flutter test` — codec goldens
  (`pedal_codec_golden_test.dart`), the R6 floor pin, repository/cubit/
  projection tests; the simulator plate renders v4 end-to-end on screen.
- `dart analyze` clean; `bloc lint lib test packages` clean.

**Blocked-verify** (a human with the hardware): the mode LED's amber on the
real 32U4 pedal, degrade behavior on an un-reflashed (v2/v3) pedal, and stage
feel of momentary bindings under custom mode. Everything wire-level is proven
here by the contract tests; nothing about *rendering* on real LEDs is.

## Acceptance criteria

- A v4 frame with mode value 3 round-trips byte-identically through both C
  copies and the Dart codec; a v3 frame with mode 3 is still rejected.
- Unknown firmware still encodes at v2 (the pinned floor test stays green);
  explicit v4 and the simulator encode custom mode on the wire.
- Custom mode: bound switches run their bindings with toggle/momentary + B1
  + R25 semantics; unbound switches (MODE and Bank excepted) do nothing.
- MODE LED says custom distinctly on plate and firmware (lockstep colors,
  gate-enforced); pre-v4 targets render custom as mute, never a dark pedal.
- All four verify-loop commands green.

## Non-goals

- No payload growth, no new message types, no negotiation channel.
- No encoder rebinding, no MIDI-out vocabulary, no generic-controller parity.
- No rack targets until #535 lands (the target encoding leaves the arm open).
- No Pico 2 firmware or UART transport work (#752), and no indicator-chain
  changes (#369's companion plan — explicitly decoupled).
- No pedal-firmware OTA (the #331 remainder).
