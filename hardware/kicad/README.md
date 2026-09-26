# Board generators

<!-- cspell:words XHP SXH -->

SKiDL scripts that emit KiCad netlists. One per board:

| script | board |
|---|---|
| `main_board.py` | standalone pedal — Pro Micro (ATmega32U4) |
| `ring_board.py` | encoder + LED ring + XIAO RP2350, behind the faceplate (4-way link, #987) |
| `console_board.py` | console v3 — Pico 2 on the Pi's GPIO (#747); v3 adds the 4-way ring link (#987) and the CTRL ring sense |

The ring carrier now uses **white solder mask and black silkscreen** for LED
reflections. See [ring order and assembly notes](RING_ASSEMBLY.md) for the
September 24 hole allowances, order settings and USB programming connection.

## Console connection to the screen-power board

**Revision L is the current screen-board design.** It adds a through-hole
negative gate supply to improve MOSFET drive margin, retaining the two-layer
68 × 76 mm outline, direct USB-to-XH leads and existing connector anchors.
The corrected relay contact mapping from Revision J remains. Use only the
archive and checks identified in the
[current three-board audit](../../docs/reviews/pcb-finish-all-three-1072/audit.md).
Revision I is withdrawn; J/K are superseded. No pre-PCB prototype or further
owner measurements are required by this change. The final archives also
include rounded power-bar corners on the console and cleaned, rounded J1
power taps on the white ring carrier, preserving their full-white capacity.

Use **J25**, the two-pin through-hole JST XH connector beside the Pi ribbon
connector. It is already included in the console source, routed PCB and BOM
under #1072. The top-side label reads `SCREEN`; the pin map is documented below.
PD J23, RING J6, screen-control J25 and PI PWR J9 share the same horizontal
connector row. J9 sits immediately beside the Pi ribbon connector; it carries
the floating power-button pair, not a supply rail. PWR BTN J8 remains on the
rear-panel connector row.

| Console J25 | Screen-power J2 | Signal |
| --- | --- | --- |
| Pin 1 | Pin 1 | BCM GPIO17, from Pi ribbon J2 physical pin 11 |
| Pin 2 | Pin 2 | Ground |

The connector is JST **B2B-XH-A(LF)(SN)**, 2.50 mm pitch. Use one short
two-wire 22 AWG cable with an XHP-2 housing and two SXH-001T-P0.6 contacts at
each end. Check numbered pin continuity before connecting it; cable colors
and mirrored views do not establish polarity.

The existing Pi-to-console ribbon remains direct. The dedicated AUX buck
feeds screen-power J1 separately; no screen load passes through console J3
or J25. No extra USB or power connector is needed on the console for this
interface. See the [screen-board wiring](screen_power/README.md) and
[console connector verification](../../docs/reviews/console-screen-connector-1072/verification.md).
The latest [placement verification](../../docs/reviews/console-pi-power-placement-1072/verification.md)
covers the PI PWR move and retained PD alignment. The subsequent
[top-label verification](../../docs/reviews/console-screen-label-1072/verification.md)
covers the `SCREEN` text change and current exports.

The screen planning load is **4.25 A shared**, including both main outputs,
both touch outputs and the 0.05 A bleeder. The old 6 A expansion allowance is
retired. The 3 A main and 500 mA touch lead ceilings are not additive or
simultaneous guarantees. Ring current uses its separate console power path
and does not pass through Q3/Q4. See the
[screen-board assessment](screen_power/README.md#circuit-and-limits).

The ring's J6 connector is JST XH, rated **3 A with 22 AWG wire**. Use 22 AWG
for its +5V and GND leads with SXH-001T-P0.6 contacts. The updated console
feed and carrier J2 strip pads support **40 LEDs at unrestricted full white**:
2.4 A for LED channels, 40 mA idle allowance and 200 mA for the ring controller.
This is a hardware design budget; it does not require a firmware brightness cap.
Use one external strip, or one direct-mount 24/16-LED module. A second ring is
outside this budget. See the [power-path verification](../../docs/reviews/ring40-full-white-1072/verification.md)
and [JST rating](https://www.jst-mfg.com/product/pdf/eng/eXH.pdf).

## Running them

```bash
python3.12 -m venv .venv && ./.venv/bin/pip install -r requirements.txt
cd hardware/kicad && ./.venv/bin/python console_board.py
```

**Run from `hardware/kicad/`.** `generate_netlist()` writes `<script>.net` into the
current working directory, so running from the repo root silently drops the netlist
in the wrong place while reporting success.

The routing pipelines finish unlocked signal bends with `round_routes.py`
after setting trace widths and before refilling copper. It uses KiCad's native
pad and track geometry to preserve connections and clearance. Locked power
routes and the screen's paired USB traces are rounded by their own generators.
Run `test_round_routes.py` with KiCad's Python to exercise the native contact,
keepout, small-radius and repeat-run regression cases without changing a board.

## Two things that will mislead you

**A netlist diff is not a design change.** SKiDL assigns a *random* `SKiDL Tag` to
every `Part` without an explicit `tag=`, and component `tstamps` derive from it. Two
runs of the **same** version on unchanged source differ by ~190 lines — all tags,
timestamps and the tool version string, with **zero** net changes. Pinning skidl does
not fix this. Judge a run by `0 errors found while running ERC` and the `(net ...)`
blocks, not by `git diff`.

**Prefer upstream footprints.** `segno.pretty/` exists for parts KiCad does not ship
(the NeoPixel Ring 24, the EC11 on its ring board, the module mount-pad and wire-pad
helpers). It is not a place to re-draw something that already exists. The Pico 2, for instance, is KiCad's own
`Module:RaspberryPi_Pico_Common_THT` — its description explicitly says it supports
Pico 2, and it is maintained upstream.
