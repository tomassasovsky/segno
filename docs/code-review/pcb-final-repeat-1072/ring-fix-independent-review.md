<!-- cspell:words unmanufacturable unswitched -->
# Independent review of the exact ring encoder correction

Completed 2026-09-26 against base HEAD `368b9bd72589e12853ea7d47595351f67c843452` plus the final uncommitted correction whose contents are identified below. Native PCB SHA-256: `e6e1d1bcda4258391ed43a441f9bf8231839abab3b1551660f1b817472f8f62b`. Required runtime: PR #1082 at `dd46ab0d1a44bc55c7f42bc7db7992773c7a4113`.

**Result: complete and clean within the PCB, sourced-part and documented assembly scope.** One independent annulus-calculation finding was repaired during review. The final exact encoder selection, footprint, native copper and assembly instructions agree. No unresolved actionable PCB defect was found. This report supersedes the earlier ring hashes in the independent inter-board review; the refreshed manifests there refer to these final files.

## Resolved finding: asymmetric fabrication tolerance

The first encoder guard used 0.08 mm for both hole undersize and oversize, and claimed at least 0.20 mm concentric annulus for 1.8 mm signal pads around 1.3 mm holes. JLCPCB's published rigid-board PTH tolerance is **+0.13/−0.08 mm**: those pads actually provided 0.185 mm at maximum diameter, so the new guard and claimed bound were incorrect. The same assumption overstated the support-pad annulus. This was a calculation/verification defect; it did not establish that the earlier nominal pad geometry was unmanufacturable. [JLCPCB rigid capabilities](https://jlcpcb.com/capabilities/Capab).

The author split the tolerance constants in `ring_encoder.py` and enlarged the five signal pads to 1.9 mm in both library and native footprint. Final signal/support concentric annulus at maximum hole size is 0.235 mm; nominal annulus is 0.30 mm. The guide now explicitly distinguishes this size calculation from the separately specified hole-position tolerance. It no longer presents a concentric calculation as an unconditional finished-board minimum. No extra routing change was needed. The final bounded follow-up clarified mutation labels and the nominal-hole table heading, and tightened the calculated concentric-annulus guard to 0.23 mm, rounded down from the actual 0.235 mm geometry. Its baseline passed again; native geometry and model hashes did not change.

## Manufacturer drawing, electrical use and hand assembly

