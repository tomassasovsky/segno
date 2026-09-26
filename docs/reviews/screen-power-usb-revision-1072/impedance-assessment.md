# Two-layer USB impedance assessment

Date: 26 September 2026. Baseline: `355882d848477537cb491b8ab9180123eb7f8971`.
This review concerns the screen-power board's USB copper. It does not release
the board, qualify the purchased cables, or resolve the separate USB suspend
current defect. No PCB, placement, routing or generator was changed by this
assessment.

## Recommendation

Change the coupled USB sections from **0.85 mm width / 0.16 mm gap** to
**0.78 mm width / 0.23 mm gap**, preserving the **1.01 mm center spacing**,
existing centerlines, no-via routing and protected reference ground. Have the
layout author make and verify this bounded change. Retain two layers, 1.6 mm
FR4 and 1 oz copper.

The reason is electrical: a coated cross-section model places the original
geometry near **80 ohms**, whereas the proposed geometry converges near
**90.8 ohms**. The earlier 89.64-ohm figure was an uncoated analytical estimate.
The proposed change improves nominal centering and increases the manufacturing
gap; it does not buy an impedance guarantee or prove an assembled USB link.

## Supplier information and its limits

[JLCPCB capabilities](https://jlcpcb.com/capabilities/pcb-capabilities) publish
these ordinary two-layer parameters:

| Parameter | Published information |
| --- | --- |
| FR4 relative permittivity | 4.5 for two layers |
| Finished 1.6 mm board thickness | ±10%, or 1.44–1.76 mm |
| Track width tolerance | ±20% |
| One-ounce minimum design width/gap | 0.10/0.10 mm |
| Controlled impedance | Listed for 4–32 layers, not the selected two-layer service |

These do not provide a bounded two-layer dielectric-constant tolerance,
correlated finished width/gap tolerance, or purple-mask thickness tolerance.
A manufacturing remark alone is not evidence that JLC accepts tighter limits.
No published tighter two-layer service was found; explicit supplier acceptance
would be needed before promising one.

JLC's [impedance-model parameters](https://jlcpcb.com/impedance) use mask
permittivity **3.8**, **30.48 µm** coating above substrate/between traces and
**15.24 µm** above copper. These are useful nominal inputs, but that page
covers multilayer controlled-impedance construction. It does not warrant the
same precise profile on this two-layer purple order. Its
[laminate guide](https://jlcpcb.com/help/article/multi-layer-pcb-standard-laminated-structures)
also lists **40.64 µm** finished outer copper for its one-ounce impedance model;
that value is included as a sensitivity case alongside the board's 35 µm.

[Polar's coating guidance](https://www.polarinstruments.com/support/cits/AP169.html)
explains that mask profile, especially material between a tightly coupled pair,
changes differential impedance; increasing that fill lowers impedance. A single
mask-thickness entry in KiCad does not model this cross-section fully.

## Calculation and independent controls

The [reproducible model](impedance-model.py) uses **scikit-fem 12.0.1** and
**SciPy 1.16.2** to solve the two-dimensional electrostatic equation. It follows
the established finite-element capacitance method documented in
[Femwell's capacitor example](https://helgegehring.github.io/femwell/electronics/examples/capacitor.html):
capacitance follows from electric-field energy at a specified voltage.

The symmetric half-section has a 0 V odd-mode symmetry boundary midway between
the conductors, one conductor at 1 V, and a continuous reference plane. Copper
is rectangular, with 1.53 mm substrate height, relative permittivity 4.5,
35 µm copper, and the nominal mask profile above. A separate vacuum solve gives
`C0`. Differential impedance is `2 / (c * sqrt(C * C0))`; the capacitances are
per unit length. This is a quasi-static straight-section model, without loss,
weave anisotropy, frequency-dependent material data or a 3D connector model.

| Geometry | Uncoated FEM estimate | Coated FEM estimate |
| --- | ---: | ---: |
| Existing 0.85/0.16 mm | 83.48 Ω | 79.44 Ω |
| Intermediate 0.80/0.21 mm | 91.39 Ω | 87.52 Ω |
| Proposed 0.78/0.23 mm | 94.36 Ω | 90.53 Ω |

Those comparable rows use the same 29,876-node mesh. Refinement of the proposed
coated section gives **90.760 Ω at 117,040 nodes** and **90.818 Ω at 261,504
nodes**. The last refinement changes the result by 0.058 Ω. The original
coated section reaches 79.682 Ω at 117,040 nodes.

Additional controls:

- Doubling the remote boundary from 6 to 12 mm changes the proposed result
  by 0.034 Ω at the middle mesh density.
- Adding same-face ground beginning 5 mm from the pair midpoint changes it
  by 0.009 Ω. This represents the straight-run pour setback; it is not a model
  of the terminal regions.
- A two-dielectric parallel-plate control reproduces its exact analytical
  capacitance with relative error below `2e-15`.
- A separate reviewer checked the odd-mode boundary conditions, energy,
  capacitance-to-impedance conversion, material boundaries and unit scaling.
  They did not independently execute the solver.

The [KiCad 10.0.4 implementation](https://gitlab.com/kicad/code/kicad/-/blob/10.0.4/common/transline_calculations/coupled_microstrip.cpp)
was also compiled without changing its equations; the small
[driver](impedance-kicad-driver.cpp) accepts width, gap, height and copper
thickness in millimeters, followed by relative permittivity and frequency in
hertz. It reproduces **89.6448 Ω** at permittivity 4.4 and **88.8357 Ω** at 4.5.
Its reported `Z_DIFF` is twice the **static** odd-mode impedance, even when the
input frequency is 1 GHz. It omits coating and differs from the finite-element
cross-section; these estimates must not be presented as agreeing measurements.

An exploratory ATLC run was rejected as a decision basis after its independent
dual-dielectric coax control missed the analytical answer by about 5.4%.
It is not used to tune the proposed geometry.

## Sensitivity, not guaranteed production bounds

The [numerical evidence](impedance-evidence.json) records inputs and results.
All scenarios below use fixed 1.01 mm conductor-center spacing: wider etching
means a narrower gap, and vice versa. Independently varying width and gap as
though they were unrelated would give misleading corners.

| Proposed geometry sensitivity | Coated FEM result, base mesh |
| --- | ---: |
| 40.64 µm copper, otherwise nominal | 89.75 Ω |
| Half the nominal mask thicknesses | 92.23 Ω |
| 1.5 times the nominal mask thicknesses | 89.17 Ω |
| High-impedance engineering corner | 100.35 Ω |
| Low-impedance engineering corner | 81.54 Ω |

The engineering corners assume finished width **0.78 ±0.025 mm**, core
**1.37–1.69 mm**, permittivity **4.2–4.8**, copper **25–45 µm**, and mask
**50–150%** of the nominal model. These are deliberately stated sensitivity
inputs, **not supplier-promised bounds**. The approximate core range subtracts
two nominal copper layers from the published finished-board thickness range;
it is not a specified core tolerance. Rectangular width also does not fully
represent a trapezoidal etched cross-section.

The approximately 81.5–100.4 Ω modeled envelope fits a 90 Ω ±15% design target
under those assumptions. It does **not** prove the ordinary JLC service holds
that envelope. Applying the published −20% width allowance to the proposed
0.78 mm trace gives 0.624 mm width and 0.386 mm gap at unchanged centers; even
with the other parameters nominal, the modeled impedance exceeds the target.
The capability table alone therefore cannot guarantee USB impedance for either
geometry. Its minimum design spacing must not be mistaken for a guaranteed
finished-space lower bound.

## Complete-channel boundary and practical actions

The current native checks establish matched, continuous B.Cu data routes,
no data vias or stubs, correct polarity and filled F.Cu ground samples at
0.1 mm intervals. The **1.35 mm exclusions around through-hole terminals**
are real local reference-plane discontinuities; they are not an impedance
waiver or proof that return current is ideal there. The model above applies
to the coupled straight runs, not these transitions.

The two JST XH interfaces, widened terminal separation, plated barrels and
IM02TS contacts remain short 3D discontinuities. TE's
[IM02TS RF specifications](https://www.te.com/en/product-1-1462037-3.html)
are useful component data, but they do not qualify this balanced USB channel.
The seller's 28 AWG description does not establish cable pair impedance,
shielding, USB-C CC configuration or 480 Mbps performance. Relays, headers
and cables can dominate a small correction to the PCB's straight sections.

Proceed with the bounded 0.78/0.23 mm correction and retain the existing
terminal proximity and protected ground. Re-run the native USB graph,
width/gap/skew, reference-ground and complete DRC checks after the author's
change. Keep data pairs away from any new coil-drive routing.

A useful fabrication request is to ask the supplier to confirm the material,
finished copper and **finished pair geometry**, including whether width
0.78 ±0.025 mm at 1.01 mm center spacing can actually be held. Do not label
an unacknowledged request as an accepted controlled-impedance order. If an
impedance warranty is essential while retaining two layers, seek an explicit
90 Ω coupon/TDR quotation from another fabricator before altering the order.
[PCBWay](https://www.pcbway.com/pcb_prototype/impedance_calculator.html) offers
manufacturer-calculated stackups and asks customers to obtain their final
construction, but no verified affordable two-layer quote was obtained here.
The user’s JLC choice has not been changed.

The assembled large-screen hub must still enumerate and operate reliably at
480 Mbps; the small screen uses 12 Mbps. Functional operation is useful
qualification for this pedal, but the
[USB-IF electrical tests](https://www.usb.org/sites/default/files/USB2%20Electrical%20Compliance%20Specification%20v1.08.pdf)
measure signal quality and other properties that this cross-section study
cannot certify.

To reproduce the nominal matrix, install the two pinned analysis dependencies
in a disposable Python environment, then run `python impedance-model.py`.
`--mesh 2` or `--mesh 3` refines it, and `--domain 12` tests the remote boundary.
Additional corner inputs are explicitly stored in the evidence JSON and can
be passed to the script's `run` function. No project dependency is required.
