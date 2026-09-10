# Load cases and boundary assumptions for the 1100-H14 calculation

This is an independent modelling review of the current source geometry, not a
load rating. No CAD geometry, manufacturing export, or native Fusion document
was changed by this review. The numerical assembly results must state which
assumptions below were actually implemented.

## Material basis

The supplied Alcast certificate for lot 26E0269 specifies 2.00 mm 1100-H14:
95 MPa minimum 0.2% proof stress, 127 MPa measured proof stress, and 145 MPa
measured tensile strength. The minimum is the main calculation reference;
127 MPa is a separate lot-result sensitivity. Ultimate strength is not the
criterion for avoiding a permanently bent enclosure. Certificate transcription
and its hash are retained in `../material-certificate/certificate-review.json`.

Use linear elastic E = 69,000 MPa and Poisson ratio 0.33 for the room-temperature
metal calculation. These are alloy-level modelling properties, not additional
measurements of this lot. The supplier's published 1100 data lists E = 69 GPa
and G = 26 GPa, consistent with Poisson ratio approximately 0.33. A sheet
manufacturer also publishes 0.33 directly. [Austral Wright 1100 data](https://www.australwright.com.au/products/aluminium/aluminium-data-sheet/),
[Henan Lichen 1100-H14 data](https://www.lichenalu.com/uploads/file/1100-h14-aluminum-circle.pdf).

The corresponding 2 mm thin-plate bending rigidity is
`D = E*t^3 / [12*(1-nu^2)] = 51,621.6 N mm`. This is useful for an independent
unit and stiffness check, not a replacement for the actual perforated and
folded geometry. Nominal sheet thickness is 2 mm; the certificate does not
establish a lower thickness tolerance for every point in the finished part.
A 1.9 mm sensitivity, if run, represents an assumed 5% thickness reduction:
isolated plate bending stress scales by 1.108 and deflection by 1.166. It must
not be described as the supplier's declared tolerance.

## What powder curing changes in the evidence

The incoming-material certificate does not test the subsequent coating cycle.
1100 derives strength from cold work. Recovery and annealing can lower that
strength depending on temperature and time. ASM describes this mechanism;
Austral Wright lists full annealing at 350°C and stress relief around 220°C,
with testing if strength loss matters. These facts do not show that the chosen
powder cycle necessarily anneals this enclosure. [ASM aluminium fabrication
guide](https://www.asminternational.org/aluminum-and-aluminum-alloys-subject-guide/),
[Austral Wright heat-treatment information](https://www.australwright.com.au/products/aluminium/aluminium-data-sheet/).

A representative smooth-matte powder has an object-temperature cure window
of 180°C for 15–30 minutes or 200°C for 10–20 minutes. Other powders have lower
temperature windows. The actual painter's product and metal-temperature cycle
remain unknown. No validated 1100-H14 residual proof-strength curve was found
for that exact cycle; do not invent a percentage deduction or assert that
95/127 MPa is guaranteed after baking. [AkzoNobel Interpon D1036 Matt data](https://powdercoatings.brand.akzonobel.com/m/16009339936cddca/original/Interpon-D1036-Matt-30-.pdf).

If the assembly fails the required mechanical case with as-received 95 MPa or
even 127 MPa, this thermal uncertainty does not rescue it. If it passes only
with a small as-received margin, post-cure material retention matters. A
hypothetical 25 MPa annealed-material sensitivity can demonstrate whether the
design depends on cold-work strength, but is not a measured result or a
guaranteed bound for the finished part.

## Applied loads

The owner weighs 70 kg and observed 15–20 kg during sustained presses and a
maximum displayed 35 kg on a scale. Treat displayed kilograms as approximate
kg-force readings converted with 9.80665 m/s². A consumer scale's sampling and
display filtering do not establish the transient peak of a stomp.

| Case | Vertical force on one pedal | Interpretation |
|---|---:|---|
| Repeated operating screen | 200 N | Approximately 20.4 kgf; upper sustained reading rounded up |
| Observed-load reference | 350 N | Approximately 35.7 kgf; displayed maximum rounded up |
| Body-weight screen | 700 N | Approximately the owner's entire static weight rounded up |
| Transient sensitivity | 1,400 N | Twice the body-weight screen; a declared dynamic sensitivity |

The factor of two has a limited mechanical interpretation: a dead load applied
suddenly to an initially unloaded, ideal undamped linear spring produces twice
its static deflection and reaction. It is not an upper bound on a human stomp.
For a dropped weight W from height h, the same ideal model gives
`F_max/W = 1 + sqrt(1 + 2*h/delta_static)`, so even that model exceeds two when
there is drop energy. The human leg's effective moving mass and damping are
unknown. A 700 N result can establish the selected static case; it cannot alone
be labelled a universal stomp rating. Do not multiply 1,400 N by a second
dynamic factor while describing it as the same case.

The current pedal envelope is 76.35 mm across and 109.87 mm front to rear.
Include centered loads and eccentric resultants at horizontal offsets
`(du,dv) = (±30,0), (0,±45), (±30,±45)` mm from the pedal center. All those
centroids lie within the case envelope. Use a finite loading patch or the
pedal's own load-spreading stiffness; a single constrained node creates an
artificial local stress singularity. A 0.2*P horizontal force at the pedal top
may be used as a separately labelled oblique-foot sensitivity, but 0.2 is an
assumed scenario, not a measured friction coefficient or standardized load.

## Actual geometry and support path

Source: `hardware/enclosure/segno_enclosure.py`, current worktree. The base
schedule is 846 ×419 mm between nominal fold stations. In the native assembled
frame its floor underside is z = 0 and its floor top is z = 2 mm. In the local
formed-base STEP frame the floor top is z = 0. Never apply the 2 mm transform
twice.

The 15 foot centers, in base (u,v) millimeters, are:

| Group | Coordinates |
|---|---|
| Four original corners | (14.3,45), (14.3,374), (831.7,45), (831.7,374) |
| Four front pairs | u = 119.571429, 321.857143, 524.142857, 726.428571; v = 66.198026 |
| Four rear pairs | same four u; v = 374 |
| CLEAR/BANK support | (321.857143,229.968960) |
| Two intermediate supports | (625.285714,131.440), (726.428571,131.440) |

The modelled purchased foot is rubber, 5 mm high, Ø18 mm at the chassis and
Ø15 mm at the floor, with a metal washer insert and an M4 retaining screw. The
source does not specify rubber hardness, compression stiffness, maximum force,
or manufacturing height tolerance. The metal-base contact patch is Ø18 mm,
not Ø15 mm. The retaining screw is not the principal path for a downward load:
the metal bears on the rubber foot, which bears on the floor.

There are eight front pedals at u = 69, 170.142857, 271.285714, 372.428571,
473.571429, 574.714286, 675.857143, 777 mm and v = 66.198026 mm. CLEAR and BANK
are at u = 271.285714 and 372.428571 mm, v = 229.968960 mm. Their vertical load
path is pedal case → printed sled → printed deck and columns/walls → metal
floor → rubber feet → floor. The faceplate is not directly under the pedal's
base and should not be made an artificial ground restraint.

The low front collar has broad floor contact. The tall collar has a hollow
underside: its nominal contact is a 3 mm perimeter wall around 118.47 ×88.75 mm
plus four Ø12 mm columns, with four Ø4.5 mm bottom insert pockets. That simple
section calculation gives 1,596.092 mm² contact area. Loading the full tall
collar rectangle as if its hollow center touched the floor adds a false load
path. The actual partition of reactions between perimeter and columns depends
on printed stiffness and contact; uniform contact pressure is only a modelling
scenario. A columns-only reaction case is another sensitivity, not the exact
physical distribution. The separate PETG assessment covers that local path.

## Ground boundary conditions and lift-off

Support reactions must act only in compression. A foot resting on the floor
cannot pull the enclosure downward. Fixing every foot's vertical displacement
without checking reaction signs can falsely hold down unloaded corners and
overstate stiffness. The initial all-feet solution is acceptable as a screening
scenario only if its tensile reactions are reported and the limitation remains
explicit; it is not automatically the final contact solution.

Use distributed foot contact areas with free rotation, or compression-only
springs/contact coupled to those patches. Constrain only enough in-plane
degrees of freedom to remove rigid-body modes. Do not clamp all three
translations across each entire foot patch unless that deliberately optimistic
condition is identified as such. Foot friction is unknown.

Useful support sensitivities, in priority order:

1. All feet level and in contact, then compression-only active contact with
   separation allowed and the assembly's gravity included.
2. Remove the central CLEAR/BANK foot or the front pair foot at
   (321.857143,66.198026). Losing that front support leaves 404.571 mm between
   its neighboring front supports. Test the load position that depends on the
   removed support rather than a remote pedal.
3. Compliant vertical foot springs, for example 25, 100 and 400 N/mm per foot,
   as intentionally broad assumed scenarios. They are not claimed measured
   properties of the purchased rubber feet.
4. A selected foot initially 0.3 mm short, if contact gaps are implemented.
   This is a sensitivity to height/flatness error, not a declared tolerance.

Assembly weight should come from the current parts or a clearly stated
estimate. It affects which feet are seated. Equal load sharing among 15 feet is
not justified by their count. Absolute downward movement includes rubber
compression and rigid-body motion; fit assessment needs relative movement of
the pedal/platform, lid, and nearby electronics. The nominal base-to-ground
clearance is only 5 mm. Predictions approaching it require additional floor
contact rather than extrapolating an unbounded linear deflection.

## Folded walls, lid, corners, and ties

Keep the continuous base bends: they give the walls a real structural path to
the floor. The removable lid can redistribute load through its 18 screws and
seated edges, but it does not ground the enclosure. The front lip has nine
fitted shim packs; the rear lap has nine screws. The sides locate without
screws. Rear corner brackets are riveted; the two front corner seams are plain
relieved joints. Do not bond open corner lines or all lid edges.

A model with ideal no-slip bolt patches and ideal corner ties is useful as an
optimistic joint case. A model without lid contribution is a separate
sensitivity. Removing a component generally lowers global stiffness but does
not provide a rigorous upper bound on every local stress, because load paths
redistribute. If an optimistic ideal-joint model already fails, that is strong
evidence against release. Passing it alone does not establish the actual
slipping, clearanced joints.

The actual 18 lid/base axes were independently extracted from the current
formed STEP files and their manifest placements, using circular bore surfaces.
Both rows share these u stations:
18.428571, 119.571429, 220.714286, 321.857143, 423,
524.142857, 625.285714, 726.428571, 827.571429 mm.

| Row | Base-bore midpoint (v,z), base-local frame | Lid outer face (v,z), base-local frame | Outward axis |
|---|---|---|---|
| Front | (-0.910841,4.455420) | (-4.410842,4.455147) | (0,-1,0) |
| Rear | (406.412230,91.501655) | (407.653635,94.232480) | (0,0.413803,0.910366) |

Add 2 mm to all tabulated z values for the assembled floor-bottom world frame.
The largest radial mismatch between extracted mating bore axes is 0.000273 mm,
from the documented native modelling rounding. Couplings should follow these
local joint patches, without rigidly connecting an entire flange to a single
point. The calculation must also inspect the resulting joint forces; ideal
ties do not establish the capacity of the short aluminum threads, rivets, or
insert retention.

## Acceptance and communication

For each selected force and eccentric position, report the converged stress,
its location, `95/stress` and `127/stress` yield ratios, and relevant relative
displacement. A minimum ratio of one only marks calculated onset of permanent
set in the selected model. A target ratio of 1.5 is a reasonable explicit
engineering screening margin for this task, corresponding to 63.3 MPa at
95 MPa proof strength; it is our chosen margin, not an asserted applicable
pedal-enclosure standard. Do not silently change criteria after seeing results.

A 1 mm elastic movement target can be stated as a proposed stiffness/feel
target. Exceeding it alone does not prove fracture. Actual aperture clearances,
screen clearance, screw engagement and possible contact determine functional
limits. The unladen 0.18 mm baffle/faceplate spacing must not be treated as a
universal allowable downward deflection: its direction and the two parts'
relative motions matter.

Quadratic solid elements need bending and thickness convergence checks. Report
whether stresses come from integration points, extrapolated nodes, or averaged
nodes. A diverging peak beside an idealized point constraint or sharp contact
edge is not by itself a physically proven yielding location. Check mesh
convergence away from those singularities and check force/moment equilibrium.
If linear deflections are comparable to sheet thickness, or predicted stress
exceeds yield, qualify that result as a trigger for nonlinear/contact analysis,
not an accurate final deformed shape.

A static pass is not a fatigue-life demonstration. No measured duty cycle,
printed-part fatigue data, bolt preload, or actual stomp time history is
available. Nevertheless the calculation can give a useful decision: identify
the highest analysed load with margin and the first limiting component. If
the chosen one-pedal design case fails, recommend the necessary reinforcement
without delaying that conclusion for unrelated material confirmations.
