## Architecture Review

Review date: 2026-09-15. Scope: issue #1037's solid CLEAR/BANK collar port
against the saved pre-port baseline, including generator geometry, assembly
access and documentation. This is a Python/CadQuery manufacturing change;
Flutter, Bloc and FFI architecture rules do not apply. Earlier sheet-metal
changes in the working tree are outside this delta.

### Layer Separation

- Violations found: 0.
- The generator remains the authority for the printed collar. It replaces
  the modeled underside cavity and its insert columns with solid material,
  retaining four explicit driver passages. Slicer infill remains a print
  setting rather than a second CAD geometry mode.
- CAD generation, native Fusion synchronization and package production retain
  their existing responsibilities. The change introduces no Fusion APIs,
  supplier state or packaging logic into `_platform_printed`.
- The obsolete `PLAT_WALL` parameter is removed; `PLAT_TOOL_D` describes the
  required physical access opening. There is no compatibility branch for the
  old cavity.
- Clean files: the generator delta, mid-platform mounting regression and
  updated manufacturing/design instructions reviewed for this port.

### State Management Assessment

- `_platform_printed`: appropriate deterministic construction. The mid collar
  keeps its existing outer envelope, sled seating plane, upper walls and cable
  opening. The new voids are on the existing four deck-screw axes.
- Assembly sequence: consistent with the geometry. Assemble the sled and
  collar on the bench using a long driver with the screw retained on its tip,
  then attach the complete module to the metal base. The base necessarily
  covers the access openings once installed; servicing requires module removal.
- Printing instructions distinguish a solid CAD volume from solid infill.
  The updated guide defers filament consumption to the slicer instead of
  inferring finished print mass from CAD volume alone.

### Dependency Direction

- Direction violations: 0.
- No added imports, dependencies, classes or alternate generation path.
- An AST comparison against the saved baseline identifies only
  `_platform_printed` as a changed function. Metal geometry builders,
  placement helpers, sled builders and package assembly definitions remain
  unchanged in this delta.
- At this review snapshot, the base and faceplate native STEP files, native
  flat files and formed manifest are byte-identical to the pre-port baseline.
  The printed change does not require editing or requalifying their geometry.

### Package Structure

- Existing enclosure module and mounting regression module are sufficient;
  no new abstraction or package is needed.
- Independently ran all seven `tests.test_mid_platform_mount` tests: passed.
  They exercise exported solids, blind insert pockets, screw/head/driver
  clearance, deck bearing material, sled insertion/removal and the assembly
  builder's front/mid variant placement.

### Independent Geometry Evidence

- The mid collar is one valid solid. Its modeled volume increases from
  165908.178173 to 420870.396409 mm³.
- Valid bidirectional Boolean comparisons show no removed material and
  254962.218236 mm³ of added material. All added material lies within the
  former underside cavity, from Z0 to the unchanged deck underside at
  Z30.345008866 mm. The original eight-millimetre deck starts there.
- The outer bounds remain exactly equal: X ±59.235 mm, Y ±44.375 mm,
  Z0 to 74.345022896 mm. Consequently the changed material does not move
  the upper seating surface, cable opening or lid interface.
- Four Ø12 mm passages open from the floor to Z30.345008866 mm at
  X ±30 mm, Y ±18 mm. They provide 2 mm nominal radial clearance for the
  qualified Ø8 mm straight driver and 3 mm for the Ø6 mm screw head.
  The Ø3.7 mm deck holes and their full eight-millimetre bearing thickness
  remain unchanged.
- Bottom insert pilots remain Ø4.5 ×6 mm at X ±48.685 mm,
  Y ±22.1875 mm. Deck and pedal mounting axes are unchanged. The insert
  support annuli and blind roofs pass the existing solid-containment checks.
- The front collar, both console sled variants and the mini-console tub are
  Boolean-identical to their corresponding pre-port source geometry: zero
  material added or removed, unchanged bounds and valid solids.

Independent numerical evidence is in the task's scratch
`architecture/independent_geometry.json` and `architecture/scope_isolation.json`.
Generator reviewed: SHA-256
`c0a124ea22db2a86f18fab5d3cbbbce3e6a4d2cb93a39c333c41c002df894ee1`.

### Evidence Boundary

The checks above cover current source-generated geometry and temporary
exports produced by the mounting tests. The coordinator owns synchronization
of the actual Fusion component bodies, preservation of instance placement and
final artifact/archive freshness. Those operations were in progress during
this review and are not independently certified here. Geometry and assembly
access checks do not establish PETG strength, actual heat-set insert fit or
printed bridge quality; the existing first-print verification and separate
structural release hold remain applicable.

### Verdict

Architecture is clean within the stated #1037 source/geometry scope. No
actionable architecture or nominal assembly-fit findings remain.
