<!-- cspell:words millimetres -->
<!-- cspell:words WIMA KSSD Yageo -->
<!-- cspell:words CadQuery onsemi Littelfuse EEUFR SUP VHR MKS heatsink -->
# Screen-power assembly audit

Reviewed 25 September 2026. Baseline: commit `9a5798be`, Revision J native
board SHA-256 `037d462c64196cca1d697975325be9b979a5360783949ed89c62c441ebef3032`.
The baseline findings below record the assembly/mechanical input to Revision K.
The final closure section identifies the exact regenerated files subsequently
reviewed; no later files are approved by this report.

## Outcome

The baseline had one confirmed issue in the assembly deliverables: the three
electrolytic capacitor models substantially understate the selected parts'
height. No wrong hole size, confirmed component collision, surface-mount part,
or new pin-orientation error was found in this scope. The bare board remains
hand-solderable. The electrical audit and final source-to-Gerber review are
separate gates.

The baseline mating VH housing near C1 needed a more conservative CAD allowance or a
specific mating-part geometry check. Its projected envelope overlaps C1, but
the present evidence does not prove that the actual plastic solids collide.
No new owner measurement or component purchase is required by this audit.
Both the model issue and conservative C1 allowance are resolved in the final
Revision K geometry inspected below.

## Confirmed model issue

`models/CP_Radial_D6.3mm_P2.50mm.step` ends at z=6.3 mm above the seating
plane; the selected C2, Panasonic EEUFR1A221, has an 11.2 mm nominal body.
`models/CP_Radial_D5.0mm_P2.00mm.step` ends at z=5.0 mm; C102 and C202,
EEUFR1A151, have 11.0 mm nominal bodies. The native assignments have unit
scale and no offset. The images therefore conceal 4.9–6.0 mm of component
height. Correct those models and regenerate the assembly STEP and previews.

