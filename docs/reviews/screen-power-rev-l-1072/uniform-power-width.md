# Uniform screen-power trace width

**Historical checkpoint — superseded artwork.** The [all-three-board audit](../pcb-finish-all-three-1072/audit.md) and its [archive manifest](../pcb-finish-all-three-1072/manufacturing-zips.json) identify the current rounded boards and exports. The hashes and fabrication counts below describe the earlier checkpoint only. Circuit and power calculations remain applicable where their geometry and components are unchanged.

26 September 2026. A uniform **2.0 mm AUX input** route and uniform **2.5 mm
MOSFET source bridge and drain feeder** are suitable for the documented
**4.25 A** combined screen planning load. They remove the visible
neck-and-taper changes without requiring different components or heavier
copper. The former 6 A expansion allowance is not the design load.

## Exact board reviewed

Claude routing source: `42f7653c` for AUX, followed by the fillet-closure
correction `ffaca8b63b51ad76ceebe4eec9244c12a6c0f0a4`; the other two power
runs originate in `e9fab839`.

- Native board: `hardware/kicad/screen_power/hand/screen_power_hand.kicad_pcb`
- Board SHA-256: `94ffa2a0ad3d428451798306c24dc087cbdf3e122cecefa7753c840033321a2b`
- `route_critical.py` SHA-256: `30b5f8ce2b49e073d40773af9e0791a92cdcf0513d1804e4c46b06d9283d0016`

The saved native tracks, including the segments approximating the rounded
bends, give these pad-center-to-pad-center lengths. Each selected run has one
width throughout; narrow control and capacitor branches are separate.

| Run | Layer | Width | Segments | Length |
| --- | --- | ---: | ---: | ---: |
| J1.1 to Q3.2, `AUX_5V` | F.Cu | 2.0 mm | 37 | 15.967206 mm |
| Q3.3 to Q4.3, `COMMON_SOURCE` | F.Cu | 2.5 mm | 19 | 16.161370 mm |
| Q4.2 to F101.1, `SWITCHED_5V` | B.Cu | 2.5 mm | 37 | 25.522906 mm |

The AUX input and source bridge both approach adjacent Q3 pads on F.Cu.
Their 2.0/2.5 mm widths at 2.54 mm pitch leave
`2.54 − 2.0/2 − 2.5/2 = 0.29 mm` nominal clearance, above the 0.2 mm rule.
Making AUX 2.5 mm would leave only 0.04 mm and violate that rule. The source
bridge and Q4 drain feeder are on opposite faces; a 2.5 mm trace beside a
1.905 mm through-hole pad leaves 0.3375 mm nominal clearance. Native DRC
remains the final geometric check.

The rounded capacitor branches retain 1.5 mm to C2 and 0.8 mm to C1. They
do not carry the continuous combined screen load and are not included in
the three series power-run lengths above.

## Trace heating estimate

