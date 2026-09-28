<!-- cspell:words SUP SUM Rds KiCad SKiDL Freerouting GPIO VBUS THT SMD NPTH PTH MOSFET pulldown pulldowns Littelfuse Gerber annulus SLLA -->

# Revision B prototype CAD readiness review

Date: 2026-09-22. Final independent native check: 03:33:13 UTC.
Scope: compact hand and factory screen-power boards, their physical layout,
assembly contract, native checks, documentation and prototype export packages.

## Verdict and independence

No unresolved Critical, Important or Suggestion finding remains in this
prototype CAD scope. Two concrete findings raised during this review were
corrected and independently rechecked below. The reviewed deliverables are
ready for a controlled prototype build; this is not production certification,
component purchasing authority, remote CI evidence or a current-head merge gate.
Issue #1072 remains blocked on physical verification.

The reviewer did not author the revision B power circuit or compact layout.
The inherited schematic renderer, RF relay footprint/symbol and earlier
multi-process checker orchestration include this reviewer's prior work. This
report does not independently approve those inherited implementations. It
reviews the new layout and package changes, actual physical artifacts, native
parity results and final assembly output. Manufacturer and circuit reviews of
the inherited relay are separate evidence.

## Findings resolved

### Shared factory source-link width

The factory board originally carried its entire common-source link through
25.7585 mm of 1.5 mm copper, although the guide described that width as short
pin necks. The final source and routed board use 3.0 mm throughout that link.
The checker now requires a continuous 3 mm factory source-to-source path.
An independent fault probe reduced it back to 1.5 mm on a temporary board;
the checker rejected that exact regression with its power-copper finding.
The hand board retains short 1.5 mm device-pin connections and a 3 mm middle
link. This width check does not establish a thermal current rating.

### Hand power-device lead clearance

