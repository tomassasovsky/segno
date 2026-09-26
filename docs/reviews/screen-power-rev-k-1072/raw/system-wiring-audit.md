<!-- cspell:words misconnection unswitched derating Reterminate milliohm Littelfuse Mbps kilohm -->
# Screen power: system wiring and operating-budget audit

Reviewed 25 September 2026 against `9a5798be6c4ea9b0aae2a88fe7168b6751cab441`
(Revision J), while Revision K routing was being prepared. This is an independent
review of the circuit interfaces, wiring instructions and appliance lifecycle;
it does not approve an as-yet-unfinished Revision K copper export. Only this
report was edited by the reviewer. No device was flashed or manufacturing order
placed.

## Result

The intended topology makes sense: one switched AUX supply feeds both main
screen inputs and both touch-power inputs; USB data opens independently for each
host port; Pi USB power supplies only the corresponding relay coil. Native-board
pad assignments match that topology. I found no additional circuit
misconnection in the inspected board.

The authoritative system wiring instructions still contain important stale
information and the main-power harness specification is incomplete. Correct
those before calling the complete design finished. The findings below are
documentation/assembly defects, not a demand for another round of owner
measurements before ordering bare boards.

## Practical connection map

All pin numbers below refer to numbered PCB pads, never wire colour or a
mirrored view of a loose housing. The Pi, both bucks, console, screen board,
screens and HDMI connections share ground. The two buck positive outputs must
remain separate.

| From | Through | To | Wiring contract |
| --- | --- | --- | --- |
| AUX buck +5 V / GND | Dedicated branch | Screen J1 pin 1 / pin 2 | Short 16 AWG pair; VH VHR-2N with SVH-41T-P1.1 contacts; branch protection belongs upstream of this board. |
| AUX buck +5 V / GND | Separate branch | Console J3 +5 V / GND | 16 AWG feed for the documented 10 A VH rating. Screen current must not pass through the console PCB. |
| Pi 40-pin header | Existing keyed ribbon | Console J2 | Physical pin 11 carries BCM GPIO17; no additional ribbon and no screen load on GPIO. Ribbon 5 V pins 2/4 remain unconnected in the console design. |
| Console J25 pins 1/2 | Two-wire XH lead | Screen J2 pins 1/2 | 1 = GPIO17, 2 = GND; straight pin-for-pin; 22 AWG as already specified. |
| First Pi USB 2.0 port | USB-A male to XH4 | J101 | 1 = Pi VBUS, 2 = D−, 3 = D+, 4 = GND. VBUS ends at K101 coil/C101; it does not feed the display. |
| J102 | XH4 to USB-C male | UPERFECT touch/data port | 1 = switched fused VBUS, 2 = D−, 3 = D+, 4 = GND. Preserve source-role CC configuration in the USB-C plug. |
| J103 pins 1/2 | Separate main-power lead | UPERFECT power port | 1 = switched fused +5 V, 2 = GND. Retain the proven 5 V screen termination and its attachment electronics. |
| Second Pi USB 2.0 port | USB-A male to XH4 | J201 | Same four-pin map as J101; VBUS feeds K201 coil/C201 only. |
| J202 | XH4 to Micro-B male | APROTII touch/data port | Same four-pin map as J102. Micro-B ID is not one of these four signals. |
| J203 pins 1/2 | Separate main-power lead | APROTII power Micro-B port or verified power pads | 1 = switched fused +5 V, 2 = GND; retain the known working power connection. |
| Pi HDMI outputs | Existing HDMI cables | Both screens | Retain video wiring; do not route HDMI through the switch board. |
| Console J6 pins 1–4 | 1:1 XH4 link | Ring J1 pins 1–4 | 1 = +5 V, 2 = GND, 3 = console-to-ring, 4 = ring-to-console; use 22 AWG power/ground and the specified contacts. |
| Ring carrier J2 | Short 22 AWG power/ground and data lead | One 40-pixel strip | Only one LED option is populated; alternatives J3/J4 are not additional loads. |

There are four selected touch/data cables total: two USB-A-to-XH, one
USB-C-to-XH, and one Micro-B-to-XH. The two separate main-power leads are
additional. No direct Pi-to-screen touch cable or unswitched buck-to-screen
lead may remain in parallel: either would defeat the cutoff concept.

Native KiCad inspection confirmed J101/J201 D− reaches relay common 3 and D+
reaches common 6; normally open 4/5 reaches output D−/D+ respectively; normally
closed 2/7 is unconnected. Q3/Q4 pin 3 is their joined source, pin 1 their shared
gate, and pin 2 their different drains. This checks actual saved pads as well
as `switch_circuit.py`, not just the prose map.

## Power and return paths

| Allowance on AUX | Current |
| --- | ---: |
| Screen board, including both main feeds, both touch feeds and its bleeder | 6.000 A |
| 40 ring pixels, RGB channels at unrestricted full white | 2.400 A |
| Normal ten-pill indications, source-pinned v3 model | 0.498 A |
| Idle allowance for all 120 LEDs | 0.120 A |
| Console logic | 0.140 A |
| Ring controller/buffer | 0.200 A |
| **Corrected total** | **9.358 A** |

