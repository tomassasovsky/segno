# Manufacturing interface review — fresh round 2, 2026-09-05

Scope: current manufacturing source, generated part solids, supplier handoff
instructions and saved/reopened populated Fusion 343 evidence. This review
independently examines the actual geometry and does not accept the previous
review's clean claim as evidence. It includes the printed holders and their
purchased-part interfaces, because those determine whether the console can be
assembled. The reviewer made no source, production-output or Fusion edits.

## R2-IF-1 — P1: The selected Ring24 assembly intersects its printed holder

Locations: `hardware/enclosure/segno_enclosure.py`,
`build_ring_diffuser_step` (the through LED relief and shallow PCB counterbore);
`hardware/enclosure/FUSION_MODELS.md`, “Ring board (populated only)”; and the
initial round-2 `hardware/enclosure/RELEASE_REVIEW.md` status/verification.

The selected PR #990 Ring24 module on its documented 2.54 mm pin-strip stack
does not fit the current printed holder. This is independent of the older
Ø68-versus-selected-Ø80 board revision and independent of the already corrected
EC11 root chamfer. The saved native holder and current source print agree in
volume and geometry, so neither can be used with this modeled stack as drawn.

Exact native components are `ring_holder24:1 / Body1` and descendants of
`ring_board_asm:1+NeoPixel_Ring24:1+Adafruit NeoPixel Ring 24 B v3:1+PCB Component:1`:
`Board:1`, `WS2812B-NARROW:1` through `:24`, and `C0603:1` through `:15`.
There are **40 positive contacts totaling 731.560379 mm³**. The Ring24 PCB
alone intersects by **156.251908 mm³**, and each of its 24 LEDs intersects
the lens by **23.460748 mm³**. This is not a numerical seating film.

The holder frame has its lens-bottom/glue plane at z=0, the back plate at
z=-2..0 and the visible lens at z=0..2.4. The actual ring PCB occupies
z=-1.954601..-0.384601; the LEDs extend to **z=+1.015399**, physically inside
the present lens. The saved board-to-holder relative translation in millimetres
is `(-35.980430, 36.0205068984, -6.08960105775)` with equal rotations.
These values were derived from the saved row-major transforms, converting
their translation entries from centimetres to millimetres.

The generator's comment already acknowledges the pin-strip incompatibility,
but its current geometry and saved assembly still contain it. The initial
round-2 release document's completed-defects statement and metal/body-only
intersection coverage omit this modeled printed-part collision.

Fix: reconcile the holder's internal relief with the selected module stack,
preserving the owner's ring, encoder, board and cosmetic positions. Verify the
revised source and native holder against **all 73 selected board bodies**,
not just the metal disc or the LED package tops. Keep the disc-support lip
connected and specify the resulting roof/wall thicknesses and fit allowance.
Do not silently substitute a flat-soldered layout or move the selected board.
Until the correction is verified, the complete manufacturing review is not
clean; this does not imply a change to the metal aperture.

Reproduction data: `interfaces-ring-holder-before.json`. The parent independently
confirmed the same 40 contacts and 731.560379 mm³ in live Fusion.

## Candidate check supplied to the parent

The first scratch candidate extends the existing LED relief, r26.5..32.1,
from z=-2 to z=1.35, and deepens the PCB counterbore, r26.0..33.1, from z=-2
to z=-0.05. It remains one valid solid and has zero intersections with all
73 bodies. It preserves a nominal 1.05 mm lens roof and approximately
0.65/1.30 mm inner/outer lens walls.

However, its measured minimum radial clearances are **0.133654 mm to the PCB**
and **0.182242 mm to an LED**, despite the roughly 0.335 mm axial clearances.
The ring/holder centre mismatch is 0.028346 mm radially. A generic “0.3 mm
clearance” description would therefore be false. Blindly increasing the PCB
counterbore inward to meet 0.3 mm would cross the lens's inner radius and leave
only the 0.05 mm counterbore roof connecting the support transition. The parent
must resolve the actual clearance/wall tradeoff and printed fit acceptance;
the candidate is not itself a released design.

## Other checks and dispositions

- Freshly compared source STEP volumes with the reopened native components for
  both pedal collars, the sled, both 15.6-inch stands, the 7-inch tower and the
  ring holder. These correspond to the current source variants; there is no
  evidence that an older printed-part variant explains the ring collision.
- Measured the actual 14 vertical M3 floor pilot axes and all 14 printed stand
  anchors. All six 7-inch axes are within 0.014879–0.044349 mm of their base
  axes. The eight 15.6-inch axes share a 0.097923 mm displacement along y from
  the rounded base stations. This is within nominal Ø3.2/M3 clearance but
  consumes nearly all clearance at the frozen CAD seat; actual simultaneous
  assembly and the permitted stand/monitor adjustment remain part of the
  existing physical fit acceptance. No failure is inferred solely from the
  common displacement. Full measurements are in
  `interfaces-stand-anchor-check.json`.
