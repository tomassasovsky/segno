# Fully coated seating and pre-paint machining: selected geometry

The selected correction is eighteen lid clearance bores Ø4.5 (+0.10/−0.00)
before coating, M3 ISO7089/DIN125 washers of nominal Ø7, and front screw axes
0.50 mm lower, at 6.455420 mm above the bare floor bottom. Their nine X stations
remain unchanged. Rear screw centers remain unchanged. All body/lid mating
surfaces are coated; owner-fit front shim packs are selected after curing.
Completed M3 threads must remain functional under the separately agreed thread
protection process; coating them cannot be assumed to preserve screw fit.

## Seat movement and alignment

Native main-seat normal in YZ is (−0.2164096551, 0.9763026484); rear-seat normal
is (0.4138029443, 0.9103664775). Solve `n_main · delta = q_main` and
`n_rear · delta = q_rear`, with both mating film sums independently 0.12–0.20 mm.
Uniform 60/80/100 µm films give (dy,dz), respectively:

- (0.013165, 0.125831) mm
- (0.017553, 0.167775) mm
- (0.021942, 0.209718) mm

Independent main/rear sums expand dy to −0.108013..+0.143120 and rear tangential
axis shift to −0.173194..+0.066303 mm. These uniform-plane values alone are not
the final allowance: film may vary along a bearing edge.

Using the actual main straight-seat ends (Y,Z) = (2.350771,12.944639) and
(391.466079,99.196899), plus the rear bore plane at (406.412230,93.501655), allow
each pair-film value independently to take 0.12 or 0.20 mm. A first-order rigid
plane solve adds pitch up to 0.000200723 rad. At the front row, dz then spans
0.100498–0.235052 mm. Rear tangential shift spans −0.177655..+0.070764 mm.
Second-order displacement is under 0.000009 mm over this enclosure length.

Finished lid bores are 4.30–4.48 mm across the stated machining and film ranges.
Their minimum radial clearance around a maximum Ø3 screw is 0.65 mm. Include
independent bare/final centering ±0.15 mm at both ends (0.30 difference),
0.04 mm allowance for asymmetric coated edge datums, 0.01 mm residual angular
offset between local alignment edges and the screw row, and hole opening/transfer
error ±0.10 mm per axis. Worst front offset is
`hypot(0.235052+0.10, 0.30+0.04+0.01+0.10)` = 0.561034 mm, leaving 0.088966 mm.
Rear corresponding offset is 0.528765 mm, leaving 0.121235 mm. All eighteen
holes share the matched bare assembly; the lid must still be centered at both
ends, freely seated, and all screws started loosely before tightening.

The front gap is 0.50–0.60 bare, minus opposing front films and dy. Its predicted
finished span is 0.156880–0.588013 mm, within an acceptance range of 0.15–0.60.
Fit shim packs to that actual painted gap with residual 0.00–0.02 mm. Previously
fitted bare packs do not retain their thickness validity under this process.

## Ligaments and the front shim contact area

Actual base front straight planes extend from Z4.000000 to 10.094780 mm. The
lid's straight front face extends from Z−0.000273 to 10.283675 mm. With the
lowered axis, maximum lid hole Ø4.6 and +0.10 mm positioning error, upper straight
ligament is 1.428255 mm. Below the finished M3 thread's Ø3 major diameter, the
base retains 0.855420 mm before the bend tangent at −0.10 mm height error.
The rear lid hole retains 10.235445 mm toward its bend tangent and 9.571583 mm
toward the free lap edge, including maximum diameter and ±0.10 mm position.

Use measured shim OD6.9–7.0, ID4.0–4.2; a nominal 4×7 shim is acceptable only
when the actual dimensions fall in those ranges. The Ø7 shim extends below the
base's straight wall into its receding bend: it does not intersect the curved
body, but it does not have a full planar annular bearing land. Do not claim one.

Conservative circle/stripe intersection bounds include maximum hole
eccentricity, shim/washer float on a screw major diameter of at least 2.874 mm,
maximum finished lid hole Ø4.48, minimum shim OD6.9 and maximum shim ID4.2:

- Shim to base planar bearing: at least 16.6575 mm².
- Shim to lid planar bearing: at least 16.7905 mm².
- Ø7 washer to lid: at least 18.3072 mm², using ISO7089 minimum OD6.64 and
  maximum ID3.38.

The bounds subtract worst missing straight-wall area and worst eccentric bore
overlap separately, so they are conservative. A direct angular integration
sweep corroborates 16.6575/17.3164/18.3080 mm² respectively. This is geometric
support area, not a preload or powder-coat creep test. Actual torque, retention
and repeated removal still need qualification on the coated 2 mm aluminum joint.

