# Manufacturing round 2 — geometry and fabrication operations

Fresh review of the current working tree based on `1d14d701`, including the
uncommitted source, formed references and generated metal parts. This review
recomputed the geometry below rather than inheriting the prior clean verdict.
The root reviewer owns live Fusion access and the final regeneration.

## Findings and source corrections

### G2-1 — locate the lid laterally before capturing its final holes

**P2, corrected in source/process instructions and verified in final PDFs.**
The operation sheet in `segno_enclosure.py::_front_drilling_sheet` seated the
lid on both side edges and the rear lap, then captured all 18 holes. Those
contacts do not locate it in X. The actual lid has no side locating wings.

Counterexample from the actual assembly STEP: translate only the lid +1.5 mm
in X. Its left edge becomes −0.4 mm; the left side seat ends at X=0.089158839,
leaving **0.489158839 mm** bearing. Both side seats and the lap still carry the
lid, the front gap is unchanged, and there is no new substantial intersection
(the known seating films total 5.346780 mm³ in this displaced condition).
Capturing the screw holes there records a transverse offset greater than the
pedal opening's nominal 1 mm per-side allowance: opening width 78.35 mm,
maximum case width 76.35 mm. The mating pedal's precise tapered cross-section
still requires the actual-part fit check.

The corrected operation centers and squares the lid to the body, aligning
their outer-edge midpoints within **±0.15 mm at both front and rear**. All
actual pedals are checked before capturing that position; components are
removed for machining the empty chassis. This is also in `MANUFACTURING.md`
and `SHOP_REVIEW.md`. A/B continue to locate the front drill stations from
finished body faces. No metal geometry changed.

### G2-2 — the post's painted gap is a target, not a guaranteed minimum

**P3, corrected in source/documents and verified in the final post PDF.**
The post note claimed that a 1.2 mm bare gap guarantees at least 1.0 mm after
two maximum paint films. This omitted coating under the post foot and the
movement of the lid at its seats. For nominal geometry, with `c=cos(slope)`:

```
g_final = g_bare
          + (base_side_seat_film + lid_side_seat_film)
          - c * (base_floor_film + post_foot_film)
          - (post_pad_film + lid_pad_film)
```

Using `g_bare=1.2`, `c=0.976302648363` and independently allowed local films
of 0.06–0.10 mm gives **0.924739–1.162844 mm**. If the lid underside film is
uniform between its side seat and the pad, its terms cancel and the range is
**0.964739–1.122844 mm**. Uniform 0.08 mm films give **1.043792 mm**. These
figures exclude actual stock/bend variation; they do not establish a finished
physical fit.

`POST_FELT` comments, the `dxf_post` note, `MANUFACTURING.md` and
`FUSION_MODELS.md` now call 1.2 mm the nominal bare gap and approximately
1.0 mm the finished target. They require measuring the assembled finished gap
and fitting felt without lifting the lid off its seats. Post height and the
bare-geometry regression remain unchanged. No rigid metal collision was found.

### G2-3 — derive the two front-lid bend references

**P3, corrected in source and verified in the final lid PDF.**
`BEND_FOOTNOTES['segno_faceplate']` retained a 5.238 mm hole-to-bend distance
and said the front bend crossed pedal apertures, leaving 12.1 mm material.
Neither statement describes the current DXF:

- Front BEND line: V=12.082987548 mm.
- Front DRILL center reference: V=6.955420443 mm.
- Distance: **5.127567106 mm**, now printed as **5.128**, derived from these
  constants. It remains within the V12 tooling zone and remains deferred.
- First pedal opening edge: V=24.749052206 mm.
- Line-to-opening ligament: **12.666064658 mm**, now printed as **12.666**,
  derived from the actual pedal cutout list. The fold does not cross an opening.

The machining paragraph also now calls the encoder disc's straight 1.5 mm
bore length **nominal**, matching the accepted chamfer drawing and its positive
chamfer tolerance.