The nominal 10 A AUX budget therefore has 0.642 A of planning margin. The old
9.408 A table counted the 50 mA screen bleeder twice. With all 120 LEDs at
unrestricted white instead of normal pill indications, the corresponding total
is 13.660 A and remains outside the 10 A supply budget. The ring's own path is
2.640 A including pixel idle and controller allowance. It does not flow through
the screen MOSFETs.

The user's current fields imply approximately 2.2 A for the two screens. The
reported steady power maxima imply 3.0 A at 5 V (9 W plus 6 W). Combining the
large screen's startup ceiling of 10 W with the small screen's 6 W maximum gives
a conservative 3.2 A planning figure, not a simultaneous measured peak. Adding
an intentionally conservative 1 A for both touch paths and 0.05 A for the
bleeder gives a 3.25–4.25 A screen-board bracket and about 6.61–7.61 A for AUX
with full-white ring and normal pills. None of these inconsistent meter readings
establishes a precise inrush bound.

At the full design allowances, Pi 25 W plus AUX 46.79 W is 71.79 W delivered
by the bucks. Illustrative 85–90% efficiency requires about 79.8–84.5 W, or
3.99–4.22 A at 20 V. Thus the system document's old “under 3 A”/59 W and “~3 A
worst case” fuse rationale no longer matches its own load table. The 100 W
contract has room in this illustrative budget, but the exact buck efficiency,
temperature derating and T5A fuse/holder curve are not known well enough to
claim complete input-protection coordination.

