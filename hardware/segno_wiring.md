<!-- cspell:words derating unswitched Reterminate Littelfuse PXCN FHAC -->
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
              +--> BUCK_AUX (20->5 V) --+--> console J3 --> pills + ring
                                       +--> 7.5 A inline fuse --> screen-power J1
                                                                  | switched rail
                                                                  +--> J103/J203 --> screen power
                                                                  +--> J102/J202 --> touch VBUS

   DATA / CONTROL
     console board <---- keyed 2x20 ribbon, ~10 cm ----> Pi 40-pin header
        link  Pico uart0 (GP16/17) <-> Pi uart3 (GPIO8/9), 10 k series each way
        MIDI  DIN IN -> H11L1 (at 3V3) -> Pi uart0 RX (GPIO15)
              Pi uart0 TX (GPIO14) -> 74AHCT125 -> 220R loop -> DIN OUT
        SWD   Pi GPIO24/25 -> the Pico's debug pads (cold flashing)
     console board <-- footswitches x10 | ring board (4-way) | CTRL TRS x2
     Pi --HDMI x2--> 7" + 15.6" screens
     Pi USB2 x2 --> screen J101/J201 --> relays --> J102/J202 --> screen touch
     Pi GPIO17 --> ribbon --> console J25 --> screen J2 (GPIO17 + GND)
     Pi's other 2 USB --> internal leads to the rear USB couplers
                          (the audio interface plugs in there, outside the box)
     power button --J8 -> board -> J9 flying lead--> the Pi 5's own J2 pads
                          (PMIC wake -- no GPIO can wake a Pi 5)

   GND: single common ground -- the scheme, the earth-stud rules and the bench
        audit are Section 6's