## Fresh geometry checks completed

- The current metal assembly contains **eight valid solids**. All **28 solid
  pairs** were intersected. Only base/lid are positive: 5.519204481 mm³.
  Projection of each intersection's vertices onto the actual seat normal
  bounds the two side films at **0.000266180 mm** each and the rear film at
  **0.000252685 mm**. This establishes submicron coincidence; it does not
  substitute for coating or first-piece fit.
- The front ISO 7380-1 M3 screw's conservative full cylindrical head envelope
  (Ø5.7 ×1.65 mm, rather than the smaller domed volume) has **zero volume
  intersection** with either front sheet. Its upper edge is Z=9.805420443 mm;
  the lid's straight front face reaches Z=10.283675414 mm, leaving
  **0.478254971 mm** nominal straight-face margin. The old introductory
  warning about a taller front is not evidence of a current M3 head collision.
- Rear pilot axes were extracted from the actual base cylinders at all nine
  stations. Their inner centers are Y=405.998427205, Z=92.591288136 mm;
  the outward axis is approximately `(0,0.413803,0.910366)`. Starting 0.01 mm
  inside that face, **Ø6 ×30 mm and Ø10 ×50 mm** cylindrical tool envelopes
  directed into the empty enclosure clear every one of the eight metal
  solids at all nine stations (**18 probes, zero intersections**). This proves
  available local shank space, not access for an arbitrary hammer, hand,
  chuck or shop's complete tool. The specified short guided transfer method
  still needs the shop's process acceptance before cutting.
- Coating seating was solved independently using the side and rear contact
  normals. All extreme pair-film cases confirm the specified 0.50–0.60 mm
  bare front gap gives **0.156879761–0.588013319 mm** finished nominal-geometry
  gap. The postpaint match-drill/transfer sequence avoids relying on the
  displaced bare lid-hole positions.
- All six actual CUT/VENT profiles pass exact closed-contour, containment,
  non-touching, non-overlap and single-connected-sheet checks. DRILL stays
  out of laser material: base has 9, lid 18. Four reliefs are part of the
  base perimeter; there are no redundant full-circle relief paths.

| Part | CUT/VENT area, mm² | Bends | Deferred holes |
|---|---:|---:|---:|
| Base | 466717.590672539 | 5 | 9 |
| Lid | 201480.778353175 | 2 | 18 |
| Rear panel | 28132.364482324 | 0 | 0 |
| Ring disc | 2042.357238080 | 0 | 0 |
| Rear bracket | 1877.235070003 | 1 | 0 |
| Support post | 2417.395139956 | 2 | 0 |

The source import succeeds with the derived notes. A scratch rendering of
the revised final drilling page was inspected at 1800 pixels: all lines fit,
the added transverse alignment instructions are legible, and the page retains
right and bottom margins. The regenerated final pages were subsequently
inspected as recorded below.

## Limits and remaining qualifications

Stock temper/gauge, actual tooling and springback, the short V12 flange,
side-wall punch access and acute steel-post bend still need shop acceptance
and a trial bend. The two rear brackets and ten rivets need actual dry fit and
a selected rivet rated for their hole, approximately 4 mm grip, 4 mm
center-to-edge distance and installation access. General position/bend
tolerances alone do not prove every fine-clearance pattern can assemble.
Coating quality, the measured finished clearances, actual purchased parts,
felt compression, thread torque/service life and foot-load stiffness remain
physical qualifications, already held in the release instructions.

This report does not qualify electrical safety, PCB design, structural life
or arbitrary tooling. Follow-up examination of the root's expanded printed
part intersection sweep is recorded below when complete.

## Follow-up: printed-part intersection magnitudes

The root broadened the native sweep to 69 manufactured printed bodies against
924 visible bodies (1056 candidate pairs, no Boolean failures). Its positive
non-holder results were examined by location and penetration, not discarded
because their volumes were small:

