<!-- cspell:words centerlines fanout -->
# Revision M final layout and critical-routing review

## Result and reviewed revision

**No unresolved actionable finding in the reviewed layout/native-board scope.** The three Critical and one Important findings from the first Claude layout candidate are closed by the rebuilt native board and the evidence below. This supersedes the initial failed-candidate assessment; it does not imply that the first candidate passed.

Reviewed against merge base `5fd9f8bf6856673d07b27054d0b98dd7ba719561`, repository HEAD `00060494b9af330cb2fbe7834fe9bae04bac65c0` plus the final working delta. The reviewed implementation is Python/KiCad with through-hole assembly. The changed authoring files are `layout.py`, `route_critical.py` and the label-only changes to `finish.py`. The final native board was built with KiCad 10.0.4. No source or native CAD was changed by this reviewer; only this report was updated.

All paths in the following table are relative to `hardware/kicad/screen_power/`:

| Reviewed file | SHA-256 |
|---|---|
| `layout.py` | `a8cd83e901fbb763c6444726edbf2c2843e8eda4d50d9eab9d24146f84117ae7` |
| `route_critical.py` | `e029f27cd59704fa86d86eef495f7ee16d6489ce1911215f8b9bba2cf9f0e7b2` |
| `finish.py` | `bd04338e036e2b884da255e937ec48afb6f636a4770ffdac64084d4eeeaf12d0` |
| `check.py` | `b68482bb0bd5350531708bda32114d4c0f38c3f8074dbea83a5087ed01a5539d` |
| `hand/screen_power_hand.kicad_pcb` | `8a467b1c6a881cbf7dd117d38366cfda466f1a51c64553296cc374b4ca52cb27` |
| `hand/screen_power_hand.placed.kicad_pcb` | `1b2af801db5bf04bbf1e8a4c08fa80499fca9ce3560a6a82248285122a39ecdd` |
| `hand/screen_power_hand.kicad_pro` | `7c1d7d080c6be1d59b356208051249e8192af8b31a7946a435ef9cd95a7b2727` |
| `hand/screen_power_hand.net` | `03ba4273d19ed28c4ca6791daaccdcdc9ba6653379275ab499924a747203b801` |
| `validation.json` | `c7aa4a3c55ad94fce63e3c1b2651afad39f84f883576b77e062f49b023c5654b` |

The baseline native board used for geometric comparison has SHA-256 `b1e5dbb5c4a9eef5137f5dd339a685fe2ce0eac174362ba4df1bfdb6f668a123`. The review snapshot was copied before inspection, and inspected source/native hashes were checked again afterward to exclude changes during the comparison.

## Closure of the initial findings

| Initial finding | Final correction and verification | Status |
|---|---|---|
| New plated ground pads shorted retained power/control tracks and touched capacitor courtyards | TP101/201 moved to (13.5,31.5)/(13.5,56.5), TP102/202 to (51.47,32)/(51.47,57); R102 moved to center (37.9,55.6). Final pad/net parity, native DRC, courtyard checks and filled-ground connectivity pass. | Closed |
| Explicit AUX routes crossed HOST1/HOST2 and a ground via | Long low-current AUX, host and gate feeds now use the constrained router, while the local coil/stack links remain explicit. Final DRC reports no shorts/crossings, all new stage nets are physically connected, and USB reference sampling passes. | Closed |
| Channel-two divider/feed intruded into H3 fastener envelope | R201 moved to center (14.5,73.3), R202 to (27.2,73.5); regenerated feeds respect the retained fastener protection. Both native keepout checks and the independent mounting-clearance checker pass. | Closed |
| References collided with new parts, pads and labels | Component references and finish-stage connector/title labels were repositioned. Final C102/C202 references are (49,27.5)/(49,52.5). Native silk checks and the independent mask-clearance check pass; fresh top/bottom renders were inspected. | Closed |

The subsequent four bare-pad silk/mask violations are also closed. The generator removes only the F.SilkS decorative circle from TP101/102/201/202. Independent comparison with the candidate before this fix confirms that all four pad positions, 2 mm pad diameters, 1 mm drills, copper layer sets, 0.025 mm mask expansion on both faces and courtyard circles remain unchanged. No checking limit or fault control was weakened to accept the correction.

## Independent native and source inspection

### Anchors, outline and high-current copper

- All pre-existing footprint anchors and orientations match the baseline within 1 µm, including all eight connectors, four mounting holes, Q3/Q4, U1/U2 and the original passives. The U1/U2 pin rows remain aligned.
- All 350 non-USB copper segments of width at least 0.8 mm match the baseline in net, layer, width and endpoints within 1 µm. No power-run neck or unintended width change was introduced.
- The independent power checks pass after removing filled overlays and thin branches from in-memory copies: 2 mm input/main-output paths, 2.5 mm source bridge/distribution paths, 1.5 mm bulk and 0.8 mm film/touch feeds, uniform main-run widths and the three qualifying power vias. The dedicated transition still works without relying on the original fuse barrel.
- The native outline remains a closed 68 × 76 mm board with four R3 corners and exactly two copper layers. Both outer GND pours and approved overlays are filled. Existing mounting protection and connector orientation are retained.

### USB geometry and actual reference copper

All eight USB centerlines/layers match the baseline at 0.1 µm coordinate comparison precision. More strongly, the final USB segment coordinates, widths and layers exactly match the repaired critical-routing output, so router import, finishing and rounding did not alter them. Every USB segment is 0.78 mm wide on B.Cu, with no data vias. Each straight coupled section has 1.01 mm center pitch and 0.23 mm edge gap.