- The revised shop and painter instructions consistently keep suppliers
  separate, specify smooth matte black with no texture, preserve functional
  openings after coating and defer all lid holes to the finished seating.
  Tap pilots and rivet bores are excluded from the final clearance-bore
  tolerance. The release remains explicitly held for supplier acceptance and
  real-part measurements; it does not authorize cutting, ordering or sending.
- The actual pedal base thickness, blind monitor threads, converter-ear washer
  bearing area, foot hardware, printed insert fit, rivet selection and finished
  screw lengths remain measurement/selection requirements. They are not
  proved by matching source assertions or approximate purchased-part models.

Starting file hashes are in `interfaces-starting-sha256.json`. Any correction
requires another check of its final source, output and native geometry before
this finding can be closed.

## R2-IF-2 — P1: Control the disc's finished outer diameter

The bore/chamfer masking instruction initially omitted the disc's outside
edge. The holder pocket is Ø51.7, so coating a nominal Ø51.5 disc's radius by
the allowed 0.10 mm consumes all radial allowance. With the saved 0.003914 mm
centre mismatch, the resulting Ø51.7 disc intersects the holder by
0.404754 mm³; outside-contour tolerance can make this worse. This applies to
the original holder as well as the corrected cavity.

The parent authorized finished OD **51.50 (+0.00/−0.10) mm**, overriding the
general contour tolerance, with the edge masked or finished and measured after
painting. The source drawing/bend footnote, painting-table note, manufacturing
instructions and both short supplier drafts now agree. This leaves nominal
radial clearance 0.10 mm at the maximum accepted diameter before the measured
centre residue. It is a specified controlled finishing operation, requiring
shop acceptance; it is not a claim that the laser alone guarantees this band.

## Final correction and re-review — both findings closed in files

On explicit parent instruction the reviewer implemented only the holder
function, disc finish notes, matching assembly prose and independent numeric
reference/regression files. The parent modified the existing native holder
in place and saved/reopened populated Fusion **344**.

The final open-bottom holder uses a PCB cavity r25.8..33.1 at z=-2..-0.25
and LED channel r26.35..32.3 at z=-2..1.35. Eight 1.2 mm radial ribs occupy
verified unpopulated angles, r25.85..32.8 and z=-0.25..1.35. The 0.25 mm shelf
and ribs reinforce the disc seat; no continuous lower bridge traps the PCB.
The upper lens has nominal 0.50/1.10 mm inner/outer walls and 1.05 mm roof.
The Ø51.7 disc pocket and all visible geometry above z=1.35 remain unchanged.

Freshly generated source geometry, the independently studied candidate and
the final native holder are all valid one-solid shapes and exactly match in
both Boolean directions. Their volume is **4485.550372 mm³**. The native
reference's **73 bodies have zero intersection** with the final shape.
Minimum PCB clearance is **0.134601 mm** and LED clearance **0.332242 mm**;
this is explicitly not described as 0.3 mm everywhere. Eight withdrawal
samples from 0 to -5 mm are collision-free. The cavity opens monotonically
downward over the PCB footprint; ribs occupy gaps between taller components,
so the design has no hidden lower retention ring blocking insertion.

Two focused tests passed independently. The first uses 41 conservative
numeric PCB/LED/passive envelopes extracted from the actual selected module,
each proved to contain its source solid, rather than regenerating expectations
from the holder function. It checks contact and insertion and has meaningful
negative cases for the former solid lens and a lower bridge that clears the
final seat but traps the PCB during installation. The second verifies the
accepted finished-disc OD band and rejects the oversized coated-disc case.

The new ribs make rotational indexing necessary. The assembly instructions
require the actual board to dry-fit before gluing, +X toward the 15.6-inch
screen, with ribs in the exact component gaps. The internal top-view reference
`hardware/enclosure/reference/ring24_orientation.svg` was rendered and visually
inspected: LED/passive footprints, all eight rib angles and the +X/front/rear
directions correspond to the measured fixture. It warns that the underside
view is mirrored. No visible alignment mark or cosmetic geometry was added.

Final source/native parity, all-body contacts, insertion measurements, tests
and reviewed file hashes (including the SVG) are recorded in
`interfaces-final-proof.json`. Scoped whitespace validation passes. No
unresolved actionable digital interface defect remains within this review's
scope. The approximately 0.135 mm minimum PCB gap still requires one real
printed fit check; print variation, actual header stack, nut/holder retention
and light diffusion have not been physically qualified by CAD.