```

---

## 2. Power distribution (#754)

**20 V in, 5 V made next to the loads.** Local bucks keep the high-current
5 V wiring short. The current design allowances total **63.04 W** at their
outputs: 25 W for the Pi rail and 38.04 W for AUX. At an illustrative 85–90%
buck efficiency, that needs approximately **70.0–74.2 W**, or **3.50–3.71 A at
20 V**. These efficiencies are planning assumptions, not measurements of the
retained bucks. The 20 V / 5 A / 100 W contract accommodates this model; it
does not establish enclosed thermal capacity or startup response.

The Revision L screen gate driver is assessed at **4.5–5.25 V at J1**;
its negative gate supply preserves enhancement after fuse and harness losses.
Use the existing nominal 5 V buck. This driver corner does not claim that
both screens operate at 4.5 V or that the buck is adjustable. Keep screen
leads short and within the documented wire and connector ratings. The
[gate-drive and startup assessments](kicad/screen_power/README.md#circuit-and-limits)
state the remaining engineering assumptions.

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
  The revised planning load is approximately 3.5–3.7 A at 20 V before startup
  transients; the PD contract ceiling is 5 A. The exact fuse/holder and its
  ambient derating must support that duty. This existing fuse choice has no
  documented part-specific coordination with buck inrush/current limiting;
  do not treat its 5 A marking as an active current limit or guaranteed clearing
  time for a fault on the 5 V side.
- **Two bucks (B0GGHN97TK ×2), split BY RAIL, never paralleled.** Two outputs
  tied together have no current sharing: one hogs the load until it limits,
  then they hunt.
- **Screen branch fuse:** one Littelfuse **028707.5PXCN** in **FHAC0001ZXJ**
  inline holder, immediately after the AUX positive split near the buck.
  Connect its output to screen J1 pin 1; ground goes directly to J1 pin 2.
  Keep the console/ring branch separate. The
  [required harness specification](kicad/screen_power/README.md#required-aux-branch-protection)
  defines the parts, wiring and limits of this supplementary protection.

| Buck | Loads | Design figure |
| --- | --- | --- |
| **BUCK_PI** | Pi 5, its USB devices and NVMe | 5.0 A / 25 W device budget |
| **BUCK_AUX** | Both screens, console, 80 pill LEDs and 40 ring LEDs | 7.608 A / 38.04 W for a full-white ring with normal pill indications and the allowances below |

The selected ring is a **40-pixel strip**, giving 120 LEDs with the ten
8-pixel pills. The updated v3 console/carrier copper supports the ring at
unrestricted RGB white. Its electrical design no longer depends on the ring
firmware's brightness limit. The old v2 console on the current pedal is not
upgraded by changing the new PCB files.

Use 60 mA per RGB-white LED as the conservative planning model from
[Adafruit's power guide](https://learn.adafruit.com/adafruit-neopixel-uberguide/powering-neopixels).
Add 1 mA per pixel as a separate idle allowance. These are design assumptions,
not measurements or a guaranteed rating of a particular LED batch.

The v3 firmware preserved in PR #1082 still uses brightness 128 and the pill
weights `38, 92, 201, 255, 255, 201, 92, 38`. Its normal indications have at most
nine single-channel pills and one amber REC/PLAY pill. With its actual integer
scaling and gamma table, their maximum channel-current estimate is 0.498 A.
This PCB change does not alter those animations or command a full-white mode.

| AUX load allowance | Current |
| --- | ---: |
| Screen board: both main feeds, both touch feeds and its 0.05 A bleeder | 4.250 A |
| 40 ring pixels, all RGB channels at 255 | 2.40 A |
| All ten pills displaying their brightest normal indications | 0.498 A |
| Idle allowance for 120 pixels | 0.120 A |
| Console logic | 0.140 A |
| Additional XIAO ring controller and buffer | 0.200 A |
| **Planning total** | **7.608 A** |

The nominal 10 A buck has approximately 2.39 A headroom against this model.
That is not a guarantee of transient response, capacity at high temperature
or screen current; physical validation remains part of the first assembled build.
The bleeder is included once, inside the 4.25 A screen planning allowance. Relay coils
take their power from Pi USB VBUS, not AUX. The 3 A main and 0.5 A touch branch
ceilings cannot all be used simultaneously: their sum exceeds the shared 4.25 A
planning allowance before the bleeder is counted.

Allowing **all 80 pill LEDs as well as the ring** to display flat unrestricted
white is a different requirement: 7.2 A of LED channels plus the screens and
allowances above totals **11.91 A**. That exceeds the retained 10 A AUX
supply. The ring PCB upgrade does not authorize that simultaneous system load.
Normal pill rendering remains within the modeled budget with a full-white ring.

See the [40-pixel power-path verification](../docs/reviews/ring40-full-white-1072/verification.md)
for conductor widths, connector limits and the source-pinned runtime arithmetic.

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
- The console ring feed is a dedicated **1.7 mm** route to J6, with four
  parallel 0.5 mm drilled power vias. The carrier has a **1.5 mm** direct feed
  from J1 to J2 and three parallel ground vias at the strip wire pad. Console
  input, pill-output and ring-output ground connections have wider thermal spokes.
  Lower-current logic and alternative 24/16-pixel module branches retain their
  existing tracks. The routing/export guards preserve this separation.

The conductor estimates use **IPC-2221, 10 °C rise, 1 oz external copper**,
including a 20% negative width tolerance for the new high-current feeds.
They take no credit for adjacent ground copper as a heat spreader. These
calculations support the design; they are not a measured thermal qualification.

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
  for the existing peripheral budget: the audio interface and rear USB ports
  use Pi USB power. After the screen switch is fitted, each touch cable draws
  only its approximately 34 mA relay-coil load from Pi VBUS; screen touch power
  comes from switched AUX.
- The console board takes 5 V from **BUCK_AUX on J3**, a 2-way **JST VH**
  (~10 A per contact) since #1062; it was a 4-way XH with doubled pins (~6 A). The
  pills' 5 V leaves on **J24**, the JST VH beside it, and their harness is a **5 V
  bus with a tap to each pill**, not a daisy chain through the strips: 4.8 A in
  series through the strip copper would drop enough to shift the far pills'
  colour. Use 18 AWG for the pill bus and **16 AWG for J3's input feed**, with
  SVH-41T-P1.1 contacts for the latter. The selected standard VH connector's
  10 A rating is specified with 16 AWG. The data line and its GND ride the
  same J24 plug (pins 2 and 1). See `kicad/console_board_pcb.py`
  (`_pill_power_bar`, the `PILL_POWER` gate).
- **Screen evidence (owner report, 25 September 2026):** the UPERFECT ran at
  full brightness on a 5 V supply, showing about 1.3–1.4 A and up to 9 W in the
  pattern sweep, with no startup reading above 10 W. APROTII showed about
  0.8 A, up to 4 W at startup and 6 W in the sweep. The current and power fields
  disagree, so they are not a precise simultaneous-current measurement. The
  current fields imply 2.2 A combined; the steady power maxima imply 3.0 A at
  5 V. Using 10 W plus 6 W gives a conservative 3.2 A screen allowance before
  any separately counted touch current. Adding up to 1 A for both touch paths
  and 0.05 A for the bleeder gives a **3.25–4.25 A screen-board planning bracket**,
  or about **6.61–7.61 A AUX** with a full-white ring and normal pills. This does
  not qualify the buck, new-board voltage drop, thermal behavior or inrush.

### Screen power and touch harness

Both main-power leads and both touch leads pass through the screen-power
board. Keep the existing HDMI connections. A direct Pi-to-screen touch cable
or unswitched AUX-to-screen power lead would bypass the cutoff and must not
remain connected in parallel.

| Connection | Pin map and harness |
| --- | --- |
| AUX buck → input fuse → screen J1 | Positive split → 028707.5PXCN in FHAC0001ZXJ near buck → J1 pin 1; ground direct to J1 pin 2. Dedicated short 16 AWG pair with VHR-2N housing and SVH-41T-P1.1 contacts; console/ring stay on their separate branch. |
| Console J25 → screen J2 | Pin 1 GPIO17, pin 2 GND, straight pin-for-pin; one short 22 AWG XH2 lead. |
| Pi USB 2.0 ports → J101/J201 | Two USB-A male-to-XH4 leads: 1 VBUS, 2 D−, 3 D+, 4 GND. Host VBUS feeds each relay coil only. |
| J102 → UPERFECT touch | XH4-to-USB-C male: 1 fused switched VBUS, 2 D−, 3 D+, 4 GND. Preserve the source-role CC resistor in the plug. |
| J202 → APROTII touch | XH4-to-Micro-B male, same four-pin map. |
| J103 → UPERFECT power | Pin 1 fused switched +5 V, pin 2 GND; separate main-power lead retaining the working USB-C screen termination. |
| J203 → APROTII power | Pin 1 fused switched +5 V, pin 2 GND; separate main-power lead retaining the working Micro-B connection. Power pads are an alternative only after verifying their polarity and layout. |

The two main-power leads must each be **no more than 30 cm**, with **20 AWG or
larger copper conductors for both positive and return** and **3 A-rated
terminations**. At the PCB use VHR-2N housings and SVH-41T-P1.1 contacts, which
accept 20–16 AWG; match the specified insulation diameter. Reterminate the
source end of the known-working screen power connection, preserving the
screen-side USB-C/Micro-B plug and any CC/attachment electronics. The exact
existing lead gauge has not been recorded: reuse is conditional on these
requirements, not an assertion that any existing cable meets them. An
unspecified charge-only cable or the selected 28 AWG XH data cable is not a
substitute. [JST VH specifications](https://www.jst-mfg.com/product/pdf/eng/eVH.pdf).

The selected 28 AWG leads are for touch/data only. Both screen ports may join
internally, so the 750 mA touch fuse does not force screen current into the
main lead or limit it actively to 500 mA. Keep the main leads connected and
their ground returns intact. Pi USB ground and GPIO ground are signal
references, not substitutes for the screen power-return pair. The board and
all equipment still share ground; it is not galvanically isolated.

The GPIO owner enables the board before Weston starts and requests off before
normal HDMI shutdown, with a provisional five-second discharge wait. A powered
but halted Pi needs those software hooks; the PCB does not detect missing HDMI.
The owner confirmed both screens go fully dark when power and touch are
removed while HDMI stays attached. Actual GPIO-controlled timing, touch
enumeration and warm operation remain first-assembly checks. See the
[connector and power acceptance matrix](../docs/reviews/screen-power-rev-k-1072/wiring-and-power.md)
and the [board instructions](kicad/screen_power/README.md).

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
between the Pi and console board. Screen power comes from BUCK_AUX through
the dedicated inline fuse to the new board; J25 carries no 5 V. The new board
provides the enable pull-down.

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
- **One 5 V pair supports the 40-pixel strip without a brightness restriction.**
  The design budget is 2.4 A LED channels, 40 mA pixel idle and 200 mA ring
  controller, within the XH connector's 3 A rating with 22 AWG power leads.
  The console now has a dedicated 1.7 mm feed; the carrier's J2 pads have a
  direct 1.5 mm feed and three ground-return vias. This avoids routing strip
  power through the older 0.65 mm module branch. Firmware still chooses its
  display brightness, but that setting is not the hardware's current limit.
- **Only one ring or strip is supported.** Use J2 for the 40-pixel strip, J3
  for one 24-pixel module, or J4 for one 16-pixel module. Do not populate the
  alternatives together or chain an additional ring from DOUT. Extra LEDs
  require a new connector, copper and whole-system power assessment.

---

## 4. Raspberry Pi connections

- **Power** — BUCK_PI into the Pi's USB-C. Not the header, not BUCK_AUX.
- **USB** — the four ports are exactly consumed: 2× screen touch through the
  screen-power board, 2× internal A-to-A leads to the rear-panel couplers.
  No separate hub or HAT is added; the UPERFECT has its own internal USB hub.
  The audio interface
  plugs into a rear coupler from outside the box.
- **Screens** — 2× micro-HDMI out; touch comes back over USB through the
  screen-power board's switched data paths.
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