Independent Euclidean length sums on the final native segments:

| Segment, same result in both channels | P length | N length | Absolute skew |
|---|---:|---:|---:|
| Host to relay, UP | 23.526701625 mm | 23.526702576 mm | 0.000000951 mm |
| Relay to touch, DN | 26.178136398 mm | 26.178136398 mm | Below numerical precision |

The tiny UP difference is serialization/grid rounding, not deliberate length tuning. These are board-copper lengths; the relay and external cable paths are not included.

The independently rerun filled-reference check passes all **6,264** samples at 0.1 mm intervals along the centerline and both trace edges. It retains the existing 1.35 mm terminal exclusions only. Source inspection confirms the straight-section and fanout F.Cu track/via keepouts and the B.Cu pour exclusions are retained. New routing therefore does not break the checked opposite-face ground reference.

### New relay-stage pin maps and physical connectivity

Physical component/net parity and the independent circuit contract pass. For each lower Q101/Q201, source pin 1 is GND, gate pin 2 DATA_ENABLE and drain pin 3 the corresponding stack. Upper Q102/Q202 use source pin 1 on that stack, gate pin 2 on the host-presence divider and drain pin 3 on coil-low. Relay pin 1 is AUX_5V and pin 8 coil-low; flyback and contact mappings remain correct. The source now correctly describes the lower-drain to upper-source pad separation as about 4.4 mm.

Independent KiCad connectivity traversal reaches every physical terminal on each new net:

| Net | Terminals | Total routed length | Width | Vias |
|---|---|---:|---:|---:|
| HOST1_5V | J101.1, R101.1 | 19.237173 mm | 0.25 mm | 0 |
| S1_HOST_PRESENT | R101.2, R102.1, Q102.2 | 13.674925 mm | 0.25 mm | 0 |
| S1_RELAY_STACK | Q101.3, Q102.1 | 4.692142 mm | 0.25 mm | 0 |
| S1_DATA_COIL_LOW | D101.2, K101.8, Q102.3 | 26.392341 mm | 0.25 mm | 0 |
| HOST2_5V | J201.1, R201.1 | 9.454872 mm | 0.25 mm | 0 |
| S2_HOST_PRESENT | R201.2, R202.1, Q202.2 | 14.370526 mm | 0.25 mm | 0 |
| S2_RELAY_STACK | Q201.3, Q202.1 | 4.692142 mm | 0.25 mm | 0 |
| S2_DATA_COIL_LOW | D201.2, K201.8, Q202.3 | 26.392341 mm | 0.25 mm | 0 |

For branched nets, these lengths sum all copper branches rather than claiming one end-to-end path length. All remaining native connections, including AUX feeds and divider ground legs, are complete according to final DRC.

### Shield pads, local mating assumptions and silkscreen

The final four pad centers agree with [the separate drain-fit assessment](../../reviews/screen-power-usb-revision-1072/shield-drain-fit.md). Recalculated three-dimensional S–W–T paths are **7.058259 mm host** and **9.109679 mm touch**, leaving 2.941741 mm and 0.890321 mm respectively under its 10 mm drain allowance. Recalculation of the touch path against the documented maximum capacitor radius and insulated-drain radius gives **0.556602 mm** closest projected clearance, agreeing with the assessment.

This agreement is conditional on that assessment's side breakout, seated component envelopes, at most 5 mm cable jacket, at most 2 mm insulated drain, documented approach directions and strain relief. The pad-to-header distance alone is not the fit proof. The separate review covers the mated housing height and local raised jacket approach; this report does not claim a full enclosure cable route or that an unknown purchased cable necessarily has the required construction.

Fresh KiCad top and bottom renders of the exact final board were generated into temporary reviewer storage and visually inspected. All added components appear, keyed connector orientation is consistent, the new stage parts are distinguishable, and the moved wiring labels are readable. The independent silk-height/stroke/mask-clearance checks pass, and every visible silk text bounding box remains inside the board rectangle. The power/USB copper retains its rounded, uniform routing style. No additional assembly collision or label defect was found in this pass.

## Validation evidence and limits

The root's completed `validation.json`, generated at `2026-09-26T21:28:32.675716+00:00`, was inspected and its entire production-source hash inventory matched a fresh inventory during this review:

- `cad_ready: true`, no validation errors;
- all **75 distinct required control results true**;
- native DRC: zero findings, warnings, exclusions and unconnected items;
- native ERC: zero findings, warnings and exclusions;
- all **50 populated components** have enabled, resolved STEP models;
- **24 distinct ideal supply/GPIO/host states and 48 coil paths** pass;
- schematic/netlist/native component and net parity pass.

The reviewer independently reran the pad map, circuit contract, board geometry, USB connectivity/width/skew/reference, power-path/via, silk/mask and mounting checks on the final native board, without saving it. The completed 75-control run and fresh native ERC/DRC are evidenced by the root's hash-matched report; this reviewer did not duplicate the full mutation suite merely to restate that result.

**This closes the layout/native-board findings only.** Final export, independent CAM comparison, published ZIP/source/manifest agreement, final commit review and whole-PR CI remain separate gates owned by the root workflow. No claim of whole-PR CI success, USB-IF qualification, measured impedance, verified purchased-cable construction, analog startup behavior or completed hardware acceptance is made. The modeled approximately 90.8-ohm differential impedance is not a manufacturer-controlled impedance guarantee.
