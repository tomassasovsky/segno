<!-- cspell:words opencode deepseek fanout -->

# All-three-board copper and placement audit

26 September 2026, issue #1072. The owner's scope is a consistent smooth finish
and a placement review of the **console, ring carrier and screen-power board**.
This record separates observed baseline findings from reviewed source and native
changes. All three saved boards and their fresh manufacturing archives now pass
the bounded checks below. **Bare-board CAD and fabrication files are accepted.**
Use the [current archive manifest](manufacturing-zips.json); older ZIPs are
superseded. This does not qualify assembled operation or mark the whole PR
review/CI gates complete.

The later [U1/U2 alignment correction](../screen-u2-alignment-1072/verification.md)
supersedes this checkpoint for the screen board only. The manifest above points
to the aligned screen export and refreshed verification reports; console and
ring artwork are unchanged. The screen hashes and geometry below describe the
prior checkpoint.

## Audited baseline

The starting repository revision was `2b45a6adb804044baebfe6ecb7b225ac98c97ded`.
These hashes identify the inspected inputs, not the eventual release files.

| Board | Native SHA-256 |
| --- | --- |
| Console | `a57759950c14ab9606613dac89d51b9021e7824b80055f0e3daaa5ce571b377b` |
| Ring carrier | `3c92dcfd2ab2644ca74f7d82226db84476becbd7fb897ca701ff593ed604a0f2` |
| Screen power | `94ffa2a0ad3d428451798306c24dc087cbdf3e122cecefa7753c840033321a2b` |

Native sources: [console](../../../hardware/kicad/out_console/segno_console_board.kicad_pcb),
[ring](../../../hardware/kicad/segno_pedal_ring.kicad_pcb) and
[screen](../../../hardware/kicad/screen_power/hand/screen_power_hand.kicad_pcb).
This extends the earlier [Rev L record](../screen-power-rev-l-1072/verification.md);
its completed checks do not certify these later changes.

## Console: real slot and bypass-capacitor placement

The supplied screenshot matches the mirrored B.Cu copper beside **J24 pad 3,
+5V**. Its pad thermal-relief sectors are intentional. The separate pointed
slot outside them is real missing copper:

- The rounded power-bar edge is at x=102.900000 over y=116.750138–117.825138.
- The adjacent 1.7 mm ring-feed track is centered at x=102, so its right edge
  is x=102.850000. The shapes leave a **0.050 mm slot**, about 1.07 mm long.
- The pointed end lies near (102.9000,116.7021). The net connects elsewhere;
  this is a finishing defect, not an observed electrical open.

The baseline ZIP reproduces it: archive SHA-256
`d8cd9fe5bcd4e12487de33c938d0f2e457d4eb807962f5fdc3fff11ee25aaf23`, B.Cu member
`2523044cd03d7b070a5ae2105f181a4c91e7a25690d7616c1f03d5dddb2920b4`.
The loose console Gerbers were older, so they were not used to identify this
defect. The applied correction below preserves the 5 mm two-sided bar,
1.2 mm thermal spokes and 1.7 mm ring feed while closing the slot.

Remaining signal and power bends are mostly angular. Examples include the
[ring supply path](../../../hardware/kicad/console_ring_power.py), with front
bends at (141.8,134) and (146.8,129). These are requested style improvements,
not demonstrated electrical faults. A bounded narrow-gap scan and full copper
review found no second actionable gap. Exact retraced polygon seams, including
the long line at y=154.330472, are zero-area renderer boundaries. Preserve the
useful 0.272 mm front ground corridor; do not raise global fill thickness to
hide local details.

The connector row J23/J6/J25/J9 remains aligned at y=129. No connector or fixed
mount relocation is needed. **C20**, U2's bypass capacitor, is the useful
placement improvement: its existing +3V3 route to U2.6 is 17.536 mm. A proposed
native courtyard center (143.75,79.60), rotation 0, gives pads (142.50,79.60)
and (145.00,79.60), reducing the direct power-pin hop to 4.826 mm. Verified
courtyard gaps are 2.045 mm to U2, 0.510 mm to R4 and 0.500 mm to J22; the
existing 2 mm U2 isolation guard need not change. The applied placement below retains these gaps and verifies the local supply
routes, ground stitch, labels and final clearances.

