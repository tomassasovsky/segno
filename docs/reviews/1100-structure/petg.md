# PETG platform and sled load-path calculation

Date: 2026-09-09. Scope: current front and CLEAR/BANK printed platforms and
sleds; analysis only. No CAD or manufacturing geometry changed.

## Finding

The gross PETG sections do not show an obvious static compression or bending
failure at 700 N on one pedal in the modeled assembly. The most demanding
central 30 × 30 mm load case gives 5.42–6.52 MPa principal bending stress in an
approximate two-way deck/sled model. At 350 N this becomes 2.71–3.26 MPa. At
1,400 N it becomes 10.84–13.03 MPa. These are calculated demands, not a rating
for an unknown PETG print or a qualification of a real stomp.

The metal base/floor support response remains a separate and potentially
controlling calculation. This report must not be used to declare the complete
console safe merely because these local PETG demands appear modest.

## Geometry and force path

Read directly from the current source and the exported STEP solids:

| Feature | Measurement |
|---|---:|
| Collar outer footprint | 118.47 × 88.75 mm |
| Tall underside cavity | 112.47 × 82.75 × 30.345 mm |
| Tall perimeter wall below deck | 3.00 mm |
| Tall deck thickness | 8.00 mm |
| Sled thickness at center | 12.633 mm |
| Sled plan envelope | 113.27 × 78.75 mm |
| Sled thickness at pedal toe, X = −54.935 mm | approximately 10.85 mm |
| Front collar floor | 2.043 mm |
| Tall supporting columns | four Ø12 mm |
| Column axes, local X/Y | X ±48.685, Y ±22.1875 mm |
| Tall base insert pockets | Ø4.5 × 6 mm, bottom-facing |
| Separate tall sled/deck pattern | X ±30, Y ±18 mm |
| Front collar contact with base | 10,471.204 mm² |
| Tall wall contact with base | 1,207.320 mm² |
| Each tall column contact with base | 97.193 mm² |
| Total tall contact with base | 1,596.092 mm² |

The pedal's removed lower pad leaves its case underside sitting on the sled.
The source describes direct case-to-sled contact; the exact physical shell
bottom relief and its force distribution have not been measured in this
calculation. Loads are therefore applied both as a broad 90 × 60 mm patch and
as a smaller 30 × 30 mm patch, rather than asserting perfectly uniform
pressure over the pedal outline.

The downward force travels from pedal case into the sled, from the sled into
the collar deck, and from the tall deck into its perimeter and four columns.
Those contact surfaces load the metal base. The front collar instead has a
near-continuous thin floor. Retention screws clamp and locate the assembly;
assigning all downward stomp force to insert pull-out would be the wrong
force path.

The base FE loading should distinguish these contact shapes. A full solid
118.47 × 88.75 mm pressure patch represents the front collar approximately;
it does not represent the hollow tall collar. For the tall collar, use its
3 mm rectangular perimeter plus four annular feet, and assess alternative
reaction distributions if deck/metal compliance changes which supports engage.

## Printed-material assumptions

User settings: PETG, 0.2 mm layers, six perimeters, 40% gyroid, six top and
bottom layers. This calculation assumes a 0.4 mm extrusion line width:
1.2 mm top/bottom skins and approximately 2.4 mm outer perimeter bands.
Actual line width, infill paths, adhesion, temperature, moisture and extrusion
quality remain printer-specific.