## Screw length

Retain the existing M3×8 screws. For measured under-head length 7.8–8.3 mm,
washer 0.4–0.55, stock 1.9–2.1 and local film 0.06–0.10 mm, the maximum front
head-to-thread-entry stack is `0.55 + 2.1 + 3*0.10 + 0.60` =3.55 mm.
At least 4.25 mm of screw remains; rear at least 4.85 mm. The resulting tip
projection beyond the body metal is 2.15–3.77 mm front and 2.75–3.92 mm rear.

The actual pre-change populated348 snapshot contains all eighteen M3×8
references. The proposed Ø7 washers shift their heads 0.5 mm outward; the front
row is also0.5 mm lower. For each new washer pose, an enclosing box around the
entire maximum 8.3 mm shaft, with maximum Ø3 shaft and a further 0.6 mm inflation
in every world direction, remains separate from every unrelated visible solid
bounding box. Minimum conservative clearance is 2.317731 mm at the two rear
brackets and 5.028702 mm at the front sleds. The inflation exceeds the computed
coating/centering displacement and the ≤0.20 mm printed support changes. Native
base, lid and fitted shim packs are intended joint contacts and were excluded.
Nominal tips are Y3.089158/Z6.455420 at the front and
Y404.550112/Z89.404731 at the rear. This also clears the unchanged metal floor:
the front shaft lower extent remains above Z4.35 even with the 0.6 mm inflation,
while the inside floor is Z2.

This is a geometric engagement/obstruction proof, not a thin-aluminum thread
strength or wire-routing qualification. Confirm screw dimensions and route wires
clear of the actual tips during owner assembly. No screw-SKU change is needed.

## Remaining visible light apertures

Keep existing lens dimensions and centers. Changing LED_SLOT_W/H or RING_OD
would also grow the printed lenses and cancel the new clearance. Enlarge only
the metal openings to pill 60.4×6.4 with R3.2 and ring Ø67.4, with +0.10/−0.00
size tolerance before paint. At 100 µm film, final minimum openings are
60.2×6.2 and Ø67.2, providing 0.20 mm radial nominal clearance to the existing
59.8×5.8 and Ø66.8 lenses; 0.10 mm remains if the printed overall size is 0.20 mm
large. The pill's 68×14 flange retains at least 3.81 mm overlap per edge against
the maximum final opening 60.38×6.38. Aperture centers and all visible controls
stay fixed. Screen active-area registration and the internal support setback
are covered by the interfaces review.

## Sources and limits

[Accu's ISO7089 M3 washer specification](https://www.accu.co.uk/metric-flat-washers/415470-HPW-M3-V1-A2)
gives OD7 (−0.36/+0), ID3.2 (+0.18/−0), and thickness0.5 (+0/−0.1) mm.
[Nord-Lock's painted-joint guidance](https://www.nord-lock.com/tr-tr/learnings/bolting-tips/2022/washers-offshore-painted-surfaces/)
identifies preload loss from coating settlement and surface damage during
tightening. A plain washer does not by itself eliminate those effects.

This proposal changes no rear riveted joint, corner relief or ridge contour.
The implemented source/formed-cache tests pass as recorded below. Physical print tolerance, local film thickness,
coating-cycle distortion and clamp qualification remain real acceptance checks.

## Implemented verification

The current generated source and freshly exported formed cache pass all 17
manufacturing-fit tests (28.604 seconds), including the 35-solid assembly:
eight made parts, nine fitted shim references, and eighteen washer references.
All eighteen washers are coaxial with the actual formed bores, seated on the
actual metal faces, and clear of the lid solid. The nine front shim packs meet
the actual bearing-area checks; displaced-pack and displaced-bracket negative
cases fail as intended. The 0.000273 mm native front-edge numerical correction
remains within the existing independent numeric check; strict flat parity was
not weakened.

The scope-specific result is clean under the stated dimensional/process
assumptions. The exact source/manifest hashes, independent measurements and
bounds are in `full-coat-geometry-proof.json`. Saved/reopened populated349 and sheet-metal137 snapshots (both clean) pass the
recorded independent
washer/screw/shim, front-axis, rear-seam, post-bore and disc-profile checks. The
review caught the VSM base front pilots retaining their old height; the corrected
geometry now agrees within 0.000273 mm, the existing native numeric residue.
Root owns final live save/reopen checks, final package QA and the user-approved
completed-thread protection process.

The subsequent populated350 save changes only the corrected S16 reference pose
and an equivalent shared mid-collar body replacement. Native metal geometry,
washer/screw placements and seam measurements remain unchanged. The current
saved-version record is [full-coat-verification.json](full-coat-verification.json).