**Applied console correction and routing finish:** the
[bounded console review](console-review.md) and [geometry record](console-geometry.json)
verify C20's new placement, exact source/native reference and ground-stitch
agreement, and the filled rear join. The slot is fully copper, with 0.220 mm
overlap and a tangent blend whose meaningful polygon chords turn at most
9.561 degrees. The same contour check rejects the earlier 48.125-degree cutoff.
The full 1.7 mm feed is rounded, with its connector anchors and four parallel
power vias unchanged; the unsupported corner exception is removed.

The corrected local Pico supply join and tiny front power jog preserve their
external endpoints and widths. The reviewed general pass then rounds 329
remaining corners. No unresolved routed corner is reported; a second run is
byte-identical. All 91 locked tracks and routes at least 1 mm wide remain
exact, as do footprint/pad/model/via metadata, zone outlines, stack and board
outline. Both actual copper faces were reviewed. The final rounded data route
leaves **0.276252 mm** clearance to the critical power bend, above 0.20 mm.

The imported final console native is
`27e690947142c2a31af171c4e2fc82c74b66183d790098299b0fb33b412b75aa`.
Fresh all-severity DRC reports zero violations and zero unconnected items;
all 11 power fault controls and final source/native parity checks pass. The
placement source's existing 15 negative controls also pass. Manufacturing
exports and whole-PR gates remain separate acceptance evidence.

## Ring: accepted tap style and bulk-capacitor position

The baseline ring passes fresh all-severity DRC with no violations or
unconnected items, and all seven existing full-white power fault controls.
Its 1.5 mm J1.1→J2.1 feed is intact. The owner accepts rounding that main
feed while retaining the previous **two straight vertical 0.65 mm taps with
rounded bases**, one from C5.1 and one from U2.14. The shared rounding pass described below completes the remaining signal/module
bends without changing those power-path constraints.

