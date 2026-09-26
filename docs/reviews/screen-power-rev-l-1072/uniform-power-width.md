# Uniform screen-power trace width

25 September 2026. Uniform **2.5 mm** outer-layer routes are suitable for the
documented **4.25 A** combined screen planning load. They remove the visible
neck-and-taper changes without requiring different components or heavier
copper. The former 6 A expansion allowance is not the design load.

## Exact board reviewed

Claude routing source: `e9fab839`.

- Native board: `hardware/kicad/screen_power/hand/screen_power_hand.kicad_pcb`
- Board SHA-256: `d3577772b4945f93652789e109fd232b479cfc8d119dcb67e499da51d39fa5cf`
- `route_critical.py` SHA-256: `2b8e10a22ccf56d9ef0d2ca19c3c3e8197fb65349fec09f1a041ad21d299f651`

The saved native tracks, including the segments approximating the rounded
bends, give these pad-center-to-pad-center lengths. Every power segment on
each selected run is 2.5 mm wide; narrow control branches are separate.

| Run | Layer | Segments | Length |
| --- | --- | ---: | ---: |
| Q3.3 to Q4.3, `COMMON_SOURCE` | F.Cu | 19 | 16.161370 mm |
| Q4.2 to F101.1, `SWITCHED_5V` | B.Cu | 37 | 25.522906 mm |

These routes are on opposite faces. The relevant terminal constraint is
clearance to the adjacent through-hole pad, not two 2.5 mm traces sharing
one face. At the parallel pad approach, 2.54 mm pitch, a 1.905 mm adjacent
pad and a 2.5 mm trace leave `2.54 − 1.905/2 − 2.5/2 = 0.3375 mm` nominal
clearance. Native DRC remains the final geometric check.

## Trace heating estimate

Use 1 oz outer copper, represented as 35 µm, and include the manufacturer's
20% negative track-width tolerance: a nominal 2.5 mm trace is evaluated at
**2.0 mm** finished width. These assumptions retain the existing two-layer,
1.6 mm board stack. [JLCPCB capabilities](https://jlcpcb.com/capabilities/pcb-capabilities).

For an external conductor, the IPC-2221 empirical estimate used in
[TI's layout guide, section 11](https://www.ti.com/lit/an/snva766/snva766.pdf)
is `I = 0.048 × ΔT^0.44 × A^0.725`, with cross-sectional area `A` in square
mils. Solving for temperature rise at 4.25 A gives:

| Copper width used | Estimated rise | Current at a 20°C rise |
| --- | ---: | ---: |
| 2.5 mm nominal | 8.16°C | 6.30 A |
| 2.0 mm after width tolerance | 11.79°C | 5.36 A |

This is an engineering estimate of trace self-heating, not a measured board
temperature or an unconditional thermal bound. It takes no credit for nearby
ground copper or the short traces' heat flow into terminals. Nearby MOSFET
heating and the enclosure establish the local board temperature. Copper
thickness is the specified nominal 1 oz; the calculation does not establish
the finished thickness of a particular manufactured board.

As an additional hot-resistance sensitivity, applying the 100°C resistance
factor below as an equivalent-current increase gives approximately **16.1°C**
rise for the reduced-width case: `11.79 × 1.3144^(1/0.88)`. This extrapolation
is a conservative extra stress calculation, not a replacement for the
empirical method or a prediction that the copper operates at 100°C.

## Voltage drop and dissipation

Use `R = ρL/(wt)`, `V = IR` and `P = I²R`. Round standard annealed-copper
resistivity upward to `ρ20 = 1.75×10⁻⁸ Ω·m`, with temperature coefficient
`0.00393/°C`. The standard coefficient and reference copper properties are
documented in [NBS Copper Wire Tables](https://nvlpubs.nist.gov/nistpubs/Legacy/hb/nbshandbook100.pdf).

For the conservative **100°C copper** calculation,
`ρ100 = ρ20 × [1 + 0.00393 × (100 − 20)] = 2.3002×10⁻⁸ Ω·m`.
Using the reduced 2.0 mm width, 35 µm thickness and full 4.25 A through both
runs gives:

| Run | Resistance | Drop | Copper loss |
| --- | ---: | ---: | ---: |
| Q3.3 to Q4.3 | 5.311 mΩ | 22.57 mV | 0.0959 W |
| Q4.2 to F101.1 | 8.387 mΩ | 35.64 mV | 0.1515 W |
| Both runs in series | 13.697 mΩ | **58.21 mV** | **0.2474 W** |

At nominal width, the corresponding hot-copper total is 46.57 mV and
0.1979 W. These figures cover only the two named tracks. MOSFET, fuse, via,
connector, remaining power copper and harness losses are separate; this is
not the total screen supply drop.

## Conservative gate-margin cross-check

The existing [gate-drive assessment](gate-drive.md) uses ideal PCB nodes.
Deduct the entire new two-run hot/tolerance drop from its low-corner source
voltage as an additional stress:

```text
V_source = 4.5 − 4.25 × (0.015 × 1.7) − 0.058214
         = 4.333411 V
|Vgs| = (4.333411 + 4.05 − 2.0) × 21780 / 26527
      = 5.2411 V
```

This retains approximately **0.74 V** above the 4.5 V gate-drive point used
for the conservative MOSFET resistance. It deliberately counts the
downstream Q4 drain-feeder drop as though that loss also reduced the common
source voltage. The 2 V optocoupler drop and hot MOSFET resistance remain
the existing engineering stress assumptions. At the assessment's 1 V
optocoupler drop, the same added copper deduction leaves 6.062 V gate drive.
No component or gate-drive model change follows from the uniform-width routes.

## Validation contract

The saved-board checks deliberately require a continuous **2.5 mm** track
path for these runs, with filled zones removed so an overlay cannot hide a
missing or narrow track. Separate assertions reject width changes and taper
overlays on the selected power runs while permitting their control branches.
The three 0.45 mm transition vias and the fuse-barrel bypass check remain
required. The AUX input and other branch-width requirements are unchanged.

Final release still uses native DRC, the width/connectivity fault controls,
visual copper review and regenerated CAM parity for the final sources. This
assessment supports the width decision; it does not approve a stale package
or require another owner measurement campaign.
