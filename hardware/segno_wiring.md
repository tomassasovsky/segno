# Segno console — system wiring plan

How the console's subsystems connect: the **console board v2** (Pico 2 / RP2350,
`hardware/kicad/console_board.py`, #747), the **ring board** (`segno_pedal_ring`),
the **Raspberry Pi 5**, the two touchscreens, the external audio interface,
power (#754), and the rear panel.

The console is the only product. It stopped sharing a board with the retired
standalone pedal when #747 gave it a board of its own, so the constraint this file
used to open with ("the main board is in production — it is NOT modified") no
longer applies to anything.

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
     console board <-- footswitches x10 | ring board (4-way) | CTRL TRS x2
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
- **Is the contract really 20 V / 5 A?** The chip is I2C-readable: its RDO
  (`0x91`–`0x94`) carries the current the source actually granted and a
  capability mismatch bit that is set when that was less than the PDO asked for;
  `0x21` holds the negotiated voltage. A 65 W brick grants 20 V / 3.25 A with
  mismatch set: everything boots and the console browns out only when 26
  WS2812s go white under two lit screens. Console board **v3** has a 3-way
  JST-XH for it, **J23 `PD`** (GND, SDA, SCL on the Pico's GP0/GP1, I2C0),
  under the module's left end next to `5V IN`. Three wires on purpose: the
  breakout's VDD comes off VBUS on its own board and its I2C pull-ups go to
  that; the console's 3V3 is downstream of the contract being measured, so it
  must not feed the trigger. ~250 mm unshielded past two bucks: 100 kHz,
  twisted with the ground wire. On a v2 board the same read works from J22's
  GP20/GP21 (I2C0) unless those pads carry the CTRL ring wires. Firmware
  reads it and reports it up the pedal link; **not implemented yet**.
- **Fuse:** 5×20 **T5A slow-blow** in the 20 V feed, ahead of both bucks.
  Worst-case draw is ~3 A at 20 V, the PD contract ceiling is 5 A, and buck
  inrush wants the slow curve.
- **Two bucks (B0GGHN97TK ×2), split BY RAIL, never paralleled.** Two outputs
  tied together have no current sharing: one hogs the load until it limits,
  then they hunt.

| buck | loads | design figure |
|---|---|---|
| **BUCK_PI** | Pi 5 (via its USB-C) + its USB devices + NVMe | 5.0 A / 25 W (worst case) |
| **BUCK_AUX** | 7" + 16" screens + console board (J3) + all 94 WS2812 | 6.3 A / 31 W (**normal**, not worst case — see the state table) |

BUCK_PI's worst case is capped by device limits, not estimated: the Pi's own 5 A
budget. BUCK_AUX's figure is the screens' ratings plus the LEDs **as they are
actually driven** — see below, because the naive all-white number for 94 WS2812
is misleading in both directions.

**The LED load is dominated by COLOUR and the pill gradient, not by the count
(#930).** The pills went from 6 single LEDs to ten 7-LED segments of 144/m (7, not
8, for a centre pixel: #1062), and the ring is a Ring **24**, so BUCK_AUX carries
**94 WS2812**. The naive "94 × 60 mA" reading of that is 5.6 A and it is wrong for
two reasons: 60 mA is
all three channels at full (an indicator is normally ONE channel, ~20 mA), and
a pill is never all-on — it is rendered **centre-bright, dimming to both ends**,
which sums to ~62% of all-at-full. The vendor's own figure agrees: 0.1 W per LED
per colour at 5 V is exactly 20 mA.

| state | LED | BUCK_AUX | of 10 A |
|---|---|---|---|
| all off (controller quiescent only) | 0.09 A | 5.23 A | 52% |
| **normal — pills one colour + gradient, ring half** | **1.11 A** | **6.25 A** | **62%** |
| pills amber (2 ch) + gradient, ring one colour | 2.22 A | 7.36 A | 74% |
| pills white + gradient, ring full white | 4.04 A | 9.18 A | 92% |
| everything full white, no gradient | 5.64 A | 10.78 A | **108%** |

Normal operation is **1.11 A of LED**, and **the rail does not need a brightness
cap** — the gradient is inherent to how a pill is drawn, not a limiter bolted on.
Two things to keep in view: **white is the expensive colour**, and pills-white
*and* ring-white together reach 92% with little margin — so if a white lamp test or a
white "clipping" state is ever added, it is that combination, not the LED count,
that needs the thought.

**The board path is sized for the last row now (#1062).** It was the binding
limit: the LEDs reached BUCK_AUX through J3 (two JST-XH contacts, ~6 A) and the
console board's 0.6 mm +5 V track (1.65 A per IPC-2221), both sized when the chain
was 26 WS2812, so anything above ~1.6 A of LED was past the track — including row 3,
an ordinary state. v3 fixes it with topology rather than width:

- **J3** is a JST VH (~10 A per contact), carrying the whole 5.64 A.
- **J24**, a 3-way JST VH stacked under J3 at the board's left edge, is the pills'
  one connector: pin 1 GND, pin 2 data, pin 3 +5 V. J3's +5 V pad and J24's face
  each other across a bar poured on both copper layers, so the pills' 4.2 A never
  reaches a routed track. The data line crosses the board to it from the buffer,
  ~87 mm. J7 is gone.
- What the tracks carry is the ring (1.44 A at full white, through J6) and the
  logic: ~1.6 A. That is 3% inside 0.6 mm, so the +5 V rail is no longer left at
  the routed width — `widen_power.py` grows it to 0.70 mm (1.85 A, 15%) between
  the session import and the pour, on both boards. The ring board's own
  `+5V_LED` goes 0.55 → 0.65 mm the same way.

**One standard: IPC-2221, 10 °C rise, 1 oz external.** This page and
`console_board_pcb.py` used to quote IPC-2152 (~2 A for 0.6 mm) while
`route_ring_board.sh` quoted IPC-2221 (1.65 A for the same copper), and the two
boards reported different margins for the same rail as a result. 2152 is newer,
measurement-based and more generous, and it would credit the ground pour either
side as a heat spreader. None of the numbers here take that credit.

The rail becomes the limit instead: the last row is 108% of BUCK_AUX, and even
row 4 leaves 8%. Those percentages use the screens' **rated** maxima, so measure
the real draw on the bench before deciding whether full white needs a firmware
current limiter or a separate LED buck.

**And the whole table is a model of software that does not exist.** The gradient
duty (62%) and "one channel per indicator" are how a pill is *intended* to be
drawn; there is no console pixel renderer yet (`firmware/led_driver/` is the
standalone RP2040 driver, sized 24 ring + 8 indicators, with a fixed
`setBrightness(120)` ≈ 47%). So the numbers below are a design target for that
renderer to hit, not a measurement — and the 2 A track is the number it has to
hit them against. And the 5.14 A non-LED baseline is **rated maxima** for two
screens and the board, not measured; real draw is likely well under half, so the
true headroom is larger than this table admits. Measure it on the bench before
trusting either direction.

- **The Pi is fed through its USB-C, not the header.** Ribbon pins 2/4 are
  deliberately not connected (`PI_POWER` gate): tying them would put BUCK_PI in
  hard parallel with the Pi's PMIC rail and land the WS2812 load on the Pi's
  5 V pin.
- A plain 5 V feed is not a PD source, so the Pi caps its downstream USB at
  600 mA unless **`usb_max_current_enable=1`** is set in `config.txt`. Required
  here: the touch panels and the audio interface hang off that budget.
- The console board takes 5 V from **BUCK_AUX on J3**, a 2-way **JST VH**
  (~10 A per contact) since #1062; it was a 4-way XH with doubled pins (~6 A). The
  pills' 5 V leaves on **J24**, the JST VH beside it, and their harness is a **5 V
  bus with a tap to each pill**, not a daisy chain through the strips: 4.2 A in
  series through the strip copper would drop enough to shift the far pills'
  colour. Use 18 AWG for the bus and J3's feed. The data line and its GND ride the
  same J24 plug (pins 2 and 1). See `kicad/console_board_pcb.py`
  (`_pill_power_bar`, the `PILL_POWER` gate).
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
1k8/3k3 divider and the AHCT gate on this path were the retired 5 V board's needs
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

### Console board ↔ ring board: the 4-way (#987)

The ring board carries its own **XIAO RP2350**, which owns the encoder and
generates the WS2812 timing 20 mm from the LEDs. What used to be eight
conductors across ~600 mm of box is now four.

**On console board v3 the cable is a plain 1:1 4-way, JST-XH at both ends:**

| ring J1 | console v3 J6 | console v2 J6 | conductor |
|---|---|---|---|
| 1 | 1 | 1 | +5V |
| 2 | 2 | 3 | GND |
| 3 | 3 | 6 | LINK_TO_RING — GP13 drives, the XIAO listens |
| 4 | 4 | 7 | LINK_TO_CONSOLE — the XIAO drives, GP14 listens |

**On a v2 console the cable is asymmetric and that was the whole hazard:** the
fabbed 8-way J6 stays, and the ring's 4-way lands on four of its eight positions
(the v2 column). Crimp *that* one 1:1 by position and pin 2 of the ring end lands
on J6 pin 2, which is +5V: the LED rail straight onto a link line. v3 removes the
hazard by construction; `RING_CONTRACT` asserts the map is the identity there.

The link is **full duplex** (owner call). One wire would have carried the traffic
— 115200 is ~11.5 kB/s against a 72-byte pixel frame and a few bytes per detent —
but a single wire forces a master-polled, collision-avoiding protocol on the
firmware, and the second conductor buys that away for one crimp. It cost nothing
in copper: J6 pin 7 was already wired to GP14 with its 10 k pull-up, doing
nothing. Neither pin is on a free hardware UART (GP13 is UART0 RX, but UART0 is
the Pi link on GP16/17, and GP14 is on neither), so the console end is a PIO
UART — of which the RP2350 has plenty spare.

The table above is *not* the source of truth — `RING_PINMAP` in
`console_board.py` is, and `RING_CONTRACT` checks it against `ring_board.net` on
every run.

Notes that are load-bearing:

- **GND is the middle pin** so the pulsed amp-scale LED return does not run
  beside the one signal in the cable.
- **The link pull-ups are on the console board** (J6 pin 6/7's 10 k to *its* 3V3).
  The ring board deliberately fits none — a second pull-up on the other board's
  rail is the split-rail fault `RING_LEVELS` exists to catch, and `LINK_BARE` in
  `ring_board.py` rejects it from the other side.
- **On v2, J6 pins 2, 4, 5 and 8 stay fitted and carry nothing.** Pin 5 could
  never have carried the link anyway: it is the AHCT125's gate-B output with /OE
  tied low, so it is only ever driven by the console. On v3 the ring-data path
  (GP12, gate B, R1, R15) is gone and GP12/GP15 went to the expansion header.
- **One 5 V pair, not two, and it is sized for full white rather than for a cap.**
  24 LEDs at 60 mA is 1.44 A: 48% of an XH contact's ~3 A, and 21% inside the
  ring board's `+5V_LED` at 0.65 mm. This used to justify the single pair with
  "the firmware's brightness cap" and set a bench trigger at ~0.7 A. The cap does
  not exist — the ring link is unwritten on both ends — and R5 on the ring board
  is fitted precisely because the ring can latch full white with nothing driving
  it, on power-up, in the bootloader, during a reflash or after a crash. So full
  white is the state the copper is sized for and the trigger is gone.
- **A second ring chained off `RING_DOUT` is a connector change, not a wider
  track.** 2.88 A is past one XH contact at any width; J1 and J6 would go JST VH,
  the way J3/J24 did on the console.

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
| power button (`POWER`) | momentary, **unlit** → J8, through the board to J9 → the Pi 5's own J2 solder pads. Two wires, and neither end has a polarity: J8 and J9 are wired pin to pin as a floating pair that never touches the board's ground (#1062), so the lead works on the Pi's pads either way round. No 5 V run to the rear panel. The machine has no power indicator — the screens are the indicator |
| fuse (`FUSE`) | 5×20 screw-cap holder — value and placement are §2's (T5A slow-blow, in the 20 V feed) |
| MIDI DIN-5 ×2 (`MIDI_IN`/`MIDI_OUT`) | IN is opto-isolated **on the board** — the socket alone is not enough. IN's pin 2 stays unbonded (that isolation is the point) |
| Neutrik NJ6FD-V ×2 (`CTRL_1`/`CTRL_2`) | 6-pole switching 1/4" jack, rear-mounted through a Ø12 hole with its snap cap (needs the 1.5 mm panel). Vertical PCB pins, no lugs. On v2 connect T / R / S and leave TN / RN / SN open. An expression pedal OR footswitch on the same jack, auto-detected (tip → ADC with pull-up, ring → 3V3 through 1 k). A two-switch pedal on one TRS plug (BOSS FS-6 A&B) puts its B switch on the ring, which firmware ≥ 1.1 reads on GP20/GP21: a trace through 4.7 kΩ on board v3 (R19/R20); on v2 one wire from each jack's ring pin (J20/J21 pin 2) to J22's GP20/GP21 pads. Without either, use the pedal's separate A and B mono jacks, one per CTRL. **v3 jacks are Neutrik NJ6FD-V** (switched): a fourth lead, the tip-normal contact, tells the board whether anything is plugged in (J20/J21 pin 4 → GP19/GP22), so an empty jack never reads as a pedal at full toe |
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
