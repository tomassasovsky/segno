# Segno console — system wiring plan

How the console's subsystems connect: the **console board v3** (Pico 2 / RP2350,
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
- **PD contract status:** console v3 J23 `PD` carries GND, SDA and SCL to
  Pico GP0/GP1 at 100 kHz. The trigger supplies its own I2C pull-ups; do not
  connect console 3V3 to it. Firmware reads attachment, policy status and RDO
  (`0x91`–`0x94`) without changing PDOs or NVM, and reports current and capability
  mismatch through the pedal link. ST's published map reserves `0x21`, so it
  is not used as a negotiated-voltage register. Voltage stays explicitly
  unknown: verify 20 V with a meter/PD analyzer before claiming 100 W readiness.
  Twist the approximately 250 mm I2C run with ground past the bucks.
- **Fuse:** 5×20 **T5A slow-blow** in the 20 V feed, ahead of both bucks.
  Worst-case draw is ~3 A at 20 V, the PD contract ceiling is 5 A, and buck
  inrush wants the slow curve.
- **Two bucks (B0GGHN97TK ×2), split BY RAIL, never paralleled.** Two outputs
  tied together have no current sharing: one hogs the load until it limits,
  then they hunt.

| buck | loads | design figure |
|---|---|---|
| **BUCK_PI** | Pi 5 (via its USB-C) + its USB devices + NVMe | 5.0 A / 25 W (worst case) |
| **BUCK_AUX** | 7" + 16" screens + console board (J3) + all 104 WS2812 | 5.83 A / 29 W for the single-colour example below; 8.38 A / 42 W for capped full white |

BUCK_PI's worst case is capped by device limits, not estimated: the Pi's own 5 A
budget. BUCK_AUX's figures combine a **5.14 A rated non-LED baseline** (screens
and console logic) with an LED current estimate. They are not measurements of
the assembled device or guarantees of the buck's sustained output.

**There are ten eight-pixel pills and a 24-pixel ring: 104 LEDs.** The owner
confirmed eight pixels per pill; the earlier seven-pixel assumption was wrong.
The pill gradient is `38, 92, 201, 255, 255, 201, 92, 38`, giving two central
peaks and a mean of `1172 / (8 × 255) = 57.45%`. Console v3 and ring firmware
both use `LED_BRIGHTNESS = 128`, so the channel values are also scaled by
approximately `128/255`. They start dark until valid app state arrives. See
`firmware/console_board/README.md` for the chain order and pixel directions.