JST specifies 10 A for the selected standard VH family with 16 AWG; its
SVH-41T-P1.1 contact accepts 20–16 AWG. XH's 3 A rating is specified with
22 AWG, so the 2.64 A ring allowance requires the documented 22 AWG harness,
not the purchased 28 AWG USB leads. These connector ratings include their
conditions and are not automatic ratings for every compatible marketplace
housing. Sources: [JST VH](https://www.jst-mfg.com/product/pdf/eng/eVH.pdf),
[JST XH](https://www.jst-mfg.com/product/pdf/eng/eXH.pdf).

The main screen returns must accompany their power feeds back to J103/J203 and
then J1. GPIO ground and Pi USB ground provide signal references; neither is a
substitute for the main power return. HDMI/USB may create additional parallel
ground paths because they remain connected. Do not interpret the common-ground
design as galvanic isolation. The native board contains filled ground zones on
both copper layers, with nominal 0.5 mm thermal spokes and 0.25 mm gaps; an
updated copper-return review belongs with the final Revision K routing.

## Cable voltage drop and screen-port interaction

Using the existing nominal copper-wire resistance model, a 30 cm 28 AWG
two-conductor round trip is about 0.128 ohm. At 0.5 A that is about 64 mV and
32 mW; at 3 A it would be about 0.38 V and 1.15 W. Only the downstream touch
lead carries the touch supply: the upstream cable's VBUS carries approximately
34 mA for its coil. This is not a recommendation to send main screen power
through the selected 28 AWG leads.

A practical main-power harness contract is a short, 3 A-rated screen lead with
20 AWG or larger positive and ground conductors, preferably no more than
30 cm per branch, terminated in VHR-2N/SVH-41T-P1.1 at the PCB. Reterminate the
source end of the working 5 V lead while retaining the screen-side connector
and any attachment circuitry; do not replace it with an unspecified bare
USB-C connector. Nominal 20 AWG round-trip loss over 30 cm is about 60 mV at
3 A, before contacts and the fuse. A short 16 AWG input pair has still lower
wire loss. Exact screen-lead gauge/termination is not presently recorded and
must not be invented as an already owned part.

The 4 A main fuse has nominal 20.4 milliohm cold resistance; the 750 mA touch
fuse has 175 milliohm. That adds roughly 61 mV at 3 A and 88 mV at 0.5 A,
respectively, before fuse heating. Littelfuse specifies 25% continuous-current
derating plus temperature re-rating; the stated 3 A/0.5 A branch allowances
are consistent at reference conditions, but they are not active current limits.
At twice rated current, its specified maximum opening time is one second for
these ratings; do not promise a universal millisecond short-circuit shutdown.
[Littelfuse 251 data sheet](https://www.littelfuse.com/assetdocs/fuse-251-datasheet?assetguid=f47a0bb7-8ede-4679-9646-7114c3787688).

Both screen ports can share an internal supply. Consequently, main and touch
current division depends on the real screen and cable resistance; the board
does not enforce “main power only through the main connector.” Both feeds do
originate on the same switched rail, so this interaction does not restore
power when the board is disabled. However, an internally joined screen rail
can feed a fault through both fuses. Keep both intended main-power leads
connected; the 750 mA touch branch is not a rated fallback for powering a whole
screen after a main lead is removed.

The circuit calculations assume 5.0 V minimum at J1. A fixed nominal 5 V buck
plus input wiring cannot establish that floor by specification alone, and
downstream voltage also loses MOSFET, trace, fuse, contact and cable drops.
Retain this as an explicit qualification limit; do not silently call the
screen connectors guaranteed 5.0 V or infer that the buck is adjustable.

## USB and shutdown behavior

The large UPERFECT path must pass its 480 Mbps upstream hub link, even though
its touch controller behind the hub is 12 Mbps. APROTII's direct touch link is
12 Mbps. The existing short, matched PCB pairs, no data vias and preserved
ground reference address sensible layout requirements, but relay insertion
loss alone does not qualify a differential USB channel. The XH connectors,
split leads, relay pads and unknown cable pair construction remain real channel
discontinuities. TI recommends short differential paths and continuous return
reference; it does not certify this assembly.
[TI high-speed layout guidance](https://www.ti.com/lit/an/slla414/slla414.pdf).

The USB-C touch plug must present legacy-source Rp (56 kilohm nominal) to VBUS,
not sink Rd; the resistor is in the plug because XH4 has no CC conductor. This
does not negotiate PD or advertise a general 3 A source. Both orientations
must retain D+/D− continuity. The two-pin main output likewise implements no
PD or CC logic. Preserve the demonstrated working power termination. The
four-conductor XH harness carries no independent shield connection and the
board has no dedicated USB ESD suppressor; do not describe it as shield/ESD or
USB-compliance qualified.
[USB-IF Type-C specification, legacy cable rules](https://www.usb.org/sites/default/files/USB%20Type-C%20Spec%20R2.0%20-%20August%202019_0.pdf).

I inspected the GPIO daemon, service, Weston drop-in, Segno service ordering,
Yocto installation and Python dependencies. The recipe installs all three
screen-power files; its `python3-core`, `python3-io` and `python3-gpiod`
dependencies cover the used modules. The pinned Poky manifest puts `glob` and
`signal` in core and `socket` in io. The host suite independently passed
**12/12 tests**, including real socket-loop/termination behavior with mocked
GPIO, missing-controller rejection, interrupted enable, and failure cleanup.

Normal startup is: request GPIO17 low → publish daemon readiness → Weston's
pre-start requests high and waits one second → start display probing. Normal
shutdown is: Segno stops → Weston's stop hook requests low and waits five
seconds → Weston terminates → GPIO owner stops/releases low. `ExecStopPost`
also covers failed startup; `BindsTo` couples loss of the GPIO owner to stopping
Weston; force-off attempts to reclaim a released line after owner failure.
These use the documented systemd lifecycle ordering.
[systemd service semantics](https://raw.githubusercontent.com/systemd/systemd/main/man/systemd.service.xml),
[systemd dependency semantics](https://raw.githubusercontent.com/systemd/systemd/main/man/systemd.unit.xml).

This is not a hardware watchdog: a powered but hung Pi can retain GPIO high.
An unexpected loss of HDMI cannot be preceded retroactively by power removal.
The five-second delay is a provisional software wait, not a measured display
discharge time. The owner's observation that both displays go fully dark with
power and touch removed while HDMI remains connected supports the isolation
concept; it does not prove the exact GPIO-controlled shutdown timing. The image
and assembled board were not deployed or exercised by this review.

No new owner pre-order test is required by this report. First assembly still
needs the ordinary polarity/short check, touch enumeration/reconnect, normal
shutdown with HDMI attached, and warm full-load operation that the project
already records. Full USB compliance, destructive fault tests, quantified SOA
and a guaranteed enclosed operating envelope have not been established.

## Actionable findings

1. **Important — update the authoritative end-to-end wiring instructions.**
   `hardware/segno_wiring.md:23` and `:32` still draw unswitched screen power
   and direct touch USB. Its `:173` paragraph asks to repeat the already
   completed 5 V screen test and suggests an unrelated PD fallback. Replace
   those paths with the connection map above and record the user's actual
   results, so an assembler cannot unknowingly bypass the cutoff board.
2. **Important — reconcile the system power and harness budget.**
   `hardware/segno_wiring.md:51`, `:70`, `:99` and `:170` respectively retain
   the obsolete input-power rationale, double-count the bleeder, and specify
   18 AWG for a feed whose 10 A connector claim is conditioned on 16 AWG.
   Use the corrected 9.358 A AUX total, updated 20 V input estimate, separate
   expected-load bracket and a 16 AWG console input; retain appropriate
   uncertainty for the unspecified upstream fuse/buck behavior.
3. **Important — finish the separate main-power harness contract.**
   `hardware/kicad/screen_power/external_bom.csv:11` and `:12`, and
   `hardware/kicad/screen_power/README.md:140`, still say the power leads are
   to be selected without specifying their minimum gauge, length or rating.
   Record the short 20 AWG-or-larger, 3 A-rated lead requirement, VH termination
   and preservation of the proven screen-side connection; clearly retain the
   distinction between a defined assembly requirement and an unidentified
   existing cable. This does not require changing the PCB connector.

No Critical findings. Three Important findings. No Suggestion findings.