Prusa's measured printed PETG tensile modulus is about 1.5–1.6 GPa and its
flexural modulus about 1.6–1.7 GPa. Its separately reported interlayer
adhesion is 18 ± 4 MPa. Those specimens used 100% rectilinear infill and are
not the user's 40% gyroid parts. Here, 1–2 GPa is an explicit stiffness
sensitivity for dense printed skins, not a guaranteed property; no solid
filament tensile strength is adopted as a printed-part allowable.
[Prusament PETG technical data sheet](https://prusament.com/wp-content/uploads/2022/10/PETG_Prusament_TDS_2021_10_EN.pdf).

Core elastic modulus is screened at 0.16 and 0.40 times the skin modulus.
These are chosen engineering sensitivity ratios, respectively the square of
nominal relative density and nominal relative density. They are not claimed
to be measured bounds for this exact gyroid. Experimental gyroid research
shows that printed relative density and bulk stiffness depend on resolved
cell geometry and printing. That study used toughened PLA, so its numerical
strengths are not transferred to PETG.
[Experimental gyroid elastic-properties study](https://www.mdpi.com/2076-3417/12/4/2180).

## Compression and local stability

The 3 mm wall sections are expected to be filled by overlapping perimeter
paths. The columns are solid around the bottom insert bore; above the insert
pocket, the six outer perimeters leave a nominal Ø7.2 mm infill core. Taking
40% of that core area gives 88.669 mm² effective axial area per upper column,
which is smaller than the 97.193 mm² lower annulus and governs this screen.

| Applied force | Front mean pressure | Tall mean pressure | All force through four columns | All force through one column |
|---|---:|---:|---:|---:|
| 200 N | 0.019 MPa | 0.125 MPa | 0.564 MPa | 2.256 MPa |
| 350 N | 0.033 MPa | 0.219 MPa | 0.987 MPa | 3.947 MPa |
| 700 N | 0.067 MPa | 0.439 MPa | 1.974 MPa | 7.895 MPa |
| 1,400 N | 0.134 MPa | 0.877 MPa | 3.947 MPa | 15.789 MPa |

The last column is an intentionally severe distribution sensitivity. It is
not the predicted load share: the perimeter and other columns also contact
the base. If all core material is ignored, a single column carrying all
700 N needs 9.67 MPa in its outer shell.

A pinned Euler-column calculation for the 30.345 mm unsupported length,
E = 1 GPa and only the outer 2.4 mm radial shell gives approximately 9.50 kN
per column. Elastic global column buckling therefore does not appear to be
the controlling local mode. This does not rate the column's material crushing
strength, layer defects or local insert installation damage.

A 700 N load on 30 × 30 mm gives 0.778 MPa gross contact pressure. Dividing by
40% nominal polymer fraction gives a simple 1.94 MPa core stress scale before
load spreading or detailed gyroid strut bending. A 1,400 N load doubles it.

## Deck and sled bending

A two-way Navier plate solution was evaluated over the cavity span,
112.47 × 82.75 mm, with all four sides simply supported. The four interior
columns and the upper baffle stiffness are omitted. The deck and sled are
allowed no bonded composite action: their separate flexural rigidities add.
They are assumed to remain in normal contact and have approximately equal
curvature under the downward load.

For each layer of thickness t, skin thickness s = 1.2 mm and core/skin
modulus ratio k, the section inertia per unit width is:

`I(t) = [t³ − (1 − k)(t − 2s)³] / 12`

`D = E [I(8) + I(t_sled)] / (1 − ν²)`, with ν = 0.35.

The rectangular pressure patch is expanded into a double sine series, with
`W_mn = Q_mn / [D (kx² + ky²)²]`. Moments follow from the second derivatives
of W. Skin stresses are recovered using the individual slab's distance to
its own neutral plane; the assembly is not treated as a bonded 20.633 mm
solid plate. This is the standard simply supported plate method described
by [IIT Guwahati's rectangular plate course](https://archive.nptel.ac.in/courses/112/103/112103251/).

| Static load | Center 30 × 30 mm maximum principal stress | Center bending deflection, E = 1–2 GPa |
|---|---:|---:|
| 200 N | 1.55–1.86 MPa | 0.051–0.123 mm |
| 350 N | 2.71–3.26 MPa | 0.090–0.216 mm |
| 700 N | 5.42–6.52 MPa | 0.179–0.431 mm |
| 1,400 N | 10.84–13.03 MPa | 0.359–0.862 mm |

At 700 N, the broad 90 × 60 mm patch gives 2.54–3.06 MPa maximum principal
stress. A toe-side 30 × 30 mm patch, placed entirely within the pedal outline
and conservatively using 10.84 mm sled thickness over the whole plate, gives
3.87–4.51 MPa maximum principal stress. The central small patch governs these
bending cases.

At the new mid retention positions, the unperforated plate's central-load
nominal principal stress is about 2.79 MPa at 700 N. Three times that nominal
stress is 8.37 MPa. This is only a notch sensitivity scale, not a solved hole
stress concentration or a heat-insert allowable; the real pocket terminates
within the sled and has perimeter paths around it.

Limitations that affect these numbers:

- The deck is slightly larger than the sled. Treating them as coextensive
  slabs neglects the short deck transfer strip at the outer edges. Normal
  contact, local separation, insert pockets and screw clamp forces are not
  solved explicitly.
- Kirchhoff bending neglects transverse core shear. These are fairly thick
  slabs for this span. A one-way shear sensitivity, using a 30–75 mm load
  width, the combined 15.833 mm core thickness and the stated elastic ratios,
  adds roughly 0.05–0.62 mm at 700 N. The table is bending deflection alone,
  not a prediction of total measured movement.
- The four omitted columns should reduce broad bending, but their local
  stress concentrations and their support flexibility are not included.
- The underlying metal base is not rigid in reality. Its movement and
  contact redistribution must come from the enclosure calculation.
- The toe eccentric plate solution uses ideal simply supported edges;
  local edge lift and corner hold-down are not resolved.
- A sharp point, a protruding case feature, or a much smaller real contact
  patch would require a different local stress screen.

For perspective only, a chosen 10 MPa short-duration gross-section screening
limit would give a 1.53 ratio at the 700 N central case. A chosen 15 MPa limit
would give 2.30. Neither threshold is an established allowable for the user's
filament and print. The 1,400 N case fails the chosen 10 MPa screen.

## Retention and rocking

A vertical force anywhere within the modeled pedal footprint also lies
inside the collar's base support polygon and inside the sled/deck contact
polygon. There is therefore no statically required insert pull-out solely
from that vertical load. This does not mean zero screw force: clamp preload,
non-flat contact, lateral loads and local flexure can load the inserts.

An explicit lateral sensitivity uses H = 0.2P at the outer pedal edge. This
ratio is an assumption, not a measured stomp direction. At P = 700 N, a
rigid-body edge-bearing model gives up to approximately 50 N per opposing
base insert or 41 N per opposing deck/sled insert for the side direction.
The corresponding toe direction gives approximately 37 N and 25 N. At
1,400 N those forces double. Combined corner loading and joint compliance
are not included in this simple pair calculation.

No generic pull-out number is assigned to the M3 Ø5 × 5 mm inserts. Their
actual knurl, the printed boss, installation and clamp torque determine
performance. Manufacturer guidance explicitly ties retention to those
variables. [SPIROL insert design and performance guide](https://www.spirol.com/assets/files/ins-threaded-inserts-design-guide-us.pdf).

## Verification and reproducibility

- STEP bottom-face areas and dimensions are recorded in
  `petg-geometry.json`.
- `petg-calculate.py` reproduces the plate, compression, column and rocking
  tables using NumPy and writes `petg-results.json`.
- The plate code reproduces the uniform-load simply supported square result
  `w_center / (q a⁴ / D) = 0.004062352659`, versus reference 0.004062352660.
- Increasing the series from 31 to 101 modes changes the central 700 N
  principal stress from 6.51398 to 6.51531 MPa (0.021%); deflection changes
  from 0.431128031 to 0.431128426 mm. This verifies series convergence, not
  the physical assumptions or printed-material properties.
- The force cases are static force bases: 200 N working, 350 N scale-display
  reference, 700 N provisional high static screen, and 1,400 N sensitivity.
  The user's 35 kg scale display does not measure a validated transient peak,
  and doubling a static load is not an impact qualification.

This calculation supports proceeding with the intended first-print fit and
load-path checks. It does not establish a fatigue life, sustained-load creep
limit, temperature rating or a complete-console stomp rating.