The planning model uses 20 mA per fully driven colour channel, derived from
the conventional 60 mA RGB-white budget in
[Adafruit's NeoPixel power guide](https://learn.adafruit.com/adafruit-neopixel-uberguide/powering-neopixels).
It adds a separate **1 mA per pixel idle allowance** (104 mA total), including
when the LEDs are dark. This is a conservative budgeting assumption, not an
identified LED variant's measured or guaranteed current. Brightness scaling
reduces the colour-channel term, not that idle allowance; gamma correction,
integer rounding and actual LED variants further affect the real draw.

**Example patterns at the current 128/255 cap:**

| state | LED estimate | BUCK_AUX estimate | of 10 A |
|---|---|---|---|
| all off (idle allowance only) | 0.10 A | 5.24 A | 52% |
| pills one colour + gradient, ring half a single-colour load | 0.69 A | 5.83 A | 58% |
| pills two full channels + gradient, ring one colour | 1.27 A | 6.41 A | 64% |
| pills white + gradient, ring white | 2.21 A | 7.35 A | 74% |
| all LEDs white, no gradient (hypothetical stress pattern) | 3.24 A | 8.38 A | 84% |

For example, the single-colour row is
`0.104 + (80 × 0.020 × 0.5745 + 24 × 0.020 × 0.5) × 128/255` amps of LEDs.
These patterns illustrate the budget; they do not assert that every pill is
normally lit or that the ring always occupies half its available pixels.
With the cap removed, white pills with the gradient and a white ring would be
approximately **9.44 A AUX**. Uncapped white without the gradient would be
approximately **11.48 A AUX**, above the buck's 10 A rating. Keep the current
brightness cap; a future brighter mode must be budgeted separately.

**The old v2 board and new v3 board have different power paths (#1062).** On
v2, the LEDs share the console's 0.6 mm +5 V track, estimated at 1.65 A by the
project's IPC-2221 calculation. That approximately 1.6 A path limit remains
relevant even with a 10 A buck. It is not a measured cutoff or a fuse rating.
V3 sends pill power through a copper bar instead:

- **J3** is a JST VH (~10 A per contact), carrying the LEDs and console logic.
- **J24**, a 3-way JST VH stacked under J3 at the board's left edge, is the pills'
  one connector: pin 1 GND, pin 2 data, pin 3 +5 V. J3's +5 V pad and J24's face
  each other across a bar poured on both copper layers, bypassing the narrow
  routed track. The 80 pill LEDs have a 4.8 A uncapped RGB-white channel
  budget (about 4.88 A including the idle allowance). The data line crosses
  the board to J24 from the buffer, ~87 mm. J7 is gone.
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

**Testing the existing ten-pill chain on v2:** use a temporary diagnostic that
keeps the ring dark and lights only one eight-pixel pill at a time, with one
colour channel capped at 32/255. Its channel-current estimate is
`8 × 20 mA × 32/255 = 20.1 mA`, plus the already connected pixels' idle draw.
This checks addressing, colours and pixel direction at low current. It does
not qualify maximum brightness or the new v3 board. The diagnostic starts and
finishes dark, then the installed v2 firmware is restored; normal v3 firmware
must not be flashed onto the old board.

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
  bus with a tap to each pill**, not a daisy chain through the strips: 4.8 A in
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
with no fold in the cable. 17 of the 40 ways carry something;
`console_board.py`'s `PI_HDR` is the authority:

| Pi pins | signal |
|---|---|
| 1, 17 | 3V3 — the board's 3V3 rail (opto + pull-up bias, ~15 mA) |
| 6, 9, 14, 20, 25, 30, 34, 39 | GND |
| 8 / 10 | uart0 TX / RX = MIDI OUT / MIDI IN (GPIO14/15) |
| 11 | GPIO17 = screen-power enable, through J25 pin 1 |
| 21 / 24 | uart3 RX / TX = pedal link (GPIO9/8, `dtoverlay=uart3-pi5`), **10 k series** |
| 18 / 22 | GPIO24/25 = SWD to the Pico's debug pads (flashing only) |
| 2, 4 | 5 V — deliberately **not connected** (`PI_POWER`) |

**J25 is the two-wire screen-power control connector:** pin 1 is GPIO17
(physical pin 11 on J2), and pin 2 is GND. Connect it pin-for-pin to J2 on the
[screen-power board](kicad/screen_power/README.md). The existing Pi ribbon stays
between the Pi and console board. Screen power comes directly from BUCK_AUX to
the new board; J25 carries no 5 V. The new board provides the enable pull-down.

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
- **One 5 V pair, not two, and it is sized for 1.44 A rather than for the cap.**
  24 LEDs at 60 mA is 1.44 A: 48% of an XH contact's ~3 A, and 21% inside the
  ring board's `+5V_LED` at 0.65 mm. The cap is real — `LED_BRIGHTNESS = 128`
  (#1064) puts all-white at 0.72 A and the comet at ~0.2 A — and the current v3
  XIAO firmware applies the same cap with PIO/DMA output. Two states are outside any
  cap in either generation: the window before firmware runs, which is why R5 sits
  on `RING_DATA_3V3` at all (power-up, the bootloader, a reflash, a crash), and a
  console flashed with a higher `LED_BRIGHTNESS`. Neither is exotic, both land on
  1.44 A, and the copper now carries it, so the old bench trigger at ~0.7 A of the
  capped case is gone: nothing the capped case can do makes one pair insufficient
  when the uncapped case already fits.
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