- **Ten sled/collar seats:** every native intersection occupies only
  **0.000139371686 mm in world Z**, at the horizontal supporting seat. The
  approximately 1.201731 mm³ per pair is a broad submicron contact film.
- **7-inch module/tower:** the tracked measured module STEP and current tower
  STEP, placed using the exact current native transforms, reproduce
  **0.859314510628 mm³**, against native **0.859314511201 mm³**. There are four
  tab/boss patches of 0.214764–0.214893 mm³. Vertex projections onto
  `(0,−0.216409655053,0.976302648363)` bound every patch at
  **0.004513071 mm** normal penetration. This is a 4.5 µm seating-position
  residue at the four intended mounts, not a broad PCB collision. Actual
  printed support height still needs the stated fit check.
- **Ten tile/rubber-pad interfaces:** exact native REC_PLAY and Top Pad exports
  reproduce **0.754999798039 mm³** as a toe-end strip. In tile coordinates it
  spans Y=−9.950000000 to −9.942197128 and Z=0 to 1.8 mm: maximum transverse
  intrusion is **0.007802872 mm**. It is not a normal seat film. The source
  explicitly specifies a compliant rubber press fit because 0.05 mm clearance
  is below FDM resolution. This 8 µm nominal placement residue does not
  establish a physical fit defect or call for a tile-outline change.

For an exact nominal tile placement, the two pad end planes lie at tile-local
Y=−9.942197128 and +10.064296499. Their midpoint is **+0.061049686 mm** from
the current origin. Moving the complete tile parent that far toward its cable
end centers its 19.9 mm body with **0.053246813 mm clearance at each end**.
A +0.05 mm trial shift was intersected and gives zero tile/pad overlap. The
root's disposition is to retain the existing placements: the quantified 8 µm
residue at an explicitly compliant rubber fit is not a geometry defect that
justifies moving the ten visual tiles and their glyphs.

No additional macroscopic geometry defect was found in these three interface
families. This disposition is separate from the ring-holder defect being
corrected and rechecked by the root/interface reviewer, and from decorative
light bodies that are not manufacturing geometry.

## Final regenerated-artifact review

After the complete generator exited successfully, all pages of the following
current files were rendered and independently inspected, with extracted PDF
text checked against the corrected source:

| Final file | Pages inspected |
|---|---:|
| `out/segno_base.pdf` | 2 |
| `out/segno_faceplate.pdf` | 2 |
| `out/segno_post.pdf` | 1 |
| `out/segno_ring_disc.pdf` | 1 |
| `out/segno_paint_quote.pdf` | 4 |

**All 10 pages pass visual and operation-note review.** No clipping,
overlapping instructions or missing tolerance/finish text was found. Both
drilling sheets carry the lateral ±0.15 mm alignment, actual-pedal fit and
empty-chassis machining sequence. The lid sheet prints the independently
derived 12.666 mm ligament and 5.128 mm drill reference. The post sheet
requires measuring the assembled final gap and fitting felt without lifting
the lid. The corrected source values and relevant dimensions are unchanged.

The ring disc's new **finished outer diameter 51.40–51.50 mm** is stated on
its drawing and in the paint cover's part remark; it explicitly overrides the
general contour tolerance and requires masking/finishing its edge and measuring
after paint. The final Ø7.2 bore, underside-only C0.5 positive-tolerance
chamfer, nominal 1.5 mm straight bore and upper nut face remain coherent.
All four paint pages retain smooth matte black RAL 9005, specified film,
functional-bore masking, electrical lands and separate postpaint machining.

**Final scope disposition: no unresolved actionable findings in the reviewed
metal geometry, fabrication/coating operations, corrected notes and assigned
printed-contact families.** This is a clean digital review within the stated
scope, conditional on the shop/tooling and physical qualifications above; it
does not authorize cutting or establish structural/service-life qualification.
