<!-- cspell:words ECEA optocoupler kicad -->
# Revision L final layout review

**Historical checkpoint — superseded artwork.** The [all-three-board audit](../pcb-finish-all-three-1072/audit.md) and its [archive manifest](../pcb-finish-all-three-1072/manufacturing-zips.json) identify the current rounded boards and exports. The hashes and fabrication counts below describe the earlier checkpoint only. Circuit and power calculations remain applicable where their geometry and components are unchanged.

Reviewed 2026-09-25 against the published Revision K base `7dcdc944`.
The final layout includes Claude's corrections through `e9fab839` and the
subsequent comment-only source corrections.
No unresolved layout, assembly-clearance or generator findings remain in
the inspected Revision L files below.

## Evidence

- KiCad 10.0.4 rebuilt the board and exported its package. Native ERC and DRC
  report zero errors, warnings, exclusions and unconnected items. All 52
  self-test results pass. The added gate-drive sheet appears in the native
  schematic hierarchy and portable package.
- The board retains two copper layers, a 68 × 76 mm outline with 3 mm corner
  radii, purple solder mask, 44 populated through-hole components and four
  mounting holes. Final exported top, bottom and perspective renders were
  inspected; all populated parts are visible. The final populated STEP opens
  as a valid compound with 124 solids and a 68 × 76 mm overall XY envelope.
- U1's maximum 10.16 × 6.60 mm body and U2's maximum 4.83 × 6.65 mm body fit
  their courtyards without neighboring-body collisions. C3/C4 fit with their
  maximum 5.5 mm diameter and 12.0 mm height. DIP orientation, pin centers,
  model placement and the bipolar capacitors' unmarked polarity are correct.
  The 0.90 mm DIP drills leave a minimum 0.82 mm finished hole and accommodate
  U2's maximum 0.695 mm lead diagonal. Manufacturer dimensions and model
  limitations are recorded in the [model notes](../../../hardware/kicad/screen_power/models/README.md).
- The connector anchors and retaining-wall directions are unchanged. The
  [JST XH drawing](https://www.jst-mfg.com/product/pdf/eng/eXH.pdf) confirms that
  the mating housings fit within the reviewed header envelopes. Relocated Q1
  does not block the adjacent top-entry connector or access from the left
  edge. The new parts do not enter the previously checked VH/C1/C2 mating
  region or increase the tallest-component envelope.
- Actual KiCad stroke polygons were checked for all 84 silkscreen text
  objects. The nearest ink is 5.113 mm from a mounting-hole center, clearing
  both a centered 7 mm washer and the 4.25 mm reserved radius. The revision
  and control labels now clear the fasteners; inspected reference labels
  remain outside component bodies.
- The negative-supply route passes below the optocoupler collector, resolving
  the former crossing. `CONTROL_SINK` uses bottom copper outside the USB
  lanes; the low-current AUX buffer branch uses the front. Its final 45°
  segment runs from (13, 27.5) to (12, 28.5) mm, replacing the square elbow.
  Both branches connect completely. The wider screen-current paths remain
  separate from these control-supply branches.
- The Q4.3-to-Q3.3 bridge and rear Q4.2-to-F101.1 feed now use a uniform
  2.5 mm width, with no narrow necks or taper zones. Their bends
  retain a nominal 1.25 mm inner radius. The nearest neighboring pad copper
  clears by 0.3375 mm against the 0.2 mm rule. The 3 mm fuse branches and
  2 mm main-output branches also have curved bends. All 178 broad critical
  segments match the placed source exactly after routing and cleanup;
  circular chords preserve the curves through the DSN/SES exchange.
- With every zone and via removed from independent in-memory copies, the
  shared paths remain connected at 2.5 mm, fuse distribution at 3 mm and
  main outputs at 2 mm. The right-edge spine remains 4.5 mm wide. Its six
  inside branch joins and outer corners are rounded in the actual filled
  copper. Its lower edge clears H4's 4.25 mm reserved radius by 1.00 mm;
  the refilled front ground corridor at `x=64` spans 0.7945 mm.
- The three 0.45 mm drilled supply-transition vias moved to
  `(46.4, 22.7)`, `(47.5, 23.0)` and `(48.35, 23.6)` mm. Their complete
  0.9 mm copper disks fit inside both faces' routed copper, with at least
  0.20 mm remaining copper beyond each disk. The nearest fuse-hole edge
  clears by 0.441 mm. The rear feed now removes the former ground tips
  without a rear cutback; the rounded front Q3 cutback remains local.
  Each final ground fill is one connected polygon.
- All 40 USB copper segments match Revision K exactly in position, layer
  and width. Each upstream conductor is 23.357803 mm and each downstream
  conductor is 26.351514 mm, with zero computed pair skew. The final filled
  ground-reference check passes 5,452 samples at 0.1 mm spacing, including
  trace centers and edges, outside the documented 1.35 mm terminal exclusion.

These are CAD, assembly-envelope and generation checks. Actual assembled
operation remains distinct from this review; electrical limits are addressed
by the [gate-drive assessment](gate-drive.md) and [startup assessment](startup.md).
This geometry review does not replace final manufacturing-package parity.

## Inspected file hashes

Paths below are relative to `hardware/kicad/screen_power/`. Hashes are SHA-256.

| File | Hash |
| --- | --- |
| `hand/screen_power_hand.kicad_pcb` | `d3577772b4945f93652789e109fd232b479cfc8d119dcb67e499da51d39fa5cf` |
| `layout.py` | `90f48b1cd5cdee6393b62bbcb6edc2a3ca05898c43d5051277d9b73805bcb85f` |
| `route_critical.py` | `2b8e10a22ccf56d9ef0d2ca19c3c3e8197fb65349fec09f1a041ad21d299f651` |
| `schematic.py` | `b80c9a1337f9c5549e397a56400716b9a5c7284007eaae73ae91bd1e3b907fcf` |
| `finish.py` | `f230664f50047ed983798e4c5d2056457f55775f45311b6daea5dc6aaf7f786e` |
| `pcb.py` | `7d50aacdb44947ba1fc7beb3006c4c8eee2b8cc140dfdc713899f5b6a7d46d9a` |
| `model_geometry.py` | `37b7e49ece74315e77e22654cca75c0bf3113b33001c297ee5f2679da280b288` |
| `models/DIP-4_W7.62mm.step` | `39490b2c17b5f36ae3fdd5fdd2952f6879a060ff6cbc6d0241e3d6262fd0f215` |
| `models/DIP-8_W7.62mm.step` | `4a377a56a8d9e9c0b86c095ef9ecc1869ac19e7f5069a3247b294250bf4f235d` |
| `models/Panasonic_ECEA1EN100U.step` | `a9118f23639820ef24ddecc1867e0263a3505276e58d869e6209c0b4fdaa8a45` |
