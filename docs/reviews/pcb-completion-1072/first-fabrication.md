<!-- cspell:words MOSFET MOSFETs SUP Rds onsemi milliohm kilohms kilohm unassembled -->
# First-fabrication decision — 24 September 2026

**September 25 update:** the console and ring archives below are superseded by
the [40-pixel full-white revision](../ring40-full-white-1072/verification.md).
Use that revision's hashes and exports for a new order. The screen archive and
the decision to proceed without further pre-order measurements remain unchanged.

No pre-order voltage measurement is required from the owner. The earlier
blanket requirement for cable, current, temperature and shutdown measurements
before ordering bare PCBs was excessive. These boards are a first build;
fabrication readiness and validation of the assembled system are separate.

## Supply-margin review

The current automated calculation uses 5.0 V at J1. That is an assumption,
not a measured or specified lower bound of the existing buck and wiring.
Reusing its assumptions at 4.75 V input gives:

`|VGS| = (4.75 - 6 × 0.015 × 1.7 - 0.2) × 326700 / 331447 = 4.334 V`.

The 1.7 hot-resistance factor is an estimate. The resulting drive is below the
SUP70101EL's −4.5 V resistance test condition, so the guaranteed 15 milliohm
figure cannot be claimed there. It is not a turn-on boundary. The manufacturer's
typical resistance curves remain low near 4.3 V gate drive; they do not predict
a switching failure at 4.75 V input. Those curves support an engineering
assessment, not a guaranteed process or temperature limit.
[Vishay SUP70101EL, electrical table and typical curves](https://www.vishay.com/docs/77632/sup70101el.pdf).

Q1 also has ample base drive: the existing conservative GPIO calculation gives
about 1.43 mA, while its steady collector demand is below 1 mA. The 0.2 V
collector-drop allowance is conservative relative to its specified test at
10 mA collector current and 1 mA base current.
[onsemi 2N3904 specification](https://www.onsemi.com/download/data-sheet/pdf/2n3904-d.pdf).

For loss budgeting, 30 milliohms per power MOSFET is an engineering allowance,
not a new manufacturer guarantee. It corresponds to 0.36 V drop and 2.16 W
across the pair at 6 A, or 0.18 V and 0.54 W at 3 A. Cable, connector, fuse and
copper losses are additional. This does not establish the lowest voltage at
which either screen operates, the buck's transient response or enclosure
temperature. The 4.75 V case is a design sensitivity check, not a claim about
the buck's guaranteed output tolerance.

Keep the existing circuit for first fabrication. Reducing R3 from 4.7 kilohms
to 1 kilohm would gain only about 49 mV at this corner and change switching
speed; it does not justify a revision. A single multimeter reading would not
establish worst-case supply behavior either. No layout change or mandatory
owner measurement follows from this gate-drive concern.

## Practical decision

The existing console and screen-board CAD checks pass. The reviewed evidence
supports first fabrication without the previously requested bench programme.
It does not promise that an unassembled first build has no remaining hardware
issues. No order has been placed and no PCB, schematic, BOM or Gerber changed
as part of this clarification.

Cable polarity must be checked before applying power; pin order can be
corrected by repinning. Functional USB, heating, startup and screen cutoff
checks belong to first assembly. The software shutdown delay remains
adjustable. The owner's HDMI-only darkness check has already passed.
Issue #1072 remains `autonomy:blocked-verify` for hardware validation and merge;
that label is not a prerequisite to buying the hardware needed for validation.

This decision supersedes the pre-order measurement requirements in the older
September 22 reports and exported READMEs. Their measurements and simulations
remain evidence with their original stated limitations.

## Verified order files

The two fabrication ZIPs were checked again on September 24: 65 recorded source
files and 111 packaged artifacts match their manifests, and every ZIP member
matches its corresponding reviewed Gerber or drill file. Both boards retain
zero recorded DRC violations and zero unconnected items. The source and board
hashes are unchanged, so no CAD regeneration was necessary.

| Upload name | SHA256 |
| --- | --- |
| `segno-console-v3-gerbers.zip` | `93dc849e1950138fa5018f3916ef894e0d452159b3ce3764b68acfbc2437485e` |
| `segno-screen-power-rev-i-gerbers.zip` | `25370578cbb1184f6d2bc1913c88746ff87ce91809779c7878d62f4af735a878` |

These are byte-identical copies of the reviewed ZIPs, renamed for the order.
Both use two-layer FR4, 1.6 mm, 1 oz, purple mask and white silkscreen. Select
ENIG for the screen board as its export specifies; lead-free HASL is suitable
for the console, whose native finish is unspecified. The order contains five
individual PCBs of each design, with no stencil or factory assembly. Separate
order instructions and a verification record accompany the upload files.

The ring is now included as a third order, following the owner's white-mask
request and a separate [ring fabrication review](../ring-order-ready-1072/verification.md).
Use `segno-ring-white-gerbers.zip`, SHA256
`e79e97d122088814b1ee34b1e33ecbe281fb9ee7a6f27c9b05a437ad16fccc74`.
It is an 80 mm circular, two-layer board with white mask, black silk and
lead-free HASL. The first two boards retain their earlier upload hashes.