Use 1 oz outer copper, represented as 35 µm, and include the manufacturer's
20% negative track-width tolerance: the nominal 2.0 mm AUX trace is evaluated
at **1.6 mm** finished width, and each nominal 2.5 mm run at **2.0 mm**.
These assumptions retain the existing two-layer, 1.6 mm board stack.
[JLCPCB capabilities](https://jlcpcb.com/capabilities/pcb-capabilities).

For an external conductor, the IPC-2221 empirical estimate used in
[TI's layout guide, section 11](https://www.ti.com/lit/an/snva766/snva766.pdf)
is `I = 0.048 × ΔT^0.44 × A^0.725`, with cross-sectional area `A` in square
mils. Solving for temperature rise at 4.25 A gives:

| Run and copper width used | Estimated rise | Current at a 20°C rise |
| --- | ---: | ---: |
| Source bridge/drain feeder: 2.5 mm nominal | 8.16°C | 6.30 A |
| Source bridge/drain feeder: 2.0 mm after width tolerance | 11.79°C | 5.36 A |
| AUX: 2.0 mm nominal | 11.79°C | 5.36 A |
| AUX: 1.6 mm after width tolerance | 17.03°C | 4.56 A |

This is an engineering estimate of trace self-heating, not a measured board
temperature or an unconditional thermal bound. It takes no credit for nearby
ground copper or the short traces' heat flow into terminals. Nearby MOSFET
heating and the enclosure establish the local board temperature. Copper
thickness is the specified nominal 1 oz; the calculation does not establish
the finished thickness of a particular manufactured board.

As an additional hot-resistance sensitivity, applying the 100°C resistance
factor below as an equivalent-current increase gives approximately **16.1°C**
rise for the reduced-width source bridge/drain feeder and **23.2°C** for
reduced-width AUX: multiply each empirical rise by `1.3144^(1/0.88)`.
This extrapolation is a conservative extra stress calculation, not a
replacement for the empirical method or a prediction that the copper
operates at 100°C. In particular, it does not claim a strict 20°C rise limit
for AUX under every temperature assumption.

## Voltage drop and dissipation

Use `R = ρL/(wt)`, `V = IR` and `P = I²R`. Round standard annealed-copper
resistivity upward to `ρ20 = 1.75×10⁻⁸ Ω·m`, with temperature coefficient
`0.00393/°C`. The standard coefficient and reference copper properties are
documented in [NBS Copper Wire Tables](https://nvlpubs.nist.gov/nistpubs/Legacy/hb/nbshandbook100.pdf).

For the conservative **100°C copper** calculation,
`ρ100 = ρ20 × [1 + 0.00393 × (100 − 20)] = 2.3002×10⁻⁸ Ω·m`.
Using the reduced widths, 35 µm thickness and full 4.25 A through all three
runs gives:

| Run | Resistance | Drop | Copper loss |
| --- | ---: | ---: | ---: |
| J1.1 to Q3.2, at 1.6 mm | 6.559 mΩ | 27.87 mV | 0.1185 W |
| Q3.3 to Q4.3 | 5.311 mΩ | 22.57 mV | 0.0959 W |
| Q4.2 to F101.1 | 8.387 mΩ | 35.64 mV | 0.1515 W |
| All three runs in series | 20.256 mΩ | **86.09 mV** | **0.3659 W** |

At nominal widths, the corresponding hot-copper total is 68.87 mV and
0.2927 W; AUX alone is 22.30 mV and 0.0948 W. These figures cover only the
three named tracks. MOSFET, fuse, via, connector, remaining power copper and
harness losses are separate; this is not the total screen supply drop.

## Conservative gate-margin cross-check

The existing [gate-drive assessment](gate-drive.md) uses ideal PCB nodes.
Deduct the entire three-run hot/tolerance drop from its low-corner source
voltage as an additional stress:

```text
V_source = 4.5 − 4.25 × (0.015 × 1.7) − 0.086088
         = 4.305537 V
|Vgs| = (4.305537 + 4.05 − 2.0) × 21780 / 26527
      = 5.2182 V
```

This retains approximately **0.72 V** above the 4.5 V gate-drive point used
for the conservative MOSFET resistance. It deliberately counts the
downstream Q4 drain-feeder drop as though that loss also reduced the common
source voltage. The 2 V optocoupler drop and hot MOSFET resistance remain
the existing engineering stress assumptions. At the assessment's 1 V
optocoupler drop, the same added copper deduction leaves 6.039 V gate drive.
No component or gate-drive model change follows from the uniform-width routes.

## Validation contract

The saved-board checks deliberately require a continuous **2.0 mm AUX** track
path and **2.5 mm source bridge/drain feeder**, with filled zones removed so
an overlay cannot hide a missing or narrow track. Separate assertions reject
width changes and taper
overlays on the selected power runs while permitting their control branches
and the rounded AUX capacitor junctions.
The three 0.45 mm transition vias and the fuse-barrel bypass check remain
required. The AUX minimum is deliberately raised from 1.9 mm to 2.0 mm;
the capacitor and other branch-width requirements remain unchanged.

Final release still uses native DRC, the width/connectivity fault controls,
visual copper review and regenerated CAM parity for the final sources. This
assessment supports the width decision; it does not approve a stale package
or require another owner measurement campaign.
