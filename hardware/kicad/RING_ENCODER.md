<!-- cspell:words Digi undimensioned -->
# Ring encoder part and fit contract

Fit **Same Sky ACZ11BR1E-20FD1-20C** at ENC1. This exact part has a momentary
switch, vertical leads, a 20 mm D shaft, an M7×0.75 bushing 5 mm long, and
20 pulses / 20 detents per revolution. The previous generic EC11 footprint
and ALPS EC11E18244AU selection were incompatible and have been removed.

Source: [Same Sky ACZ11 datasheet](https://www.sameskydevices.com/product/resource/acz11.pdf),
revision 1.08, 2026-05-07, pages 1–4. The reviewed PDF SHA-256 is
`a1d5e9764abdf31c5da469bc044ad1ea916185cd0b6459b692f1e1aa52396996`.
The [DigiKey listing, 102-1768-ND](https://www.digikey.com/en/products/detail/same-sky-formerly-cui-devices/ACZ11BR1E-20FD1-20C/1923363)
allows single-quantity purchase. Procure the documented **SJ5-43502PM-nut**
separately; supplied hardware is not established by the encoder datasheet.
The datasheet names replacement 071-0068R / 071-0069R but gives no dimensions
for them. No part has been purchased by this change.

Hand solder at **350 °C maximum for at most 3 seconds** per terminal. Keep the
existing 10 kΩ pull-ups to 3.3 V and 100 nF filters (1 ms nominal RC). The
manufacturer specifies 5 V maximum supply, shows 10 kΩ pull-ups, and does not
specify a minimum contact current. The old ALPS minimum-current finding is
resolved by selecting this exact component; it is not a waiver for ALPS parts.
Runtime INPUT_PULLUP is in parallel with the fitted resistor, making release
slightly faster. The filter is the existing board circuit, not a reproduction
of the manufacturer's optional two-resistor filter.

## Physical coordinates

The footprint origin is the shaft centre, fixed at PCB (35.9825, 35.7675) mm.
Coordinates below are the manufacturer's **top view**, with PCB Y increasing
toward the A/C/B terminals. S1/S2 are the datasheet's D/E switch contacts.

| Pad | X / Y from shaft, mm | Signal | Nominal finished-hole diameter, mm |
| --- | --- | --- | --- |
| A | −2.5 / 7.5 | ENC_A / XIAO D1 | 1.30 |
| C | 0 / 7.5 | GND | 1.30 |
| B | 2.5 / 7.5 | ENC_B / XIAO D2 | 1.30 |
| S1 | −2.5 / −7 | ENC_SW / XIAO D3 | 1.30 |
| S2 | 2.5 / −7 | GND | 1.30 |
| MP1 / MP2 | −4.7 / 0 and 4.7 / 0 | unconnected mechanical tabs | 3.00 |

The manufacturer recommends 1.2 mm signal holes and rectangular 1.8×2.1 mm
support openings. Circular plated 3.0 mm support holes accommodate the entire
recommended rectangle: its diagonal is 2.766 mm, below the 2.92 mm minimum
finished diameter after a −0.08 mm fabrication tolerance. Signal holes remain
at least 1.22 mm at the same tolerance. The [JLCPCB finished-PTH tolerance](https://jlcpcb.com/capabilities/Capabilities)
is asymmetric, +0.13/−0.08 mm. Copper pads are 3.6 mm (support) and
1.9 mm (signal), each leaving 0.235 mm concentric annulus at the largest hole. This calculation
covers diameter tolerance; it is not an unconditional finished-board minimum
after registration. JLCPCB separately specifies ±0.05 mm hole position. The
nominal annulus is 0.30 mm, above its 0.25 mm recommendation for two-layer
1 oz PTH pads. The guard uses a 0.23 mm lower bound for the calculated
concentric annulus, rounded down from the specified geometry's 0.235 mm;
it does not substitute a new fabrication or registration tolerance.
This uses ordinary circular plated drills and retains solderable mechanical
tabs; the enclosure's threaded nut provides final clamping.

Body dimensions are nominal 11.7 mm wide and 13.75 mm long (7.25 mm above,
6.5 mm below the shaft in the top drawing). The seating-to-shaft datum is
6.5 mm. The bushing occupies Z=6.5…11.5 mm above the front PCB surface and the
shaft ends at Z=26.5 mm. Shaft diameter is 6.0 +0/−0.1 mm; across-flat size is
4.5 +0/−0.1 mm and flat length is 10 mm. Switch travel is 0.5 mm. General
drawing tolerances are ±0.3 mm through 10 mm and ±0.5 mm above 10 through 30 mm.
The enclosure retains its 7.2 mm M7 clearance hole and nut mount. Use the
[Same Sky SJ5-43502PM-nut](https://www.sameskydevices.com/product/resource/sj5-43502pm-nut.pdf),
drawing rev C dated 2024-09-12: M7×0.75, 2.0±0.1 mm thick, 10.0±0.1 mm across
flats. Clamp the 2.0 mm disc directly with that nut, **without a washer**.
The nominal stack is 4.0 mm; the nut maximum gives 4.1 mm, below the bushing's
4.7 mm minimum. A disc manufactured at up to 2.1 mm still leaves 0.5 mm of
thread past the nut. This is a drawing-based assembly allocation, not a claim
that unspecified replacement washers were checked. The 10.1 mm maximum nut
has an 11.67 mm corner diameter, inside the enclosure model's 22 mm relief.

The existing purchased-knob model assumes a 12 mm blind bore and a 4.5 mm-deep
nut relief. The 20 mm shaft allows its tip to enter that bore with the knob
raised above the disc; allow 0.8 mm maximum axial switch travel (0.5 mm plus the general 0.3 mm
tolerance) and clearance.
The knob's undocumented relief remains a pre-existing enclosure-model
assumption; the PCB does not require a new hole or a changed shaft centre.

The STEP file is a **drawing-derived nominal envelope**, generated by
`ring_encoder_model.py`, not official manufacturer CAD. It contains the
correct body, shaft, bushing and terminal centres. Threads, internal contacts
and undimensioned shell shapes are omitted; terminal thickness is illustrative.
The manufacturer CAD download service failed during this change. Tight fit
checks use the drawing and its tolerances, not that simplified model alone.

## Runtime contract and checks

For the 20C option, both contacts are open at each detent. With pull-ups and
A as the high bit, a clockwise click is **11 → 01 → 00 → 10 → 11**;
counterclockwise reverses it. One cycle is one click. Keep the physical A/B
assignments above. The runtime must emit +1 for that clockwise sequence so
that the console's unchanged-sign delta increases the application's gain.
The direction correction and executable waveform tests belong to
[runtime PR #1082](https://github.com/tomassasovsky/segno/pull/1082), commit
`dd46ab0d1a44bc55c7f42bc7db7992773c7a4113`; firmware
installation is separate from bare-board fabrication.

Run `ring_encoder.py --self-test` with KiCad Python. It checks actual placed
and library pads, shaft datum, plated holes including fabrication tolerance,
annulus, net roles, exact part and model transform. Its eight fault controls
include an outward-shifted mounting tab, changed A-C spacing, wrong switch
row, too-small support drill, undersized annulus, A assigned the B signal,
shifted shaft and generic encoder substitution.
Run the ordinary ring generator/selftest, ring power guard, native DRC and
silkscreen guard as well. The encoder guard also runs before route-script CAM
export. The current correction preserves every other component placement, the board
boundary and power geometry, changing only ENC1 and five attached segment
endpoints by 0.04 mm before refilling the ground planes.
