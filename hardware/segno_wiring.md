# Segno console — system wiring plan

How the console's subsystems connect: the **console board v2** (Pico 2 / RP2350,
`hardware/kicad/console_board.py`, #747), the **ring board** (`segno_pedal_ring`),
the **Raspberry Pi 5**, the two touchscreens, the external audio interface,
power (#754), and the rear panel.

The **standalone pedal** is the other product and keeps the V1 Pro Micro board
(`segno_pedal_main`) with its own wiring plan (`segno_pedal_pcb_design.md`).
Nothing in this file applies to it: the console stopped sharing that board when
#747 gave it a board of its own, and the constraint this file used to open with
("the main board is in production — it is NOT modified") is satisfied the easy
way now — the console does not use that board at all.

---

## 1. Block diagram

```
   POWER (#754)
     USB-C PD inlet -- rear panel, D punch, QIANRENON coupler (all 24 ways wired)
              |   STUSB4500 trigger: ONE 20 V / 5 A contract
              |   fuse, T5A slow-blow, in series with the 20 V feed
              +--> BUCK_PI  (20->5 V) --> Pi 5 via its USB-C  --> Pi USB + NVMe
              +--> BUCK_AUX (20->5 V) --> 7" + 16" screens | board J3 | WS2812

   DATA / CONTROL
     console board <---- keyed 2x20 ribbon, ~10 cm ----> Pi 40-pin header
        link  Pico uart0 (GP16/17) <-> Pi uart3 (GPIO8/9), 10 k series each way
        MIDI  DIN IN -> H11L1 (at 3V3) -> Pi uart0 RX (GPIO15)
              Pi uart0 TX (GPIO14) -> 74AHCT125 -> 220R loop -> DIN OUT
        SWD   Pi GPIO24/25 -> the Pico's debug pads (cold flashing)
     console board <-- footswitches x10 | ring board (3-way) | CTRL TRS x2
     Pi --HDMI x2--> 7" + 16" screens ;  screen touch --USB--> Pi (2 of 4 ports)
     Pi's other 2 USB --> internal leads to the rear USB couplers
                          (the audio interface plugs in there, outside the box)
     power button --J8 -> board -> J9 flying lead--> the Pi 5's own J2 pads
                          (PMIC wake -- no GPIO can wake a Pi 5)

   GND: single common ground -- the scheme, the earth-stud rules and the bench
        audit are Section 6's
```

---

## 2. Power distribution (#754)

**20 V in, 5 V made next to the loads.** 5 V at the inlet was tried and dropped:
the usable window is **5.0–5.25 V** (the Pi 5 browns out under ~4.8 V and it and
both screens cap at 5.25 V, so trimming low eats brown-out margin and trimming
high eats the ceiling), and at the console's ~12 A even a heavy 1.5 m lead drops
~0.3 V — *load-dependently*, so no single supply trim holds both idle and
full-tilt inside that 250 mV band without remote sense. At 20 V the same 59 W is
under 3 A, the lead drop is regulated away by the bucks, and the tight 5 V
tolerance only has to survive ~100 mm of internal wiring.

- **Inlet:** panel-mount USB-C coupler on a D punch (QIANRENON B0CQ4VD2N2,
  100 W, 10 Gbps). The 10 Gbps matters only because it means **all 24 ways are
  wired**, so CC reaches the trigger and PD can negotiate — a charge-only
  coupler drops CC and nothing powers up.
- **Trigger:** SparkFun STUSB4500 board, programmed to request **20 V / 5 A**.
  Its shipped default asks 20 V at only 1.0 A, which contracts 20 W — set the
  PDO before first power-up.
- **Fuse:** 5×20 **T5A slow-blow** in the 20 V feed, ahead of both bucks.
  Worst-case draw is ~3 A at 20 V, the PD contract ceiling is 5 A, and buck
  inrush wants the slow curve.
- **Two bucks (B0GGHN97TK ×2), split BY RAIL, never paralleled.** Two outputs
  tied together have no current sharing: one hogs the load until it limits,
  then they hunt.

| buck | loads | worst case |
|---|---|---|
| **BUCK_PI** | Pi 5 (via its USB-C) + its USB devices + NVMe | 5.0 A / 25 W |
| **BUCK_AUX** | 7" + 16" screens + console board (J3) + all 26 WS2812 | 6.7 A / 34 W |

The worst case is capped by device limits, not estimated: the Pi's own 5 A
budget, the screens' ratings, 26 WS2812 at 60 mA all-white.

- **The Pi is fed through its USB-C, not the header.** Ribbon pins 2/4 are
  deliberately not connected (`PI_POWER` gate): tying them would put BUCK_PI in
  hard parallel with the Pi's PMIC rail and land the WS2812 load on the Pi's
  5 V pin.
- A plain 5 V feed is not a PD source, so the Pi caps its downstream USB at
  600 mA unless **`usb_max_current_enable=1`** is set in `config.txt`. Required
  here: the touch panels and the audio interface hang off that budget.
- The console board takes 5 V from **BUCK_AUX on J3** — four ways as two
  parallel pairs, because JST-XH is ~3 A per contact and the LED chain alone
  nears that.
- **Unverified until a build (carried from #754):** the UPERFECT 15.6" is a
  USB-C portable monitor, and many of those expect PD and run dim — or refuse
  to light — on a plain non-PD 5 V feed. BUCK_AUX is exactly that. Verify the
  panel at full brightness on bench 5 V **before** committing the harness; the
  fallback is a dedicated PD trigger for the screen off the 20 V rail.

---

## 3. The console board's two internal data cables

### Console board ↔ Pi: the ribbon

One **keyed 2×20 IDC ribbon, ~10 cm** — both boards sit under the 16" screen
and the Pi is ~30 mm from the board (`board_mounts()` in `segno_enclosure.py`).
J2 is rotated so both connectors' pin-1 ends face the front: pin 1 meets pin 1
with no fold in the cable. 16 of the 40 ways carry something;
`console_board.py`'s `PI_HDR` is the authority:

| Pi pins | signal |
|---|---|
| 1, 17 | 3V3 — the board's 3V3 rail (opto + pull-up bias, ~15 mA) |
| 6, 9, 14, 20, 25, 30, 34, 39 | GND |
| 8 / 10 | uart0 TX / RX = MIDI OUT / MIDI IN (GPIO14/15) |
| 21 / 24 | uart3 RX / TX = pedal link (GPIO9/8, `dtoverlay=uart3-pi5`), **10 k series** |
| 18 / 22 | GPIO24/25 = SWD to the Pico's debug pads (flashing only) |
| 2, 4 | 5 V — deliberately **not connected** (`PI_POWER`) |

The link needs **no level shifting**: RP2350 and Pi are both 3.3 V. The old
1k8/3k3 divider and the AHCT gate on this path were the 5 V Pro Micro's needs
and died with it. The series 10 k in each link line is not level shifting — it
bounds the cross-domain current when one side is powered and the other is not
(rationale and arithmetic: R17/R18 in `console_board.py`).

The **74AHCT125** remains for MIDI OUT's current loop and the indicator chain.
Its third gate still drives the ring-data pin (J6 pin 5) and that pin now goes
nowhere: since #987 the ring board generates its own WS2812 timing behind a XIAO
RP2350, so the level shifting for the ring moved onto **that** board. Gate B, R15
and J6 pin 5 stay fitted because the console board exists in copper and its
netlist has to keep matching it. **MIDI IN's H11L1 runs at 3.3 V** and
feeds the Pi directly — no shifter. GPIO4 (pin 7) is left alone: the GeeekPi
N07 NVMe board under the Pi claims it (`PI_RESERVED`).

### Console board ↔ ring board: the 3-way (#987)

The ring board carries its own **XIAO RP2350**, which owns the encoder and
generates the WS2812 timing 20 mm from the LEDs. What used to be eight
conductors across ~600 mm of box is now three.

**The cable is asymmetric and that is the whole hazard.** An 8-way JST-XH
housing at the console (J6, unchanged copper) and a **3-way at the ring board**
(J1), populated on three of J6's eight positions:

| ring J1 | console J6 | conductor |
|---|---|---|
| 1 | 1 | +5V |
| 2 | 3 | GND |
| 3 | 6 | RING_LINK — half-duplex UART to GP13, 115200 |

Crimp it 1:1 by position and pin 2 of the ring end lands on J6 pin 2, which is
+5V: that is the LED rail straight onto a link line. The map above is *not* the
source of truth — `RING_PINMAP` in `console_board.py` is, and `RING_CONTRACT`
checks it against `ring_board.net` on every run.

Notes that are load-bearing:

- **GND is the middle pin** so the pulsed amp-scale LED return does not run
  beside the one signal in the cable.
- **The link's pull-up is on the console board** (J6 pin 6's 10 k to *its* 3V3).
  The ring board deliberately fits none — a second pull-up on the other board's
  rail is the split-rail fault `RING_LEVELS` exists to catch, and `LINK_BARE` in
  `ring_board.py` rejects it from the other side.
- **J6 pins 2, 4, 5, 7 and 8 stay fitted and carry nothing.** Pin 5 could never
  have carried the link anyway: it is the AHCT125's gate-B output with /OE tied
  low, so it is only ever driven by the console.
- One 5 V pair, not two: 24 LEDs at the firmware's brightness cap sit well under
  the 1.44 A all-white figure the doubled pair was sized for. If a bench
  measurement of the *capped* worst case exceeds ~0.7 A, add the second pair
  (J6 pins 2/4 are still there).

---

## 4. Raspberry Pi connections

- **Power** — BUCK_PI into the Pi's USB-C. Not the header, not BUCK_AUX.
- **USB** — the four ports are exactly consumed: 2× screen touch, 2× internal
  A-to-A leads to the rear-panel couplers. No hub, no hat. The audio interface
  plugs into a rear coupler from outside the box.
- **Screens** — 2× micro-HDMI out; touch comes back over USB.
- **Storage** — NVMe on the N07 board under the Pi (PCIe — no GPIO use beyond
  the GPIO4 claim noted above).
- **Position** — under the 16" screen (#743, #753). Its own ports face inward
  and are serviceable only with the case open, by intent; everything the build
  needs comes back out through the rear stations.

---

## 5. Rear panel mapping

Nine stations plus the earth stud, on one centreline. The list is generated:
the enclosure writes `rear_io_stations.json` and the board's `REAR_IO_COVER`
gate checks its connector set against it, so this table is commentary, not a
source of truth.

| station | wiring note |
|---|---|
| USB-C PD inlet (`PD_IN`) | D punch; coupler → STUSB4500 → fuse → both bucks. Never touches the console board |
| power button (`POWER`) | momentary, **unlit** → J8, through the board to J9 → the Pi 5's own J2 solder pads. Two wires; no 5 V run to the rear panel. The machine has no power indicator — the screens are the indicator |
| fuse (`FUSE`) | 5×20 screw-cap holder — value and placement are §2's (T5A slow-blow, in the 20 V feed) |
| MIDI DIN-5 ×2 (`MIDI_IN`/`MIDI_OUT`) | IN is opto-isolated **on the board** — the socket alone is not enough. IN's pin 2 stays unbonded (that isolation is the point) |
| TRS 6.35 D-series ×2 (`CTRL_1`/`CTRL_2`) | expression pedal OR footswitch on the same jack, auto-detected (tip → ADC with pull-up, ring → 3V3 through 1 k) |
| USB 3.0 coupler ×2 (`USB3_1`/`USB3_2`) | internal A-to-A leads to two Pi ports |
| M6 earth stud | between the cluster and the vent block; rules in the grounding doc |

---

## 6. Grounding & ventilation

Single common ground; DIN **IN** opto-isolated; exactly **one** hard chassis
bond, at the board's H1. The full scheme — what goes on the earth stud, what
deliberately does not, and the bench audit to run before trusting any of it —
lives in `docs/design/console-grounding-and-bonding.md` (#751). Vents: intake
in the bottom plate, exhaust in the rear wall; air crosses the boards and the
Pi's active cooler.
