<!-- cspell:words soldermask centerlines nonplated overmolds -->
# Native layout and manufacturing review

Reviewed the three native boards and the published fabrication packages at `d32bca8b24c543b907ee1f104ebf8b04f6fa6947`, then corrected the verified silkscreen defects. Electrical geometry was not changed. The final native hashes and exact preservation evidence are in `silk-invariants.json`; the final fabrication ZIPs must be regenerated against those hashes.

## Result

No copper, drilling, footprint placement, net mapping, layer-count or outline defect was found in this bounded review. The original silkscreen did violate the manufacturer's current minima. That finding was fixed on all three routed boards and both saved placed boards, with source updates and stricter validation.

This is a fabrication and native-layout review. It does not certify an assembled enclosure fit: the screen board's final mounting holes and mated harness envelopes are not integrated into the enclosure model. Its documented mounting position remains a proposal. The distinction is retained in the assembly documentation.

## Verified manufacture contract

The current [JLCPCB capability table](https://jlcpcb.com/capabilities/pcb-capabilities) lists 0.15 mm minimum legend line width, 1.0 mm minimum text height and 0.15 mm pad-to-silkscreen distance. The native ink was checked against the resolved soldermask opening rather than relying only on the default DRC silk checks.

All three boards use two copper layers, 1.6 mm finished thickness and nominal 35 µm external copper. The screen board is 68 × 76 mm, the console 99.5 × 99.5 mm, and the ring approximately 80 mm diameter. Their edge profiles remain unchanged.

| Native measurement | Screen | Console | Ring |
|---|---:|---:|---:|
| Narrowest track, mm | 0.25 | 0.40 | 0.30 |
| Smallest different-net copper gap F / B, mm | 0.19086 / 0.16000 | 0.22475 / 0.20326 | 0.24355 / 0.22607 |
| Minimum copper-to-outline, mm | 0.50050 | 0.49857 | 0.54764 |
| Minimum PTH annulus, mm | 0.250 | 0.275 | 0.24999 |
| Minimum via annulus, mm | 0.200 | 0.200 | 0.200 |
| Minimum separate pad-mask web, mm | 0.350 | 0.740 | 0.540 |
| Final minimum actual ink-to-mask gap, mm | 0.15874 | 0.16500 | 0.15871 |

Copper measurements use boolean unions of actual native tracks, pads and filled zones, with 1 µm polygon approximation. The console's 0.49857 mm edge result includes that approximation around the rounded outline; fresh native DRC accepts the configured edge rule. All measured clearances exceed the relevant JLCPCB capability minima. The 0.16 mm screen USB pair gap is intentional.

Minimum drilled-edge distances between PTH component holes are 1.142 / 1.021 / 1.242 mm. The smallest distances involving vias are 0.442 / 0.600 / 0.307 mm. Pad annuli meet the 0.25 mm preferred two-layer target within native polygon rounding; via annuli are 0.20 mm.

Fresh all-severity native DRC reports zero violations and zero unconnected items for each board. No DRC exclusion was introduced by this work. Native connected-pad mappings agree with the saved source netlists: screen 115, console 206, ring 63 connected pads. Independent high-current guards separately pass for all three boards.

## Silkscreen correction

Existing useful labels were retained; no new text was added. Visible text is at least 1.0 mm high and 0.15 mm stroked, with existing heavier strokes retained. Existing outline strokes below 0.15 mm were widened. Filled vector artwork with zero outline width remains filled artwork.

A small native helper trims straight footprint outline/hatch centerlines around their own soldermask openings with a 0.16 mm target gap and round stroke caps. It changes neither copper nor pads. The independent mask checker examines actual ink of all shapes and visible text against every pad on that face, including neighboring footprints and non-straight graphics. The checker is enforced by the screen validation, console generation/export and ring export paths.

The screen references needing more room were repositioned explicitly. The console keeps all 66 existing reference positions rather than allowing the larger text to reflow. Existing body/courtyard-overlap checks remain active. A single back artwork divider moves down 0.2 mm to clear C20's mask openings. Ring J2's four pin labels move down 0.35 mm; ENC 1 moves to the clear right-hand position, and the decorative circular encoder outline crossing its mounting opening is removed. The encoder body and shaft/key outline remain visible.

Final native plots were inspected. Text is legible and the clipped outlines retain pin-one, diode and capacitor polarity indications. The screen's relay outline now has proper clearance from its corner pads. All three boards' actual ink checks pass independently of the native DRC implementation.

Exact parsed S-expression comparisons against the frozen pre-fix files confirm that every item outside F/B silkscreen is unchanged, including tracks, vias, filled polygons, keepouts, pad shapes/drills/net assignments, footprint positions/orientations, model placements, mounting holes, edge cuts and stackup. This comparison also covers both saved placed boards.

## Mechanical and assembly checks

The screen board has models for all 44 populated parts; its four NPTH mounting holes intentionally have no component model. The console's populated components have models and courtyards. The ring's wire/module mounting pads intentionally have no body model; RING1 represents the optional ring module. The XIAO module is the documented hand-soldered castellated module.

The screen DIP packages remain on the common pin rows y=11.63 and 19.25 mm. Maximum specified body envelopes for U1 (10.16 × 6.60 mm) and U2 (4.83 × 6.65 mm) leave 0.965 mm between bodies; their stock courtyard clearances to C3 and Q4 are 0.1525 and 0.140 mm respectively, without overlap. The surrounding capacitors were checked using maximum specified body diameters and heights, including 5.5 ×12 mm for C3/C4.

Lead-to-hole checks use the JLCPCB minimum finished bore (nominal minus 0.08 mm) and maximum purchased lead dimensions. Examples: screen VH 1.8 mm drill leaves 1.72 mm for the 1.14 mm square post's 1.612 mm diagonal; selected TO-220 1.4 mm holes leave 1.32 mm for an approximately 1.18 mm maximum lead diagonal. The relay 0.9 mm holes exceed TE's 0.75 mm recommended drill even after tolerance. The console's 1.25 mm IDC/expansion holes leave 1.17 mm for the specified 0.79 mm square post's 1.117 mm diagonal. The selected DIP, capacitor, fuse and resistor lead diameters fit their documented drills.

Screen connector orientation, pin-one identification and corresponding channel wiring are consistent. Header/latch access remains open on the PCB itself. Maximum mated XH height is 9.8 mm; enclosure clearance for actual cable overmolds still belongs to the enclosure fit contract. Both TO-220 tabs remain electrically live on distinct drain nets; they cannot share an uninsulated heatsink. Thermal adequacy is covered by the separate component/current review.

The screen's mounting rule areas retain their 4.25 mm keepout radius for up to 7 mm screw heads/washers. The closest non-ground copper gap beyond a 7 mm washer envelope is 1.75 mm at H4. Console mounting holes intentionally distinguish the bonded ground hole from isolated chassis holes; the screen's 7 mm washer allowance must not be generalized to those console holes.

## Copper and package inspection

All six copper faces were rendered from actual filled native unions and inspected. Broad power routes keep their documented widths and rounded transitions; USB routes and their ground references are unchanged. No new narrow copper neck, same-net slot, acute residual ground tip or undocumented layer handoff was found. Minimum high-current path widths are checked without crediting zones or vias as an accidental substitute for the intended tracks.

The pre-fix published packages matched their native and source hashes and contained the intended two copper layers, mask, silk, outline and drill files. The current silkscreen edits invalidate those package hashes; the final publication step must refresh them and repeat package/source hash checks. The manufacturing assessment above remains valid because electrical and mechanical geometry was preserved exactly.

## Independent replay closure

A separate reviewer confirmed all three non-silk native invariants and all eight edited custom-footprint non-silk invariants. Screen `pcb.py` plus `finish.py` replay matches printed labels and outline ink; the observed 12–21 nm translation on C2/C102/C202 is existing serialization noise. Q3 now matches exactly. Hidden mounting-hole reference sizes are an unprinted difference. No source/native discrepancy requiring a change remains.

The exact final console generator (`ef4fa0ac661d9a22b2a06eeeea0ad09f1e89effa6fba9c332aa8aba8958e6084`) passed all 15 existing negative controls and its routed-board fabrication guard, both exit 0. The new ink-mask gate runs after the pre-existing placement/circuit gates so each fault control retains its intended diagnostic.
