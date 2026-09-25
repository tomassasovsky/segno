<!-- cspell:words Kimi Mbps -->
<!-- cspell:words datasheets WIMA CadQuery heatsinks -->
# Revision K screen-power verification

25 September 2026. Baseline commit: `9a5798be6c4ea9b0aae2a88fe7168b6751cab441`.
Issue [#1072](https://github.com/tomassasovsky/segno/issues/1072),
PR [#1080](https://github.com/tomassasovsky/segno/pull/1080).

The screen board now has gradual power-copper transitions, accurate capacitor
assembly models and clearance for the plugged-in power connector. The complete
circuit and its integration were independently checked, beyond design-rule
checking. **Local CAD and fabrication checks pass. The newly requested external
multi-model reviews remain incomplete because both providers reached usage
limits; no external approval of Revision K is claimed.**

Revision K supersedes J as the current screen package. Revision I remains
withdrawn for its disconnected relay commons. The corrected J contact mapping
is retained: host data on commons 3/6, screen data on normally open 4/5.
Console and ring manufacturing files are unchanged.

## Finished change

- Short 1.9 mm approaches remain where adjacent MOSFET pads require clearance.
  The central source bridge, including both diagonal bends, is now 3 mm.
  Eight filled tapers widen the source/input/output approaches and the four
  3 mm fuse branches into the 4.5 mm shared distribution rail. Each overlays
  an already continuous track; no power route depends on a taper alone.
- C1 moves 1.5 mm left and gains an explicit 0.8 mm feed. The nominal film
  body clears the conservative full mated VH envelope by 0.55 mm and the
  maximum C2 body by 0.782 mm. These are CAD clearances, not a physical fit test.
- The selected Panasonic capacitors are 11.2/11.0 mm tall, rather than the
  old generic models' 6.3/5.0 mm. The WIMA model is now its nominal 6.5 mm.
  Separate maximum-envelope checks include Panasonic tolerances. Polarity
  stripes are on the exterior negative-lead side, and trimmed leads are
  documented. All 37 populated parts have portable models.
- The wiring diagram routes both power and touch through this board. Separate
  main leads are at most 30 cm, 20 AWG or larger on both conductors, with 3 A
  terminations and the known-working screen plug/attachment electronics.
  The aggregate power budget includes the ring, normal pills, screens, bleeder
  and conversion-loss estimate. There are no extra modules or SMD parts.

The 68 × 76 mm outline, 3 mm corners, two copper layers, purple mask, connector
orientations, BOM and component values are retained. Only C1 changes position.
No firmware or device setting changed.

## Engineering checks

| Area | Evidence and conclusion |
| --- | --- |
| Component datasheets and pinouts | Independent complete audit of all 37 populated parts: MOSFET G/D/S and body diodes, relay contact diagram, small-transistor terminals, diodes, resistor tolerances, capacitor voltage/polarity, fuses and exact connectors. No additional connection or rating error found within the documented operating assumptions. [Circuit audit](raw/circuit-audit.md). |
| Circuit correspondence | Independently exported native schematic XML agrees with PCB and BOM: 41 references including holes, 96 connected pins, 27 nets. All four relay combinations and 16 data paths behave as intended in the contact graph. |
| Power states | GPIO high/low/floating, Pi VBUS absent, AUX absent with screen-side voltage and reverse blocking while off were traced. Enabled MOSFETs conduct both ways; the circuit does not provide reverse-polarity protection or detect a hung Pi. |
| Wiring and total power | Connector-by-connector map, alternate touch power, independent ring rail and GPIO17 pair checked. Conditional 6 A screen allowance plus full-white ring and normal pills is 9.358 A AUX; all 120 pixels at white would exceed 10 A. At full design allowances, the assumed inlet load is about 4.0–4.2 A at 20 V. [Wiring/power matrix](wiring-and-power.md). |
| Heat and voltage | Expected screen loads support upright MOSFETs without heatsinks under the documented estimate. The 15 mΩ maximum requires −4.5 V gate drive; calculations assume 5.0–5.25 V at J1, which a fixed nominal 5 V buck plus cable drop does not establish. No unconditional 6 A thermal rating is claimed. |
| USB data and return | Paired B.Cu geometry is retained, with no data vias; equal nominal pair lengths and 5,452 F.Cu ground-reference samples pass. Relay contacts and host/screen power separation agree with the circuit. Actual 480 Mbps cable/link performance still requires the assembled path. |
| Routed power continuity | All 12 minimum-width paths remain connected after independently deleting every zone and via. The dedicated power-via bypass remains connected with F101's input barrel removed. Eight taper nets, layers and fills checked. |
| Electrical/design rules | Native ERC and full-severity, all-track DRC: zero reported errors, warnings, exclusions and unconnected items under the committed project rules. No ignored electrical clearance category added. |
| Regression checks | 36/36 existing fault controls pass. Independent additional mutations prove the new C1 minimum-width guard, rejection of wrong taper names/nets/layers and missing front GND. Tests also prove that removing all eight tapers does not break power continuity. [Test review](raw/test-quality.md). |
| Mechanical/assembly | Lead dimensions versus finished-hole tolerance, polarity, 37 THT parts, two layers, M3 keepouts, connector orientation, maximum capacitor envelopes and full mated VH envelope checked. Corrected populated STEP and renders inspected. [Assembly audit](raw/assembly-audit.md). |
| Shutdown integration | Existing GPIO lifecycle host tests pass 12/12; startup and normal shutdown call sites were traced. The five-second discharge delay remains provisional. Actual screen darkness before HDMI loss is not proven by host tests. |
| Fabrication correspondence | Independent fresh export matches seven Gerbers, two drill files and job JSON after creation timestamps only. All 59 source hashes, 64 artifacts and 12 ZIP members match; 358 assertions pass. Drill-map PDFs receive identity checks, not independent content checks. [Machine record](fabrication-verification.json). |

## Review coverage and remaining boundary

Completed independent Codex roles cover complete circuit architecture,
assembly/readiness, system wiring, test quality, conventions and simplicity.
The [consolidated report](review.md) records corrected findings and final scope.
The [bug-focused review](../../code-review/screen-power-rev-k-1072/review.md)
covers this revision's intended diff, not every older change in the stacked PR.

Actual Claude Code and OpenCode Go DeepSeek, Kimi and Grok attempts are recorded
in [external-model-reviews.md](external-model-reviews.md). DeepSeek's regional
restriction was resolved on retry, but all three Go reviews subsequently hit
the shared usage limit before a final report. Claude was already session-limited.
A partial inspection is not counted as a clean review.

No additional owner measurements are prerequisites for buying bare prototype
PCBs under the existing first-fabrication decision. This is not qualification
of an assembled production unit. The actual harness, loaded supply/gate voltage,
startup, heat, USB reconnection and shutdown timing remain first-assembly
checks. Four enclosure floor mounts are still to be integrated; proposed
placement behind CLEAR does not establish final cable/assembly fit.

## Current manufacturing package

[segno_screen_power_rev_k_gerbers.zip](../../../hardware/kicad/fab/segno_screen_power_rev_k_gerbers.zip)
contains seven Gerber layers, two separate drill files, two drill maps and the
job file. Select bare PCB, two-layer FR4, 1.6 mm, 1 oz outer copper, ENIG,
purple solder mask and white silkscreen. No stencil or assembly service.

- Native board SHA-256: `d35484d551cf8f526f62c4356accbff0492c28999beb0e8830801c39f00c83da`.
- Screen ZIP SHA-256: `171034c87f3d371db9f7017a196960bdb7e01c249c1178eba90abb3ab2f05e3c`.

[manufacturing-zips.json](manufacturing-zips.json) identifies all three current
archives. The local delivery retains J only in a clearly superseded folder;
I remains quarantined as do-not-order. No order, merge, deployment or flash
was performed. PR labels remain `ci:pending`, `review:pending` and
`autonomy:blocked-verify`: feature-base CI has not established a green gate,
and external review plus assembled validation remain incomplete.