I visually read the actual ACZ11 revision 1.08 drawing, especially the **vertical switched** top-view layout, rather than substituting the horizontal or unswitched option. Exact part `ACZ11BR1E-20FD1-20C` supplies a momentary switch, vertical contacts, M7×0.75 H5 bushing, 20 mm D shaft and 20 pulses/20 detents. Its allowed hand-soldering condition is 350 °C maximum for at most 3 seconds. Operating range ends at 65 °C; this is compatible with the review's conditional 60 °C ambient allocation, not an 85 °C system claim. No minimum wetting current is specified. The design retains its 3.3 V/10 kΩ pull-ups and 100 nF filters; it does not claim to duplicate the manufacturer's optional two-resistor filter. [Same Sky ACZ11 datasheet](https://www.sameskydevices.com/product/resource/acz11.pdf).

The separately specified nut is `SJ5-43502PM-nut`. Its official drawing gives M7×0.75, 2.0±0.1 mm thickness and 10.0±0.1 mm across flats. This is now a real BOM line, with a direct disc clamp and **no washer**. [Same Sky nut drawing](https://www.sameskydevices.com/product/resource/sj5-43502pm-nut.pdf).

## Independent native and library checks

I loaded the final KiCad board and library footprint independently of the author's assertions, checked coordinates/attributes/holes/net roles, and compared every numbered native pad with the saved netlist:

| Native result | Evidence |
| --- | --- |
| Fixed shaft centre | (35.9825, 35.7675) mm; front side, zero rotation |
| A/C/B row | X=−2.5/0/+2.5, Y=+7.5 mm; ENC_A/GND/ENC_B |
| D/E switch row, named S1/S2 | X=−2.5/+2.5, Y=−7.0 mm; ENC_SW/GND |
| Mechanical tab centres | X=−4.7/+4.7, Y=0; 9.4 mm pitch; no electrical net |
| Signal pads/drills | 1.9/1.3 mm; minimum finished hole 1.22 mm |
| Support pads/drills | 3.6/3.0 mm; minimum finished hole 2.92 mm |
| Recommended support opening containment | diagonal of 1.8×2.1 mm rectangle = 2.765863 mm, below 2.92 mm |
| Concentric annulus at maximum finished hole | 0.235 mm for both pad types |
| Native/saved net consistency | All 73 numbered pad instances agree; exact ENC1 value/footprint agree |

The final native board contains 564 track/via objects. Comparing their UUIDs, net, layer, width and coordinates against the original board identified exactly five changed segments: two each on ENC_A and ENC_B, and one on ENC_SW. Only the pad-end X coordinates changed, each by 0.04 mm. All 21 vias and every power segment remain unchanged. Board settings, layer definition and circular outline also agree exactly.

Seventeen other footprint S-expressions are unchanged. `RING1` separately hides all ten retained alternative ring/support-pin models and updates its description for the selected external 40-pixel assembly. These are model-display changes, not populated components in this assembly. The exact encoder replaces the obsolete generic footprint/model; the selected design remains two copper layers, THT discrete parts and the previously accepted castellated module.

## Body, model and mounting stack

Using the drawing's maximum body width (12.2 mm) and its two half-length tolerances gives a conservative encoder body box X=29.8825…42.0825, Y=28.2175…42.5675 mm. It has **3.3175 mm** clearance to the nearest front J2 footprint bounding box. Its maximum corner radius is 9.7063 mm, leaving over 6.14 mm to the smaller alternative module's 15.85 mm bore and over 16.44 mm to the larger module's 26.15 mm bore. Back-side parts are independently separated in the native layout; DRC also checks the enlarged plated pads against their tracks and fills.

I imported the actual STEP file and read its ten solid bounding boxes. The body is nominal 11.7×13.75 mm, its shaft/bushing start at Z=6.5 mm, bushing ends at 11.5 mm and shaft at 26.5 mm, with tails to −4 mm. Terminal centres match the footprint after KiCad's model-Y inversion. The model is accurately labelled a drawing-derived nominal envelope: illustrative tail thicknesses, omitted thread detail and overlapping constituent solids are not manufacturer CAD or tolerance evidence. The maximum-body checks above therefore use the drawing independently. The 3D review showed accessible THT assembly and no conflicting front-body placement; alternatives are hidden in the final selected-assembly export.

The enclosure source retains its 2.0 mm disc, 7.2 mm M7 clearance hole and 6.0 mm knob bore. A 2.1 mm maximum allocated disc plus 2.1 mm maximum nut totals 4.2 mm, below the 4.7 mm minimum bushing length, leaving 0.5 mm. Nut maximum corner diameter is 11.6625 mm, within the model's 22 mm relief. The documented 20 mm shaft and assumed 12 mm blind bore permit the knob to stand above the disc: even 19.5−12−2.1 = 5.4 mm remains before the nominal knob underside reaches it. The guide reserves the 0.8 mm maximum switch travel plus clearance. The existing bought knob's blind-bore/relief dimensions remain explicitly assumed; neither this review nor the simplified STEP converts them into measured dimensions. No new owner measurement or pre-PCB prototype is required for this PCB correction.

## Runtime contract and executed evidence

The drawing's 20C detent position is contacts-open. With pull-ups and A as the high bit, clockwise is `11 → 01 → 00 → 10 → 11`. I inspected the pinned runtime: D1/D2/D3 match A/B/switch, the detent state is 3, and its transition table sums to +4 for that sequence and −4 in reverse, producing +1/−1 clicks. Runtime bounce/direction execution is independently reviewed in the separate firmware work; no hardware-pin reversal is used to conceal a software sign error.

Executed independently on the **final native hash**: manufacturer/library/native coordinate and drill comparison; 73-pad netlist comparison; track/footprint/settings/outline comparison; actual STEP import; native `kicad-cli pcb drc` (**0 violations, 0 unconnected**); and the final `ring_encoder.py` baseline (**PASS**). The author separately ran eight encoder fault controls and the ring-power controls. The root's final fabrication verification reports 175 passes. These are distinguished from this reviewer's read-only executions; no production files or Git state were mutated by this reviewer.

## Exact reviewed contents

SHA-256:

| Path | SHA-256 |
| --- | --- |
| `hardware/kicad/ring_board.py` | `80760bad9e564e5f254c0695840427f83519be74800911b5636a3055cd4d2f6b` |
| `hardware/kicad/ring_board.net` | `0230258a5c541f01c334d1c6012647dc55914e21926a55e96929acf10c063f88` |
| `hardware/kicad/ring_encoder.py` | `a4d3aa686fd15bf2cf492d1f843e860156913eb674018f01b730e76ed3c71cb2` |
| `hardware/kicad/ring_encoder_model.py` | `6f2524696720762946491f8cd5434f5dae026dfa96cb7ea03cc936e24684061e` |
| `hardware/kicad/segno.pretty/RotaryEncoder_SameSky_ACZ11BR1E-20FD1-20C.kicad_mod` | `d7a8f08e9ccbff5734c54407f2b0748c386ee8144b3dec9925b74416a70634f5` |
| `hardware/kicad/segno.pretty/RotaryEncoder_SameSky_ACZ11BR1E-20FD1-20C.step` | `5667ba66540f7c1ec4d935719788580d6cb87c73a0f58382bacba0e4330eb3e1` |
| `hardware/kicad/segno_pedal_ring.kicad_pcb` | `e6e1d1bcda4258391ed43a441f9bf8231839abab3b1551660f1b817472f8f62b` |
| `hardware/kicad/RING_ENCODER.md` | `51fcaa60b386fb84fb1f306e9fb48227368c58710bf5861e74bbbf9a37ab441d` |
| `hardware/kicad/RING_ASSEMBLY.md` | `956108399134a0c19f3340f38c69f9194c76dc1fc8fca37e6a3fdd6750e2de2f` |
| `hardware/kicad/fab/segno_combined_bom_lcsc.csv` | `a9d470f62531d340970e17baa51b735831d7cf414dc6a7b2130ca9a93e9a54f9` |
| `hardware/kicad/route_ring_board.sh` | `50cd9ec95bfad605ff082c06b27ca90fb83e76abe5defaee77d9c92e8650cdf6` |
| `hardware/kicad/fp-lib-table` | `222a3e8634b40e312fe6cf8d741f12244c61980d08db9f92b4e5751c6e63015a` |
| `hardware/segno_wiring.md` | `40377cc388d9ee909f28458f334bb8eb63bea2ca8e25f54e06f6fd43e1429cbb` |
| `hardware/enclosure/segno_enclosure.py` | `17f7089fc63d8a0b3675c6d2d658d022868294bfb0801d8461719861f776a014` |

Pinned runtime `firmware/ring_board/ring_board.ino` SHA-256: `1618a0e2b65d9ad0f21ee10a36a85572f66e901791f42fa215094a48da20e591`.

Primary ACZ11 PDF SHA-256: `a1d5e9764abdf31c5da469bc044ad1ea916185cd0b6459b692f1e1aa52396996`.
Primary nut PDF SHA-256: `b62ee7bc1be6ded435ecf0a3f9f49bf04eb17bd45ed2b7a5819712e862ea0fa8`.