The baseline +5V_LED paths between C5.1, U2.13/U2.14 and the y=22 rail
enclose approximately **8.912 mm² of bare board**, within x=35.945–38.675
and y=16.750–21.250. This is actual geometry, not a renderer seam, but it
is **not an electrical fault**. Removing this power-copper loop is not a
design objective. The owner's preferred tap arrangement may retain it.
The baseline routed C5.1→U2.14 connection is 7.320 mm; direct pad separation
is 3.698 mm. [TI's buffer guidance](https://www.ti.com/lit/ds/symlink/sn74ahct125.pdf)
supports keeping the bypass connection close to VCC, but does not make the
shorter proposed route a requirement or override the accepted tap style.

**Rejected intermediate topology:** Claude's `908a4801` rounds the 1.5 mm
main rail but also replaces U2's vertical tap with a 4.001 mm C5.1→U2.14
dogleg. The owner rejects that dogleg and requests the two previous straight
taps with their rounded bases. The correction below supersedes this topology
while retaining the rounded main feed.

The rejected intermediate remains recorded for traceability, not acceptance:
native SHA-256
`72634f1c65c3317f17db9aa156034e98746da2b27c03f030663ae211a4ca3cb4`;
[ring power source](../../../hardware/kicad/ring_power.py) SHA-256
`b092c9fe602320b544ed645cc9aae1f0feaa8a1f1ca4702329154e8d53ca9de6`.
Its unchanged footprints/vias/outline/stack, matching 32 critical source
segments and sole C5 fillet, zero/zero DRC and seven passing fault controls
remain valid evidence for that intermediate only. They do not approve its
rejected topology. No manufacturing export was regenerated for it.

**Applied tap restoration:** Claude's `0926032b` supersedes `e436dac5` and was
replayed from the frozen baseline with its two original vertical taps and both
rounded-base overlays. The source now rounds the main feed before inserting
collinear tap landings, preserving each bend's intended radius.
Only the main 1.5 mm rail is regenerated, as 30 chords; all 32 critical source
segments and both fillet outlines match the saved native board. The rejected
dogleg is absent and the original U2.13 feed/enable ties remain. All footprint
blocks, all 21 vias, the outline, stack and ground-zone outlines are unchanged
from the baseline. Fresh all-severity DRC reports zero violations and zero
unconnected items; all seven full-white fault controls pass. Both actual
copper faces were checked, including the restored tap bases. The final J2 bend
uses the intended 1.75 mm centerline radius; it preserves the accepted visual
style and full 1.5 mm conductor width.

- Tap-restoration native SHA-256: `e9410d054bf81afbc50477765aa6b90fd0fda2dc17c5ccf84d0b8cbe5d7ad2b4`
- Ring power source SHA-256: `d2dcb84bc34a77f9ab27c0f2bbbeb939dfa4594ab0f3682557730d3f025c8548`

**Applied remaining route finish:** the independently reviewed
[shared helper](rounding-review.md) rounds 52 additional corners on 27 routed
chains, replacing 79 segments with 495 chords. Forty-nine inside radii are
1 mm, one is 0.5 mm and two small RING_DATA bends are 0.05 mm; integer-unit
radius comparisons preserve those last two valid curves. The next pass makes
no changes and is byte-identical. The refilled final ring board is
`188fd6ee4d395d1152fd5d840536ab0699a499cb50bf74539e2bb27273ddcbf2`.
Fresh native DRC is zero/zero and all seven full-white power fault controls
pass. Fixed component/pad anchors and the accepted two taps remain in place.
C1 is retained as assessed below. Final exported-package acceptance is separate.

**C1 is retained:** the 470 µF, 16 V capacitor with ESR ≤0.15 Ω at (36,62)
supports the module power entry. No concrete electrical defect requiring its
relocation was identified. The external strip's 2.44 A design current uses the
separate 1.5 mm J1.1→J2.1 rail; it does not pass through C1's 0.65 mm branch.
The capacitor's routed connection to J2.1 is about 89.90 mm and to J1.1 about
98.73 mm. Moving it closer would reduce transient connection impedance, an
electrical benefit, but would not increase the steady full-white current rating.
No specified transient bound has been shown violated by its existing position.
[Adafruit's power guidance](https://learn.adafruit.com/adafruit-neopixel-uberguide/powering-neopixels)
supports bulk capacitance at the LED supply input; it does not establish a
board-specific relocation requirement.

The present location serves the 24-LED module alternative. An 8 mm can with an
8.5 mm courtyard cannot fit the direct 4 mm gap between C5 and J1. Other upper
locations compete with fixed module/encoder pins, east-facing XIAO USB access
or connector service space. No superior replacement placement has been verified,
so the redesign retains C1, both module alternatives and all optical/mounting
anchors. This closes the proposed relocation; assembled transient performance
remains within the existing first-assembly qualification boundary.

Preserve fixed optical/module pads, encoder position, outline/snap mounting
and XIAO USB access. Existing resistor alignment and other support-part spacing
do not require a general rearrangement. Both ground pours use solid pad
connections; the screenshot's thermal-relief pad is not from this ring board.
The three ground regions on each face connect through pads/vias and must not
be removed merely because they are separate filled polygons.

The [full-white power budget](../ring40-full-white-1072/verification.md) remains:
one 40-LED strip, or one 24/16-LED module, never multiple alternatives together.
Keep the 1.5 mm strip feed, 0.65 mm module branches, three 0.4 mm ground barrels
at J2 and the 3 A connector/AWG22 supply-return requirement.

## Screen: accepted placement and rounded routes

Claude's C4 correction `d8903850` is the screen board's only placement change. C4's body center moves from
(22.6,7) to **(22.22,7)**, rotation 270°, aligning its negative-rail terminal
with U1 pin 5's column. The reference moves by the same 0.38 mm. Exact source
replay changes only four old NEG_5V segments into three new 0.5 mm segments.

The reviewed result preserves every unrelated track/via and other footprint,
all 40 USB tracks, every zone outline and all non-ground fills. Both ground
faces remain connected; all 5,452 USB ground-reference samples pass. Native
DRC reports **zero violations and zero unconnected items**. Using the maximum
5.5 mm capacitor can and 10.54 mm Q4 body envelope leaves **0.760 mm** body
clearance; actual reference-ink clearance is 0.385 mm.

- C4 checkpoint native SHA-256: `d1f65eacb5d47e4c553b0032f2bc4a9e3f4853bd016f3ce08db4c59300d283f9`
- [Layout source](../../../hardware/kicad/screen_power/layout.py) SHA-256:
  `c2c1d43e06e89f045ac8b217402851c7444d74f43410b65fc17647aa5e6bda50`

Subsequent explicit charge-pump, gate/control and relay routes gained circular
corners, followed by the [reviewed shared helper](rounding-review.md) for the
remaining eligible unlocked traces. The [independent USB review](usb-review.md)
then verifies the mirrored rounded data fanout paths and the local Q2→R6 supply
branch: all 0.85 mm data widths and 0.16 mm minimum pair gaps remain, fanout paths
are shorter, and the final filled ground passes 6,268 reference samples.
The USB bends have actual inside radii of 0.343198–0.575 mm; no blanket 1 mm
radius claim is made.

The final accepted native board is
`c06e6b35438b2fc7208cdc50feeebee92e6c01a56a00dadd280f697d1e49d79b`;
route source SHA-256 is
`cbcc9e5cafb4c0577889beb1bb5d0c70b2fa7555982ee3701b9ff2e8982ee547`.
The [reviewed power widths](../screen-power-rev-l-1072/uniform-power-width.md)
remain 2.0 mm AUX, 2.5 mm source bridge/drain feeder, with the existing
output distribution widths. The all-three final native gates and independent
manufacturing packages remain separate release evidence.

## Independent model review

DeepSeek `opencode-go/deepseek-v4-flash` completed a read-only proposed-layout
review using the supplied ring evidence. The [actual response](deepseek-response.md)
and [checked conclusions](deepseek-adjudication.md) are retained separately.
It usefully identified the C1 tradeoff between output alternatives, preservation
of U2 ties, obsolete fillet cleanup and unchanged current-path constraints.
It did not inspect final revised copper or establish a new verified blocker.

Its unsupported requirements were not adopted: a THT capacitor does not
inherently need another ground via; moving C1 to the upper board cannot retain
its former short physical distance to the lower 24-ring pad; pad-map parity
alone cannot detect unintended physical copper touching an NC pad. Final filled
copper and native clearance/connectivity checks address those geometric risks.

## Completion conditions

Claude authored the placement and explicit route corrections; when its cloud
session became inaccessible, the bounded local rounding/USB corrections were
independently reviewed before application. Final release acceptance requires
all three saved boards and their durable source to agree; preserved pad/net
maps, fixed anchors, component envelopes and module options; a visual check of
both actual copper faces; fresh all-severity DRC with no unconnected items;
and meaningful current-path fault controls that still fail with overlays
present. Generic same-net connectivity must not substitute for required
power widths or return barrels.

Regenerate manufacturing files only after that review. The
[independent console/ring verifier](verify_console_ring.py) checks fresh CLI
exports against both tracked loose CAM and exact ZIP inventories, with source
and artifact hash stability. The screen uses its
[independent package verifier](../screen-power-rev-l-1072/verify_fabrication.py).
The final [console/ring record](console-ring-fabrication-verification.json)
passes **175 assertions** and the [screen record](screen-fabrication-verification.json)
passes **409 assertions**, with unchanged input hashes during verification.
Every ZIP member matches a fresh export under strict timestamp normalization;
the 22 tracked loose console/ring CAM files match as well. Screen ERC is clean,
all three boards have zero DRC violations and unconnected items, and the
[final screen check](screen-native-validation.json) passes all 56 fault controls.
The console and ring power guards reject all 11 and 7 injected faults.

All six native copper faces and populated top/bottom views were inspected.
The [13 rounding fixtures](rounding-review.md) pass, including physical
same-net contacts and track keepouts; the final boards have no remaining
reported exposed route corner. Tight spaces use smaller positive inside
radii. Required pad/via landings, branching contacts and thermal reliefs
remain deliberate geometry, not candidates for indiscriminate smoothing.

DeepSeek's second [source review](rounded-deepseek-response.md) completed on
retry. Its three claims were [checked against source and native copper](rounded-deepseek-adjudication.md);
none established an actionable current defect. The first attempt exhausted
its output budget and is not counted as completed review.

| Accepted board | Native SHA-256 |
| --- | --- |
| Console | `27e690947142c2a31af171c4e2fc82c74b66183d790098299b0fb33b412b75aa` |
| Ring carrier | `188fd6ee4d395d1152fd5d840536ab0699a499cb50bf74539e2bb27273ddcbf2` |
| Screen power | `c06e6b35438b2fc7208cdc50feeebee92e6c01a56a00dadd280f697d1e49d79b` |

These hashes and the linked archive hashes identify the accepted fabrication
checkpoint. No order, firmware flash or deployment was performed. Existing
first-assembly checks remain necessary; native geometry and calculations do
not establish USB compliance or actual thermal/shutdown behavior.

## Assembly-model refresh

Console and ring STEP artifacts were refreshed from the accepted native boards.
The console export completes successfully and includes C20's new position.
The ring exporter writes its file but returns status 2 for four existing
mesh-only trimmed mounting-pin models on the 24-LED module. These same pins
were absent from the preceding STEP and remain visible in native KiCad 3D.
The refreshed and preceding ring STEP each import as 74 valid solids and 1,741
faces, with identical per-solid bounds and volumes. Their overall envelope is
80 × 80 × 34.18 mm. This is an existing STEP representation limit, not missing
manufacturing copper or a newly missing component body.