Panasonic permits diameter +0.5 mm and length ±1.5 mm for these sizes.
Conservative cylinders of diameter 6.8 × height 12.7 mm for C2 and diameter
5.5 × height 12.5 mm for C102/C202 were placed at the native footprint
positions. They do not collide with nearby modeled parts. C2 has about
2.89 mm clearance to Q3 and 1.70 mm to F101. C102/C202 have about 3.86 mm
clearance to their neighboring XH header. These are solid-distance checks
against the existing nominal models, not a complete tolerance analysis.
[Panasonic FR-A dimensions and exact part rows](https://industrial.panasonic.com/cdbs/www-data/pdf/RDF0000/ABA0000C1259.pdf).

The generic WIMA STEP is also not the exact body: it reaches 9.0 mm rather
than the selected 6.5 mm nominal height. This overstates the obstacle, unlike
the electrolytics, but should be distinguished from an exact model. The
7.2 × 2.5 mm footprint and 5.0 mm lead pitch match MKS2C031001A00KSSD.
[WIMA MKS 2 catalogue](https://www.wima.de/wp-content/uploads/media/WIMA_Main_Catalogue_2026.pdf).

## Lead holes and footprints

All 37 populated parts have through-hole pads and a bundled model. Four
additional footprints are unplated M3 mounting holes. The values below were
read from the baseline native board, not inferred from its library names.
The minimum PTH diameter uses the published −0.08 mm manufacturing tolerance.

| Parts | Native hole / minimum, mm | Mechanical comparison |
| --- | --- | --- |
| Q3/Q4 SUP70101EL | 1.40 / 1.32 | Maximum 1.01 × 0.61 mm rectangular lead has a 1.180 mm diagonal; 0.14 mm diametric insertion margin remains. Nominal pad annulus is at least 0.2525 mm. |
| J1/J103/J203 JST VH | 1.80 / 1.72 | Exceeds JST's 1.65 mm minimum reference hole. 3.96 mm pitch matches. |
| J2 JST XH two-position | 1.10 / 1.02 | Meets JST's 1.00 mm minimum reference hole for the two-position header. |
| Four XH USB headers | 1.10 / 1.02 | Exceeds JST's 0.90 mm reference minimum; 2.50 mm pitch matches. |
| K101/K201 IM02TS | 0.90 / 0.82 | Exceeds the TE 0.75 mm reference mounting hole; 5.08 mm row spacing and 3.2/2.2/2.2 mm longitudinal spacing match. |
| Four TO-92 transistors | 0.95 / 0.87 | The onsemi rectangular lead envelope is accommodated; the 2N7000 maximum 0.56 × 0.52 mm diagonal is 0.764 mm. Outer leads must be formed from the package pitch to the board's 2.54 mm pitch. |
| Four axial fuses | 1.00 / 0.92 | 0.64 mm nominal leads and 7.11 × diameter 2.8 mm maximum body fit the 12.7 mm formed pitch. |
| R1–R7 | 0.80 / 0.72 | Yageo MFR-25 maximum lead diameter 0.60 mm fits; the maximum 6.8 × diameter 2.6 mm body fits the available placement. |
| R8 | 0.80 / 0.72 | Vishay PR01 maximum 0.63 mm lead fits; 6.5 mm body / 8.0 mm coating-length maximum fits 10.16 mm formed pitch. |
| Three electrolytics | 0.80 / 0.72 | Maximum 0.55 mm round leads fit; 2.5 mm C2 and 2.0 mm C102/C202 pitch are correct. |
| Three WIMA film capacitors | 0.75 / 0.67 | Published nominal 0.50 mm leads and 5.0 mm pitch fit; the MKS 2 outline does not state a diameter tolerance. |
| D1 1N4148 | 0.80 / 0.72 | Maximum 0.55 mm lead and 3.4 mm body fit 7.62 mm pitch. |
| D101/D201 1N4007 | 1.10 / 1.02 | Maximum 0.86 mm lead and 5.2 × diameter 2.7 mm body fit 10.16 mm pitch. |
| H1–H4 | 3.50 NPTH | Retained 60 × 68 mm mounting pattern; the documented conservative ±0.20 mm allowance still leaves 3.30 mm for M3 clearance. |

Primary drawings: [Vishay TO-220AB](https://www.vishay.com/docs/71195/to220ab.pdf),
[JST XH](https://www.jst-mfg.com/product/pdf/eng/eXH.pdf),
[JST VH](https://www.jst-mfg.com/product/pdf/eng/eVH.pdf),
[TE IM Series, page 5](https://www.farnell.com/datasheets/477186.pdf),
[onsemi 2N7000](https://www.onsemi.com/download/data-sheet/pdf/nds7002a-d.pdf),
[2N3904](https://www.onsemi.com/download/data-sheet/pdf/2n3904-d.pdf),
[2N3906](https://www.onsemi.com/download/data-sheet/pdf/2n3906-d.pdf),
[Littelfuse 251](https://www.littelfuse.com/assetdocs/fuse-251-datasheet?assetguid=f47a0bb7-8ede-4679-9646-7114c3787688),
[Yageo MFR](https://yageogroup.com/content/datasheet/asset/file/YAGEO-MFR_DATASHEET),
[Vishay PR01](https://www.vishay.com/docs/28729/pr010203.pdf),
[1N4148](https://www.vishay.com/docs/81857/1n4148.pdf),
[1N4007](https://www.vishay.com/docs/88503/1n4001.pdf), and
[JLCPCB hole tolerances](https://jlcpcb.com/capabilities/pcb-capabilities).

## Orientation, clearance and soldering

All eight headers are rotated 90 degrees in the native board: their pin-1
ends and retaining sides agree. VH is the standard B2P-VH header with a
retaining wall, not the different fully shrouded B2P-VH-FB-B part. The XH
headers are shrouded. The matching housings are listed in the external BOM.

Electrolytic pin 1 is the positive rail, pin 2 is ground; the native polarized
footprint marks agree. The axial diode cathodes use pin 1 and the footprint
band end. The MOSFET G/D/S and small-transistor E/B/C or S/G/D mappings agree
with the specified parts. Q3 and Q4 intentionally face opposite directions;
their tabs are different live drain nets, not a common heatsink attachment.
They must remain isolated from each other and metal hardware. No optional
heatsink is specified or qualified. The reviewed upright bodies have
approximately 2.75 mm separation in the nominal assembly models.

The component bodies and terminals remain on the top face, so an assembler
can reach all solder joints from the bottom before mounting the board.
The 2.2 mm minimum relay-terminal pitch has 1.4 mm pads, leaving 0.8 mm
nominal pad-to-pad space. The ground fills use thermal reliefs. Broad power
copper will require a suitable iron tip and controlled dwell, especially
near the axial fuses; the existing fuse soldering-temperature/time limit
remains applicable. There is no fine-pitch surface-mount soldering operation.

Both faces retain 4.25 mm mounting-hardware copper keepouts for M3 fasteners
with a maximum 7 mm head/washer diameter. Do not replace these with larger
metal washers. These keepouts account for bolt eccentricity; bare drill
clearance alone would not protect surrounding copper.

## Mating plugs and enclosure limits

Bare-header courtyards do not include every mating part. JST gives a mated
VH depth of 10.5 mm and height of 16.5 mm. The supplied bare-header model is
8.5 mm deep and 10.9 mm high. The extra latch-side projection approaches C1
beside J1/J103; their projected envelopes overlap. The actual protrusion is
height-dependent, so a full-height box cannot establish a real collision.
The exact nominal film capacitor is only 6.5 mm high. No measured or
vendor-solid latch-fit clearance is established by the current board STEP.

A conservative CAD option is to move C1 from x=50 to x=48.5 mm, preserving
y and rotation: that separates it by about 0.55 mm from the complete mated
VH projection and by about 0.78 mm from the maximum-diameter C2 envelope.
This eliminates uncertainty; it is not evidence that the original solids
necessarily collided. The author accepted this move together with corrected
capacitor models for Revision K. Those changes require routing, clearance and
assembly rechecks after generation. No such change was made by this reviewer.

The proposed replacement model names are
`CP_Radial_Panasonic_EEUFR1A221.step`,
`CP_Radial_Panasonic_EEUFR1A151.step`, and
`C_Rect_WIMA_MKS2C031001A00KSSD.step`. Their respective body centers relative
to pin 1 are (1.25, 0), (1.0, 0), and (2.5, 0) mm, with positive/first lead
at (0, 0). Panasonic's stock leads are at least 14 mm for negative and
17 mm for positive; an assembled model should explicitly identify trimmed
lead length instead of presenting shortened leads as untouched stock.
The WIMA SD suffix specifies stock leads 6−2 mm long. Unit model scale and
zero additional translation/rotation preserve the native footprint mapping.

The [documented enclosure location](../../pcb-completion-1072/screen-power-placement.md)
is the floor behind CLEAR, left of the buck converters, on 15 mm standoffs.
All seven recorded enclosure-source/obstacle hashes still match the reviewed
checkout. The board and STEP hashes have changed since that placement study,
so its numbers are historical, not a fresh Revision K integration result.
The board outline and footprint placement of this baseline are retained.
Corrected capacitor heights remain below the existing upright MOSFET envelope.
Cable bends, actual connector unlatching access, and live Fusion placement
remain unverified. The four enclosure floor mounts are explicitly not yet
implemented; this is an enclosure-integration task, not a reason to change
the PCB outline or block bare-board fabrication.

## Manufacturing and readiness scope

The native board has two copper layers, nominal 1.6 mm FR-4, 35 µm copper
per face, purple mask, white silkscreen and ENIG. These options are within
JLCPCB's published capabilities. No stencil or factory assembly is required.
No extra component, expensive module, or heatsink follows from this audit.

This review does not refresh component prices or availability, approve
substitutes, guarantee assembled thermal/USB behavior, or approve future
Gerbers. It inspects CAD and primary mechanical drawings. No repository file
other than this report was edited. Final Revision K artifacts must receive
their own source/hash, drill, layer, outline and archive-content checks.

## Revision K assembly recheck

The first completed Revision K export, native SHA-256
`0a48bfad57602856e0b1558a10f9856250cba5859e3e14df5796b197419b1813`,
was independently inspected after generation. The only changed footprint
position is C1: x50.0 to x48.5 mm, with its original y and 90-degree rotation.
All footprint pad numbers, nets, drill diameters and pad dimensions are
unchanged. The six capacitor instances use the intended three new model
files at unit scale, with zero added rotation or translation.

Reading the actual replacement STEP solids confirms the nominal bodies:
C2 diameter 6.3 / height 11.2 mm, C102/C202 diameter 5.0 / height 11.0 mm,
and C1/C101/C201 dimensions 7.2 × 2.5 × 6.5 mm. All six have explicitly
documented 3 mm assembled lead projections. The maximum-diameter C2
envelope clears C1 by 0.7824 mm. Conservative full-height boxes using the
published mated VH outline clear C1 by **0.55 mm** at both J1 and J103, with
zero intersection. This corrects the earlier informal 1.05 mm estimate;
the measured 0.55 mm value is authoritative.

The exported complete assembly STEP parses successfully, with bounds
x0–68, y−76–0, z−8.135–20.39 mm. The corrected capacitors remain below the
upright MOSFETs. Top and perspective renders show all populated parts,
the moved C1, corrected capacitor heights and Revision K marking.

The first export still hid the electrolytic polarity-stripe solid inside
the sleeve. The author corrected the source to expose a colored region
of the same cylindrical surface by intersection/subtraction. This was a preview
detail; the native capacitor '+' markings and pin map remained correct.

## Final Revision K closure

Final native SHA-256:
`d35484d551cf8f526f62c4356accbff0492c28999beb0e8830801c39f00c83da`.
Final assembly STEP SHA-256:
`ed7815e645446e8dfe00efe435876a63f88e58841f4923cf238e5fb38817758f`.

The final native board again compares identically to the baseline for every
footprint rotation, pad number, net, size and drill; C1's 1.5 mm move is the
only placement change. The actual replacement filenames are
`Panasonic_EEUFR1A221.step`, `Panasonic_EEUFR1A151.step` and
`WIMA_MKS2C031001A00KSSD.step`, all assigned at unit scale and zero offsets.
The two-layer count and 1.6 mm thickness are unchanged.

The final replacement STEP solids retain the correct nominal body dimensions.
Both Panasonic stripes now reach the outside cylindrical surface, with exposed
cylindrical face areas of approximately 5.41 and 5.31 square millimetres;
the sleeve subtraction prevents coincident hidden geometry. The assembly's
default perspective faces away from the negative-side stripe, so this closure
uses the actual STEP surfaces rather than claiming it is visible in that view.
The final top and perspective renders were inspected for populated parts,
corrected capacitor heights, orientation and the Revision K marking.

Repeated solid-distance checks give **0.55 mm** clearance from C1 to the
complete mated VH boxes at J1 and J103, and **0.7824 mm** from C1 to the
maximum-diameter C2 envelope; all three intersection volumes are zero.
The exported assembly parses as 103 solids, retaining x0–68, y−76–0 and
z−8.135–20.39 mm bounds. The corrected capacitors stay below the MOSFET tops.

All 59 source hashes and 64 artifact hashes in the final fabrication manifest
match their files. All 12 Gerber ZIP members equal the corresponding loose
exports. The final package's generated validation records zero ERC/DRC
findings and 36/36 passing fault checks. These observed local results are
distinct from assembled electrical or USB qualification.

The confirmed model defect and conservative mating-clearance improvement are
closed at this exact artifact checkpoint. No unresolved assembly finding was
identified. No enclosure floor mounts were added or validated by this PCB
review; the enclosure and physical harness limits stated above remain.
