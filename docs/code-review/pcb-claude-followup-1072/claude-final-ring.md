<!-- cspell:words Littelfuse rerating derating Ciss Qwiic VREG netclass ampacity EEUFR nonplated -->
# Ring carrier — completed Claude follow-up and evidence check

Date: 2026-09-27. Reviewed hardware revision: `60ff3a637a400deb1ce846f6cb76979c94250a32`. Associated runtime revision: `53828fc4eae1c18af45abfc3ea7c31f19f9799d7`.

**Verdict: no unresolved actionable ring-board findings.** The resumed Claude review completed normally after 16 turns, closed or withdrew its seven earlier findings, and supports releasing the ring carrier's bare-board fabrication files. A separate bounded evidence check found no new defect in that conclusion. This is a design/fabrication release verdict, not certification of assembled performance or permission to order, merge or flash.

## Finding disposition

| Prior finding | Resolution |
| --- | --- |
| Encoder filter bandwidth | C2/C3/C4 are 10 nF in source, netlist, native PCB and BOM; C5 remains 100 nF. The exact Vishay K103K10X7RF53H5 part fits the existing 5 mm-pitch footprint. Conservative RC release to the RP2350 high threshold is below 0.13 ms. Claude withdrew the earlier definite high-speed failure and contact-life assertions: the encoder's 3.5 ms phase guarantee applies at 60 rpm. |
| Hand soldering of ground pads | Both ground pours use through-hole thermal relief with 0.5 mm gaps/spokes; surface-mount ground remains solid. U2.1 uses 45° spokes. The encoder's 350 °C/3 s soldering limit remains binding; relief is an improvement, not proof of achievable dwell. |
| Strip-entry capacitance | The selected harness now includes Panasonic EEUFR1A102, 1000 µF/10 V, directly across strip-entry power with polarity, individual lead insulation, strain relief and vent clearance documented. Carrier C1 remains present. This improves local energy storage; it is not an inrush limiter. |
| Clearance enforcement | Native board minimum and default netclass clearance are 0.2 mm; geometry passes the stronger rule. Guards reject weakened settings. |
| Carrier guard scope | `ring_power.py` explicitly checks retained carrier paths. It does not claim to validate the independently powered 40-LED strip harness. |
| Mechanical-tab grounding | Claude withdrew the proposed unconditional ground connection. The part drawing does not guarantee shaft/bushing continuity through the tabs. Their use as mechanical supports is documented; assembled-system ESD qualification is outside this board review. |
| Encoder naming | Current procurement/assembly documents name ACZ11BR1E-20FD1-20C and the separate SJ5-43502PM-nut. The measured legacy EC11 bench diffuser remains explicitly historical. |

## Current evidence

The completed Claude review independently checked the changed component values, thermal and clearance settings, current runtime mapping, unchanged routing/placement structure, and a fresh CAM plot against the shipped archive. It reported no additional actionable findings. Earlier complete ring coverage of the circuit, pin/net roles, exact encoder fit, AHCT buffering, power and return paths, UART direction, alternative module footprints and two-layer stackup remains applicable to the unchanged design portions.

The separate closeout check observed:

- KiCad DRC: **0 violations and 0 unconnected items**, all severities and all track errors enabled.
- `ring_encoder.py --self-test`: actual board passes and **all 13 negative controls are rejected**.
- `starved_thermal` is an error and the minimum resolved-spoke rule is two. This establishes the configured connectivity requirement, not four spokes on every pad or a thermal current rating.
- All **10 flat ZIP members** exactly match the published loose files. Another fresh native export matches all 10 after the existing strict timestamp-only normalization. Exports leave the native board unchanged.
- The existing [console/ring fabrication verification](console-ring-fabrication-verification.json) already records **175 passed checks, zero failures**, including fresh CAM parity. Claude's later CAM check adds independent confirmation; it was not the first verification.
- Published plated drills: 0.4 mm ×21, 0.8 mm ×34, 1.1 mm ×6, 1.25 mm ×8, 1.3 mm ×5 and 3.0 mm ×2, totaling 76. No nonplated holes.
- Encoder high-level DC margin remains adequate with the existing 10 kΩ external pulls and runtime internal pull-ups. RP2350 E9's excess leakage sources current; it is not a 120 µA high-state sink penalty. The ring runtime is unchanged between `dd46ab0d` and `53828fc4`.

No equivalent-width IPC ampacity claim is made for the relief spokes. The selected carrier allowance remains 0.20 A; the 40-LED strip's high-current supply bypasses this PCB through the documented star harness.

## Verified identities

| Artifact | SHA-256 |
| --- | --- |
| `hardware/kicad/segno_pedal_ring.kicad_pcb` | `2a2d139d824a981edb4f455533b4d57a190f456496606b1f80d9dc52b9c097cb` |
| `hardware/kicad/segno_pedal_ring.kicad_pro` | `a6cffa59f01474001d594b966af544395dd25a9448ea00834447ec3fc61b89f0` |
| `hardware/kicad/fab/segno_pedal_ring_gerbers.zip` | `b7486b4a8139de9c070c85f095e1710997a0f2e3d6e0fc3174d36d129b250759` |

## Limits

Actual soldering, encoder feel/bounce, crimp quality, actual harness voltage drop, capacitor mounting and the purchased strip's current/internal voltage drop remain assembly-dependent. The 4.75 V loaded-AUX floor is the documented design bound, not a newly certified buck specification. The simplified encoder STEP is a drawing-derived envelope; exact fit uses the part drawing and tolerances. Neither this closeout nor Claude's ring-only pass establishes the other two boards' review status or system EMC/ESD compliance. No pre-PCB prototype or new owner measurement was requested by this pass.