The standard TO-220 footprint's 1.1 mm holes did not accommodate the selected
SUP70101EL drawing's maximum 1.01 by 0.61 mm rectangular lead envelope, whose
diagonal is approximately 1.180 mm. The design now names a dedicated local
footprint and gives all six Q3/Q4 leads 1.4 mm holes. Pads remain 1.905 by
2.0 mm, retaining a minimum nominal 0.2525 mm annulus. This was checked in the
actual board and the final Excellon file, which contains exactly six 1.4 mm
holes at the Q3/Q4 pad coordinates. The source footprint, netlist and native
schematic agree, and the persistent hand test rejects reduced power-device
holes. Package dimensions: [Vishay SUP70101EL, page 7](https://www.vishay.com/docs/77632/sup70101el.pdf).

## Actual layout and assembly

| Check | Hand | Factory |
| --- | --- | --- |
| Board rectangle | 72 by 84 mm | 72 by 74 mm |
| Footprints, including mounting holes | 41 | 41 |
| Plated through-hole pads | 120 | 74 |
| SMD pads | 0 | 56 |
| Non-plated mounting pads | 4 | 4 |
| Data vias | 0 | 0 |
| Signal/power tracks on inner layers | 0 | 0 |

Each board has four 3.2 mm mounting holes, 4 mm from the corners. Host USB-B
connectors face left, touch USB-A connectors face right, one relay lies in each
channel, power switching occupies the top and control occupies the space
between channels. Connector pin maps, fuse branch ordering and the two-wire
GPIO/ground interface agree across the circuit records and actual pads. No
external electronic module or surface-mount user assembly remains in hand.

Both USB channels use 0.26 mm bottom copper, approximately 0.16 mm coupled gaps
outside necessary pad transitions, and less than 0.696 mm external pair skew.
The paired routing is explicit rather than left to the general router. The
bottom-layer connections at through-hole USB connectors follow
[TI SLLA414A, connector guidance](https://www.ti.com/lit/an/slla414/slla414.pdf).

An independent 0.1 mm-step sample of the filled inner ground plane beneath
all USB tracks found no extended missing return plane. Samples outside ground
copper were confined within 0.972 mm of pads, consistent with local pad
clearances. This is a geometry check, not impedance or USB compliance proof.

Actual power geometry retains 3/4.5 mm shared paths, 2 mm main output branches
and 0.8 mm touch branches, with short hand device-pin necks as described above.
The native checker removes undersized tracks and signal vias on temporary
copies before requiring real copper connectivity; matching net names alone do
not pass this test. No thin control branch is credited as the sole high-current
path.

The selected power devices specify 15 milliohms maximum resistance at minus
4.5 V gate drive and 25 degrees C. The guide correctly treats the resulting
1.08 W pair loss at 6 A and hot-resistance estimate as a provisional design
calculation, with actual voltage drop, heating and inrush still to be measured.
[Vishay SUP70101EL](https://www.vishay.com/docs/77632/sup70101el.pdf),
[Vishay SUM70101EL](https://www.vishay.com/docs/77605/sum70101el.pdf).

The local fuse pattern matches the selected 251 series' 7.11 mm body length,
2.80 mm body diameter and 0.64 mm leads. The guide specifies the separate fuse
insertion/soldering step and its 350 plus or minus 5 degrees C, 5-second limit;
it does not place those axial fuses through reflow.
[Littelfuse 251 data sheet](https://www.littelfuse.com/assetdocs/fuse-251-datasheet?assetguid=f47a0bb7-8ede-4679-9646-7114c3787688).

Partial native top renders and both final printable assembly PDFs were
visually inspected. The final drawings are scaled to the page in black and
white, retain populated-component references, body outlines, polarity and numbered
pads, and avoid the earlier duplicate reference clutter. Missing STEP models
are explicitly documented; neither empty render space nor a passing courtyard
check substitutes for real cable, latch, live-tab or enclosure clearance.

## Verification and publication

The final independent combined native run passes both variants with zero ERC
or DRC errors, warnings, exclusions and unconnected items under the configured
KiCad rules. It confirms native schematic/netlist/component/pad parity, actual
USB and console control continuity, circuit boundaries, assembly types and
drive assumptions. All 11 hand and 8 factory negative controls are detected.
The reports retain the native list of ignored rule categories; zero findings
does not mean every optional KiCad rule is enabled.

All recorded input hashes from that independent run match the final reviewed
files. Each completed fabrication package contains 28 manifested files. Every
file hash, source hash and board hash matches. Both 15-entry Gerber/drill ZIPs
pass integrity checks and match their loose files byte for byte. Assembly
rendering uses a disposable drawing copy, leaving manufacturing board input
unchanged.

All 13 current Python sources parse, the build shell script passes syntax
checking, and the scoped text-source Git whitespace check is clean. No
hardware Python linter or coverage threshold is configured. The README, plan
and progress documentation pass the configured spell check. No temporary
skip, unresolved conflict or debug-only application behavior was found in this
hardware scope. CAD, drawings and manufacturing exports are intentional
repository artifacts; the generic rule against committing generated app
outputs does not apply to them.

## Remaining physical gates

The assembly guide and plan consistently retain the unresolved work: exact
existing power-harness connectors and USB-C signaling, actual touch operation
through relays, USB suspend/wake, inrush and fuse coordination, voltage drop,
heat, live-tab insulation, impedance approval, enclosure fit and residual HDMI
power. The board blocks reverse flow only while disabled. It does not provide
active current limiting, an ideal-diode function or controlled soft start.

GPIO shutdown before HDMI teardown is still a device integration step. The
PCB alone does not prove removal of the visible blue no-signal frame. These
are explicit limits of the prototype deliverable, not newly discovered
readiness findings or claimed successful hardware tests.

## Reviewed source and artifact hashes

| Repository-relative input | SHA-256 |
| --- | --- |
| `hardware/kicad/screen_power/README.md` | `8a622d9d2ba7f642987c1d8799c372470baa314018f8a00da6bd244e5c0b0f92` |
| `hardware/kicad/screen_power/switch_circuit.py` | `d7a3ffd3175b880374513e974c96228c374434f0db1708cdefd801135f553c25` |
| `hardware/kicad/screen_power/circuit.py` | `ce15ced01c26339f13e00f35b7a2e6d99158e33707b51cf0f906c090e423797a` |
| `hardware/kicad/screen_power/layout.py` | `deeea167e469d4f115febf98ba91a6ada9f5cded22ce1c2fd743111b351cf739` |
| `hardware/kicad/screen_power/pcb.py` | `427899731ebce81782cf95813610851be82b421f678faa359321d007c8e1d8fe` |
| `hardware/kicad/screen_power/route_critical.py` | `6da8c96d3d45c2637012de054dc2a2bf883022598750d25170bc1aecc4b8a0ae` |
| `hardware/kicad/screen_power/check.py` | `4b9d51f2978657461c0abcf572f5efa6c861dcb1ed5dd8f13e4d320790a7e45c` |
| `hardware/kicad/screen_power/hand_checks.py` | `f1810c3da62e948f0f1ca864936593218fe55c0b9fd2baa43782ddadf44db0ec` |
| `hardware/kicad/screen_power/cleanup.py` | `250a4ca530796cded61d5d1b660b5d01d1ceff215e0ff44b1265c5a3e19ad93b` |
| `hardware/kicad/screen_power/export.py` | `4e753f3a70e00116eedc175abaf1278fe7b14495cf0386816d9c317502e11979` |
| `hardware/kicad/screen_power/schematic.py` | `8853327a52cef163ef5829f327ae6583877ae2fa2ff9cf598fad55d80865a307` |
| `hardware/kicad/screen_power/screen_power.pretty/TO-220-3_SUP70101EL.kicad_mod` | `0566209e224dbf3c4e85ce20f55fe952db20cb2f4fd765e34b3a8854375b9cd0` |
| `hardware/kicad/screen_power/screen_power.pretty/Fuse_Littelfuse_251_P12.70mm.kicad_mod` | `78dc85457dff9dd66e543e545d7033531b9d0de4fea476e633baea202a66aa3d` |
| `hardware/kicad/screen_power/hand/screen_power_hand.kicad_pcb` | `c061ea06f6c050f495df81d6b3aff7bd6acb7a920c102c1312c803920897831d` |
| `hardware/kicad/screen_power/factory/screen_power_factory.kicad_pcb` | `8f1bafef2a51b4fa090e2bb35ce266e421ed2f82aae7d9d2274d8e332bd01b8f` |
| `hardware/kicad/screen_power/hand/screen_power_hand.net` | `fb783127b1c29993253542482f56e3d897cca6232ac9ee9b4e7944c3b4e535af` |
| `hardware/kicad/screen_power/factory/screen_power_factory.net` | `8cc025b0c17d9a56e3614432844d6130caa5dcabad315b6cd3765830c2f76758` |
| `hardware/kicad/screen_power/hand/fabrication/manifest.json` | `f58df4bbf0f87fa490152932aed0f2a08c448c492065a867586252f7e6546026` |
| `hardware/kicad/screen_power/factory/fabrication/manifest.json` | `aee5bce2411f837f7e50df5394e1016b24fba434a657cc75d1eba67bbd290f5a` |
