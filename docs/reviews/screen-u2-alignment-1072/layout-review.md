# Screen-power U1/U2 alignment review

Result: **PASS** for this bounded placement and routing change. Reviewed native board SHA-256 `3b00298277874b1018c55876766d4e771c1fca0e59393271a3e98df1743a80af` against baseline `c06e6b35438b2fc7208cdc50feeebee92e6c01a56a00dadd280f697d1e49d79b`.

Claude commit `2547d7dbe3f7c81dada4b824406fb65d396c730e` places both DIP lead rows at **y = 11.63 and 19.25 mm**, with both parts rotated 90°. U1 moved down 0.25 mm; U2 moved up 0.75 mm. The final layout source has identical executable semantics to Claude's patch. U1/U2 references moved with the parts; all other placements, pad and model definitions, vias, zone definitions, board stack and outline are preserved.

The affected front routes were regenerated from the existing pad-based critical-routing source: exactly **43 old segments replaced by 43 new segments**, matching the old native routes with zero coordinate error. The same exact delta is present in the native and placed boards. The sole rear change is U2.2's 0.25 mm CONTROL_SINK approach: two segments became ten, with a **1 mm inside bend radius**. Track/pad-only connectivity from U2.2 to Q1.3 passes. High-current routes remain exact.

All eight USB data routes and terminal poses are **exactly unchanged**. An independent native graph review finds no branches, stubs, detached segments or data vias. Minimum pair edge gap remains **0.160 mm**; maximum pair skew is **0.000000951 mm**. The final filled board passes all **6,268 ground-reference samples** beneath the USB center lines and copper edges. Both GND pours retain one connected filled outline per face.

A final in-memory rounding pass changes no tracks and reports no unresolved bends. The independent degree-two vertex scan finds no exposed turn above 12°. The unchanged 45° centerline vertex at B.Cu (46.4, 22.6537) is fully buried in the 2.5 mm SWITCHED_5V feed; its complete 0.25 mm corner disc has at least **0.917834 mm** additional copper containment, so it is not an exposed angular contour. Turns inside component pads remain valid pad junctions.

Native ERC and DRC report **zero errors, warnings and unconnected items**. All **56 fault controls pass**. Front/back copper and silkscreen previews were inspected: the DIP rows align, the rear approach is visibly rounded, references remain readable, and no new gap appears.

Evidence: [compact results](final-summary.json), [geometry checks](final-geometry.json), [USB checks](final-usb.json). Previews: [front copper](F-alignment.png), [rear copper](B-alignment.png), [silkscreen and pads](silk-alignment.png).

This is CAD evidence for the alignment change; it does not qualify assembled hardware or establish USB compliance.
