---
date: 2026-08-17
topic: console-board-v2
---

# Console board v2 — RP2350 board on the Pi's GPIO, carrying the rear-panel I/O

Tracking: [#747](https://github.com/tomassasovsky/segno/issues/747). Supersedes the
daughterboard half of [#746](https://github.com/tomassasovsky/segno/issues/746).
Depends on the rear panel from [#743](https://github.com/tomassasovsky/segno/issues/743).

## What We're Building

A second control board for the **10-pedal console only**, replacing the arrangement
where a Pro Micro talks to the Raspberry Pi over USB. The new board lies flat on the
bottom plate beside the Pi, connects to the Pi's 40-pin header by a short ribbon,
and carries a **Pico 2 (RP2350)** module, the **MIDI front end**, and JST headers for
every rear-panel connector and every pedal.

The manufactured V1 board is not wasted: it remains the **standalone pedal** product's
board, which is what it was designed for. Only the console moves to v2.

## Why This Approach

**The forcing problem.** The Pi 5's four USB-A ports are exactly consumed — two
touchscreens, two rear-panel couplers — and a hub was ruled out. So the Pro Micro
cannot have a USB port. Its only hardware UART (`Serial1`, D0/D1) is already the
DIN-5 pair, and the ATmega32U4 has no second one. Every path out of that requires
new hardware, so the question became *what* new hardware.

**Approaches considered:**

- **SysEx-multiplex onto the existing MIDI UART** (#746 option A). No new board, but
  pedal frames physically leave the DIN MIDI OUT jack, and Pi → Pro Micro needs a
  merge gate the built board does not have (`midi_in_opto += uart_rx`, "no merge gate").
  Rejected: a hack on a wire that is supposed to be standards-compliant.
- **Small MIDI daughterboard + keep the Pro Micro** (#746 option B). Correct, and was
  chosen — but it leaves three boards, two MCUs' worth of wiring and a link that
  exists only to work around a USB shortage.
- **One board on the Pi's GPIO** (this doc). Same parts count as option B, but they
  land on one PCB that also terminates the harness. **Chosen.**

**Why an MCU stays.** This was not a preference. `rpi_ws281x` drives PWM/PCM+DMA on
the legacy peripherals and **does not support Pi 5**, whose I/O moved to the RP1
southbridge. SPI bit-encoding works but burns SPI0 and is jitter-prone under load.
The repo had already reached this conclusion: `firmware/led_driver/` is an RP2040
WS2812 offload driver written precisely to keep that timing off the Pi. A board with
no microcontroller was never on the table.

**Why RP2350 rather than another 32U4.** PIO makes WS2812 exact — the entire reason
`led_driver` targets that family. Its ADC solves CTRL 1/2 for free (below). It has
GPIO to spare for 10 footswitches plus two UARTs. And one MCU replaces *Pro Micro +
a separate RP2040 LED driver*: the two firmwares merge into one program.

## Key Decisions

- **Pico 2 (RP2350) module, not a bare chip.** Same 51 × 21 footprint and pinout as
  the Pico, so the board is identical either way, but with headroom that costs
  nothing now and avoids a respin later. A module also keeps the board
  **hand-solderable** — no QSPI flash, crystal, USB or BOOTSEL design work, and a
  dead part is a five-minute swap. This matches V1's stated "mostly through-hole /
  hand-solderable" philosophy.
- **Flat board on a ribbon, not a HAT.** A 65 × 56.5 HAT does not fit the I/O:
  18 connectors need **158 mm of board edge** against **192 mm usable** (243 perimeter
  less 51 for the header) — 82 % consumed — before placing the module (1071 mm², 29 %
  of the board), the AHCT125, the opto, ~15 passives and four mounting holes. A flat
  ~130 × 90 board puts the module at 9 % of area with edge to spare. It also keeps the
  Pi's Active Cooler airflow clear and the NVMe and SD card reachable.
  *Only ~11 signals cross the ribbon* — two UART pairs, SWD, 5 V, 3V3,
  GND — so a 2×20 IDC is generous.
- **Footswitches stay on the MCU.** Debounce and timestamping stay out of Linux
  userspace, so jitter is bounded; the existing firmware and pedal protocol already
  work this way. (There is already an open issue about shaving ~8 ms off footswitch
  latency — moving debounce onto the scheduler would go the wrong way.)
- **MIDI terminates on the Pi's UART**, with the opto and buffer on this board. The Pi
  runs the looper, so MIDI clock and sync timing sit on the same machine as the
  engine, with no extra hop to re-timestamp across.
- **CTRL 1/2 needs no expression-vs-switch decision.** Tip → RP2350 ADC with a
  pull-up: a pot reads mid-scale, a TS switch reads rail-to-rail. Both pedal types
  work on the same jack and firmware can auto-detect. On the Pi this would have forced
  a separate ADC chip.
- **SWD from Pi GPIO**, so the Pi can reflash the MCU with openocd during a normal
  system update. Three wires and a 3-pin header. The MCU is buried under the 16"
  screen and the pedal firmware is the part most likely to keep changing — this is
  cheap now and painful to retrofit.
- **Power button goes straight to the Pi's own PWR pads**, not through the MCU and not
  through a GPIO. Clean shutdown keeps working when the MCU is wedged or mid-reflash,
  which is exactly when it is needed — and on a Pi 5 a GPIO cannot do this job at all:
  RP1 and the SoC are unpowered until the PMIC brings them up, so nothing on the 40-way
  can wake the machine. The button reaches the two solder pads beside the RTC connector
  (board J8 → J9).
- **The external potted buck stays.** The eleUniverse 8–36 V → 5 V 10 A IP67 brick
  already feeds the Pi and both screens; the board just takes 5 V in. ~5 A of
  switching regulator on a hand-built THT board is real design work that is already
  solved.
- **The ring/encoder board stays separate.** `ring_board.py` is unchanged — EC11 +
  12 WS2812 behind the faceplate's ring window, reached by one 8-pin JST cable. It
  physically cannot join a board on the floor.

## Board content

| block | parts |
|---|---|
| MCU | Pico 2 (RP2350) on 2×20 THT headers |
| Pi link | 2×20 IDC ribbon → UART ×2, SWD, 5 V, 3V3, GND (not the power button — see below) |
| MIDI IN | H11L1 at **3.3 V** → Pi uart0 RX · 220 Ω · 1N4148 · DIN pin 2 **not** connected |
| MIDI OUT | 74AHCT125 ← Pi uart0 TX · 2 × 220 Ω |
| Footswitches | 10 × JST-XH 2-pin, 100 nF RC debounce (as V1) |
| CTRL 1/2 | 2 × JST-XH 3-pin → ADC with pull-up |
| Indicators | 1 × JST-XH 3-pin, WS2812 chain via 74AHCT125 3V3→5 V |
| Ring/encoder | 1 × JST-XH 8-pin to `ring_board` |
| Power button | 1 × JST-XH 2-pin → the Pi's own PWR pads (J9), not a GPIO |
| Power in | 1 × JST-XH 2-pin, 5 V from the external buck |

Level shifting follows [`segno_wiring.md` §2b](../../hardware/segno_wiring.md): the
5 V → 3.3 V direction is the dangerous one and gets a divider; the 3.3 V → 5 V
direction merely needs the AHCT125's TTL-level inputs. **MIDI IN needs no shifter** —
the H11L1 is a Schmitt *logic-output* opto, so running it at 3.3 V feeds the Pi
directly.

## Open Questions

- **Indicator count.** The console design has a pill above every pedal (10, #366) but
  the firmware contract is `indicatorLeds[7]`. v2 is the natural moment to widen it —
  needs confirming as in-scope for this work or split out.
- **Pedal protocol version.** `pedal_protocol.h` is at v3; a v4 is referenced by epic
  #442. Whether v2 ships against v3 or waits for v4 needs settling before firmware.
- **Pi UART overlay mapping.** `uart0` = GPIO14/15 is certain; the second UART
  (`uart2` ≈ GPIO4/5 on Pi 5) must be **confirmed on the actual device** before the
  ribbon pinout is frozen. `firmware/led_driver/README.md` also assumes GPIO14/15 for
  its own link — that assumption dies with this board, but the doc needs updating.
- **Pi-side transport.** `PedalTransport` already abstracts native/noop/simulator, so
  a UART transport is a clean addition — but the removed `packages/led_client`
  (`git show 94699e89`) may be worth recovering rather than rewriting.
- **Board outline and mounting.** ~130 × 90 is the working figure; the exact outline
  and standoff pattern should be set against the real bay once the rear-panel harness
  is routed.
