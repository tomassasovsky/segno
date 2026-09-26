<!-- cspell:words onsemi Littelfuse Mbps -->
# Screen-power independent repeat review

Date: 2026-09-26. Reviewed HEAD: `368b9bd72589e12853ea7d47595351f67c843452`.
PR #1080 base: `5fd9f8bf6856673d07b27054d0b98dd7ba719561`.

**No actionable circuit, PCB or assembly-definition defect found.** The scoped
screen-board review is complete. Finding count: 0; unresolved findings: 0.
This is a fresh review of the complete current Revision M design, with native
read-only checks and independent pad/geometry calculations. It is not assembled
hardware acceptance, USB certification, manufacturing-export comparison or the
whole-PR review gate. No production file or Git state was changed by this review.

## Coverage and findings considered

Reviewed `circuit.py`, `switch_circuit.py`, `pcb.py`, `layout.py`,
`route_critical.py`, `finish.py`, `router.py`, `cleanup.py`, `build.sh`,
`hand_checks.py` and the native-check logic, plus the actual routed PCB,
project/netlist/schematic, component records, exact board/external BOMs,
custom footprints, assembly-model dimensions and current wiring instructions.
The complete screen circuit is new relative to the PR base; the review was
not restricted to the last relay correction.

- **Wrong relay contacts or package orientation:** compared the native pad
  coordinates and nets to TE's top-view non-latching diagram. Both relays use
  coil 1 positive/8 negative, host D−/D+ on commons 3/6 and screen D−/D+ on
  makes 4/5. Break contacts 2/7 are unconnected. The native 5.08 mm row pitch
  and 3.2/2.2/2.2 mm column pitch match the standard THT package. The 0.90 mm
  drill retains 0.82 mm at the stated fabrication tolerance, above the 0.75 mm
  recommendation. Sources: [TE original drawing, page 5](https://static.chipdip.ru/lib/764/DOC000764069.pdf),
  [TE current IM family data](https://www.mouser.com/datasheet/2/418/9/ENG_DS_108_98001_1-3079448.pdf).
- **Host power reaching a screen or energizing a disabled coil:** traced each
  host connector through its own 10 kΩ/100 kΩ gate network. Coil positive and
  bypasses use AUX. Native S1/G2/D3 assignments and directed body diodes pass
  an independent 24-state sweep, including floating GPIO and independent host
  loss. A 5.5 V host supplies approximately 51.5 µA with the documented leakage
  allowance; even a grounded sense node gives only 0.556 mA through the series
  resistor. This is a DC circuit bound, not a complete-device suspend test.
  [Microchip TN0702, pin table and electrical limits](https://www.microchip.com/content/dam/mchp/documents/APID/ProductDocuments/DataSheets/TN0702-N-Channel-Enhancement-Mode-Vertical-DMOS-FET-Data-Sheet-20005941A.pdf).
- **Reversed power switch, weak gate drive or off-state feed:** the actual
  Q3/Q4 pads are G1/D2/S3, with joined sources and separate drains. The two
  opposed body diodes block either through path when off; enabled channels
  conduct both ways. R4 returns the gates to their common source, not AUX.
  Independently checked gate arithmetic gives 6.110 V at the low assessment
  corner, or 5.289 V with the larger 2 V optical-drop sensitivity. Maximum
  assessed drive is 8.682 V against the ±20 V gate limit. At 4.25 A, the stated
  hot-resistance/75°C/W assumptions give 0.461 W and 94.5°C per MOSFET.
  [Vishay SUP70101EL, pages 1–2 and 5](https://www.vishay.com/docs/77632/sup70101el.pdf).
- **Pump or optical pin mismatch:** U1 pins 2/4 connect the flying capacitor,
  5 the negative rail, 3 ground and 8 AUX; pins 1/6/7 remain unconnected.
  U2 emitter 3 connects to the negative rail, collector 4 to the gate resistor,
  and LED 1/2 to the AUX-driven control network. D2 clamps positive negative-rail
  excursions. C3/C4 are the specified nonpolar parts. GPIO has no negative-rail
  connection. The transistor buffer uses the exact BU E/B/C pin order.
  Sources: [TI LMC7660](https://www.ti.com/lit/ds/symlink/lmc7660.pdf),
  [Toshiba TLP627M, pages 2–3 and 13](https://toshiba.semicon-storage.com/info/docget.jsp?did=163903&prodName=TLP627M),
  [onsemi 2N3904BU](https://www.onsemi.com/download/data-sheet/pdf/pzt3904-d.pdf),
  [onsemi 2N3906BU](https://www.onsemi.com/download/data-sheet/pdf/pzt3906-d.pdf).
- **Relay heat or hot-pickup margin:** independently solved the documented
  minimum-coil-resistance/self-heating case. At 60°C air, 5.25 V preheating and
  150 K/W, the modeled winding is 85.44°C. Restarting at 4.75 V through the two
  5 Ω driver allowances gives 4.475 V versus the temperature-scaled 4.209 V
  pickup estimate: 0.265 V margin. This supports the stated envelope, not an
  85°C ambient hot-start guarantee. Coil flyback polarity is correct.
- **Unbounded startup or fuse claims:** re-read the SUP70101EL pulse SOA and
  transient-thermal graph. The retained startup note labels its capacitance,
  current and mounting assumptions correctly; it does not turn the nominal
  10 A buck into a current clamp. The 4 A main fuses and 750 mA touch fuses are
  sustained-fault protection, while 3 A/500 mA remain lead ceilings. Their
  published hold/opening behavior does not establish a hard current limit.
  R8 reaches 0.2784 W at 5.25 V and −1% resistance against its 1 W rating.
  [Littelfuse 251 data](https://www.littelfuse.com/assetdocs/fuse-251-datasheet?assetguid=f47a0bb7-8ede-4679-9646-7114c3787688),
  [Vishay PR01](https://www.vishay.com/docs/28729/pr010203.pdf).
- **Physical interference and holes:** inspected a newly generated populated
  top view and the actual pad/drill table. All 50 populated components are
  through-hole, with four separate shield pads and four NPTH mounting holes.
  DIP drills are 0.90 mm; TO-92 drills 0.95 mm; Q3/Q4 drills 1.40 mm; VH drills
  1.80 mm. Maximum U1/U2 body widths leave 0.965 mm between their bodies at the
  native centers. The capacitor envelopes, live TO-220 tabs, mated-housing
  clearance and short insulated shield-drain construction were checked against
  their stated placement assumptions. No conflicting body envelope was found.
  Capacitor ratings and dimensions were cross-checked against
  [Panasonic SU-A](https://industrial.panasonic.com/ww/products/pt/aluminum-cap-lead/models/ECEA1EN100U),
  [Panasonic FR](https://industrial.panasonic.com/cdbs/www-data/pdf/RDF0000/ABA0000C1259.pdf)
  and the connector geometry against [JST VH](https://www.jst-mfg.com/product/pdf/eng/eVH.pdf).
- **Copper or assembly-label failure:** inspected fresh front/back copper
  plots, not only the populated view. High-current positive paths have the
  documented widths and dedicated layer-transition vias; both faces retain
  broad connected ground copper. USB data remains on the bottom with no data
  vias. The short coil crossing is confined to the relay-terminal region.
  Front reference fill, shield-pad grounding, connector orientation, polarity
  marks and bottom pin labels agree with the wiring contract. Printed text and
  mask clearances pass the native checks. No additional routing change is
  justified by this review.

## Fresh executed evidence

KiCad 10.0.4 and its bundled Python were used with outputs under `/tmp`.
The native `check.py hand --output ...` run was executed without `--self-test`;
the coordinating review owns the fresh full 75-control suite.

| Check | Observed result |
|---|---|
| `check.py hand` | Pass; no source changes during validation |
| Refilled native DRC, all severities and all track errors | 0 errors, 0 warnings, 0 exclusions, 0 unconnected |
| Native ERC | 0 findings |
| Fresh schematic export / netlist / physical-pad parity | Pass |
| Existing native USB ground-reference sampler | 6,264 samples pass |
| Existing model/assembly checks | 50 models; two copper layers; THT checks pass |
| Separate audit of physical pad nets against manual manufacturer contracts | 54 pin/no-connect assertions pass |
| Separate directed native-pad switch graph | 48 relay paths in 24 states; 4 power-direction cases pass |
| Separate exhaustive pair segment-distance calculation | All four pairs: 0.230000 mm minimum copper gap; 0.78 mm track width |
| Separate length calculation | Host halves 23.526702 mm; downstream halves 26.178136 mm; worst skew below 0.000001 mm |
| Fresh top render / F.Cu and B.Cu SVG plots | Generated and visually inspected |

Raw temporary evidence: `/tmp/fresh-screen-review-368b9bd-validation.json`,
`/tmp/fresh-screen-review-368b9bd-independent.json`,
`/tmp/fresh-screen-pad-map.json`,
`/tmp/fresh-screen-review-368b9bd-top.png`, and
`/tmp/fresh-screen-review-368b9bd-svg/`.
These are disposable review outputs, not manufacturing deliverables.
The Python tools emitted KiCad wx initialization/via-width diagnostics but
completed successfully; the parsed native rule reports contain zero findings.

## Limits retained

No assembled screen board was available to this review. The documented
480 Mbps hub path, cable shield/twist/USB-C Rp construction, exact attachment
transients, fuse/buck coordination, shutdown delay, enclosure fit and final
thermal behavior remain assembly qualification matters. The paired-line
calculation is a nominal two-layer target; ordinary fabrication does not
warrant USB impedance. The source explicitly distinguishes these limits from
bare-board readiness. No new owner measurement, pre-PCB prototype, connector
change, layer change or active current limiter is requested by this review.

## Reviewed screen source hashes

The screen files below were unchanged when this report was written. Concurrent
corrections to general console/ring documentation are outside these hashes.

| File under `hardware/kicad/screen_power/` | SHA-256 |
|---|---|
| `circuit.py` | `5fb3b82bc4f65d7a3bd8ed4abbdba5ffd497cf17e5acc1ffc4ae6eb00957083f` |
| `switch_circuit.py` | `652502f1006b5019752c874b08ff431b5e8bc24cea1dcbf52d50cc513fd23a7e` |
| `layout.py` | `a8cd83e901fbb763c6444726edbf2c2843e8eda4d50d9eab9d24146f84117ae7` |
| `route_critical.py` | `e029f27cd59704fa86d86eef495f7ee16d6489ce1911215f8b9bba2cf9f0e7b2` |
| `pcb.py` | `c8f2f0c50dee11ce991e081f552d66bb980ca8d55c423a58b8c20a5535cdcf5f` |
| `finish.py` | `bd04338e036e2b884da255e937ec48afb6f636a4770ffdac64084d4eeeaf12d0` |
| `check.py` | `b68482bb0bd5350531708bda32114d4c0f38c3f8074dbea83a5087ed01a5539d` |
| `hand_checks.py` | `92e6f017791bd62e2accb6adf20ade2c4ad0ea7652942574c6d03fb5ae35e655` |
| `hand/bom.csv` | `11453e0458584697b86bee36f62dde5e376ca67fcdaea2f85060cfc8e52f0cb3` |
| `external_bom.csv` | `0381a3f6d5dd4d14d762caabd7251d0696b5a0df5cd89a2824c3d4469ff9322e` |
| `hand/components.json` | `35e4030e6ad81a77f54dc95381926146003938d9ee6e5f5ad667e099d54ec4ba` |
| `hand/screen_power_hand.kicad_pcb` | `8a467b1c6a881cbf7dd117d38366cfda466f1a51c64553296cc374b4ca52cb27` |
| `hand/screen_power_hand.kicad_pro` | `7c1d7d080c6be1d59b356208051249e8192af8b31a7946a435ef9cd95a7b2727` |
| `hand/screen_power_hand.net` | `03ba4273d19ed28c4ca6791daaccdcdc9ba6653379275ab499924a747203b801` |
| `hand/screen_power_hand.kicad_sch` | `3c76eb50894b0c1abe5efd7475a8eb685b20c05dc0f030ec6ba27dbaca671a38` |
| `README.md` | `94f0279d565ac2b1c15b18b045a978ad97b7467c346a9796150e93f2dee1a23a` |
| `hand/gate_drive.kicad_sch` | `09ffd32dbb69730a21629b7c9ee53ed11545a4eff8c2d40f2ef7d6b92dd3acc0` |
| `hand/screen1_power.kicad_sch` | `8ce5ab106cb392470852029e1f9becc041bac678d48c716aff9caedf1a7e384e` |
| `hand/screen1_touch.kicad_sch` | `f9304b39b547b599c1d28a4e06c3dba8a638b4149c9755d107c6f2f2f191e09e` |
| `hand/screen2_power.kicad_sch` | `ca9821d03acfcda914a5d8a6a6d83c3b8bc19e6629e8c9f8d4afb6b21c6ce175` |
| `hand/screen2_touch.kicad_sch` | `3bfc6b3db74dba9af777a37c9609b1acc93928177c0f95eb5059434f1699e93d` |
| `hand/shared_power.kicad_sch` | `8e77cc5aa213a5a1a3f3fc3cc8d7c813d3ca267db1ecbd221d86a38b2d6a0dad` |
