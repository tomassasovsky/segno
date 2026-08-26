# Widening indicatorLeds 7 → 10 — the premise died in hardware (#369)

Status: **plan recommending a rescope, not a build.** #369 asks for an LED
pill on every pedal (7 → 10). Between its filing and today, the owner decided
the opposite and that decision is already manufactured into the v2 console.
This document verifies what today's hardware actually has, shows the wire
protocol needs nothing either way, and asks the owner to bless the rescope
rather than letting the stale 7 → 10 framing drive firmware work.

## Current state (verified)

### What the hardware actually has today

- **V1 console (manufactured, Pro Micro/32U4):** one 19-pixel WS2812 chain on
  D2 — loop ring 0–11 + seven indicators 12–18 (mode, track1–4, clear, bank)
  — driven by `firmware/segno_pedal/segno_pedal.ino` (`kNumLeds = 19`) and
  documented in `hardware/segno_pedal_pcb_design.md`
  (`FastLED.addLeds<WS2812B, 2, GRB>(indicatorLeds, 7)`). Unchanged, still
  correct for that board.
- **V2 console (board fab-ready, faceplate landed in #792):** the all-ten
  pills #366 trialed were **reversed by owner call 2026-08-21** —
  `hardware/enclosure/segno_enclosure.py` now says it outright:
  `NO_LED_PEDALS = ("REC/PLAY", "STOP", "UNDO", "MODE")`, "a per-pedal status
  light has nothing to report" for fixed-function transports. **Six** pills
  survive: TRACK1–4, CLEAR, BANK — note that is a *narrowing* from V1's
  seven: the MODE pill is gone too (mode lives on the screens).
  `hardware/MANUFACTURING.md` ships **6** LED pucks, "one per *mappable*
  pedal — the four fixed-transport pedals carry none."
- **V2 board topology:** the ring and the indicators are separate circuits —
  `hardware/kicad/console_board.py` puts RING_DATA on GP12 (J6, with the
  encoder) and IND_DATA on GP18 (J7). The pucks daisy-chain off J7; the
  Ring 24 hangs off J6.
- **No v2 firmware exists.** #793 already tracks the reference driver's
  stale constants (`firmware/led_driver/led_driver.ino`: ring 12 +
  indicators 8, vs the actual Ring 24 + 6 pills), notes there is no Pi-side
  sender, and flags the single-strip-with-offset assumption. With separate
  data pins on the Pico 2, that assumption is not just stale — it is
  structurally unnecessary.

### What the wire protocol carries

Nothing about the indicator chain crosses the wire as a *count*. The v3 state
frame already carries every datum six (or seven, or ten) pills could render:
`trackLeds[8]` (both banks), `activeBank`, `clearFadeActive`, the mode, the
global color (`packages/pedal_repository/lib/src/pedal_codec.dart`,
`firmware/segno_pedal/pedal_protocol.h`). The chain length is a
firmware-local constant; V1 proves it — its firmware maps the same frame onto
7 indicators, rendering the active bank's four tracks
(`base = active_bank * 4`). Ten pills would ALSO have needed no new bytes:
the three "new" positions #369 named (REC/PLAY, STOP, UNDO) were transport
state the frame's global color and mode already carry. **There is no
protocol-v4 dependency in either direction**, and #253's surviving mapping
question collapses to "V1's map minus the mode pill."

## Decision for the owner

- **Option A (recommended) — rescope #369 to the six-pill reality and fold
  execution into the Pico 2 firmware bring-up.** Retitle/rescope the issue to
  "v2 console indicator chain: 6 pucks off J7", covering: the index map
  (proposal below), the two-strip structure, and constants. The actual code
  lands inside the Pico 2 firmware work #752 gates — where #793's ring-count
  fixes land too — because until that firmware exists there is nothing to
  edit. #369 stays the tracker for the *decision*; #793 stays the tracker for
  the reference-driver constants.
- **Option B — close #369 as overtaken** (by the 2026-08-21 owner call) and
  let #793 + the Pico 2 bring-up carry everything. Cleanest board, but the
  index-map/topology decision loses its only home until a firmware issue
  exists, which is how #763's scope went untracked for months (#442's
  history).
- **Option C — build the widening as filed (10 pills).** Rejected: it
  contradicts an owner call that is already cut into the shipped faceplate
  generator, BOM, and puck count, and would re-add indicators the design
  argues are noise ("LEDs only where they mean something", #792).

Recommended index map (v2, chain off J7, faceplate left → right):
`0–3 = TRACK1–4, 4 = CLEAR, 5 = BANK` — V1's order with the mode pill
removed, so the two firmwares' render loops stay diffable. Semantics
unchanged from V1: tracks render `trackLeds[activeBank*4 + i]` (per-mode
meaning per R8), CLEAR renders `clearFadeActive`, BANK lights on bank B.

Second, smaller call, bundled here: **keep ring and indicators as two
independent strips** (two data pins, two pixel buffers) rather than one
logical chain with an offset. The board already paid for the second pin; the
offset arithmetic is exactly what #793 caught addressing pixels past the end
of the physical chain. Recommended: two strips.

## Implementation outline

Under option A, in order:

1. **Now (this rescope):** #369 retitled + relabeled; the index map and
   two-strip decision recorded on the issue; #253's closure comment already
   points here and stays valid.
2. **With the Pico 2 firmware bring-up (gated on #752's board existing):**
   `IND_LEDS = 6` and the map above on GP18; `RING_LEDS = 24` on GP12 (the
   #793 fix); render from the same decoded `pedal_frame` the 32U4 uses — the
   shared `pedal_protocol.{h,c}` unit decodes it, so the contract tests
   already cover the only cross-machine surface.
3. **Console side:** none. The projection (`lib/control/control_projection.dart`)
   already emits everything the six pills render; no Dart change, no codec
   change, no fixture change.
4. **V1:** untouched. Its seven-indicator map stays correct for its
   manufactured board.

## Verification plan

- `bash firmware/test/run_tests.sh` — proves the protocol surface is
  untouched (drift gate + golden round-trips must pass with zero fixture
  changes; a diff here means this work leaked into the wire, which is a bug).
- `/Users/Tomas/development/flutter/bin/flutter test`, `dart analyze`,
  `bloc lint lib test packages` — all expected no-op green for the rescope.
- **Blocked-verify (all the actual behavior):** the six pucks lighting in
  chain order, diffuser brightness, and ring/indicator independence need the
  assembled v2 console — no Pico 2 firmware, no board in hand, nothing
  host-testable. This is why execution folds into the bring-up rather than
  shipping speculatively now.

## Acceptance criteria

- #369 no longer claims 7 → 10 anywhere a builder would read: rescoped (or
  closed) per the owner's pick, with the index map + two-strip decision
  recorded.
- The pedal wire protocol is untouched: no version bump, no fixture churn,
  and #763's protocol v4 carries zero indicator-chain scope.
- The eventual Pico 2 firmware renders 6 indicators + Ring 24 from the
  standard decoded frame with the map above (verified on hardware, later).

## Non-goals

- No protocol change of any kind — this does not fold into protocol v4
  (#763), explicitly.
- No V1 firmware or board changes; no re-adding transport pills.
- No Pico 2 firmware written now (nothing to verify without the board);
  no resurrection of `packages/led_client` (#793 records the recovery path).
- No enclosure/BOM work — #792 already landed the six-pill faceplate, pucks,
  and diffusers.
