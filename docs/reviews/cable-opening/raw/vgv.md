# VGV correctness review

Scope: only the cable-opening delta in `hardware/enclosure/segno_enclosure.py` against `/tmp/segno-cable-opening/before/hardware/enclosure/segno_enclosure.py`. Performed read-only as a separate second pass after the architecture review.

Source SHA-256: `87242c52c481d4a2664adf65588ece5ff97ba718fce377c2fb59bcf41b5c8b24`.

Findings: none.

The selected width is 8.6 mm, giving 0.5 mm on each side of the measured 7.6 mm feature. The lower edge is 6.95 mm above the bare case/sled interface: the lower of the two approximate measured positions, 7.45 and 8.5 mm, less 0.5 mm clearance. The 60 mm cutter still reaches above the whole rear wall. No upper bridge is introduced, so vertical insertion remains possible. Rearward direction, horizontal centering, the existing through-wall cutter reach, and the sled-top datum are consistent with the builder's coordinate system.

Independent CadQuery checks generated baseline and changed front, mid, and integrated-mini collar solids directly from their respective source files. Both changed collars are valid single solids. Each adds 695.782716 mm3 entirely within the old cable slot, removes zero material, and keeps the 118.47 x 88.75 mm outside footprint. Thus no existing screw bore, sled bore, outside clearance, support column, or other surface is moved by this source delta. The mini solid has zero bidirectional Boolean difference.

For both front and mid collars, padded rectangular cable envelopes at both measured vertical interpretations, including 0.5 mm on all four sides, intersect the collar by zero volume. Their continuous upward installation sweeps also intersect by zero volume. The existing seated console sled has zero volumetric intersection with each changed collar. Raw numerical results are in `/tmp/segno-cable-opening/source-review-geometry.json`.

No API, dependency, import, lifecycle, async, or application-layer changes occur. Naming and arithmetic are consistent with this existing Python/CadQuery source. Test edits and final native/export publication are separately owned and were not classified as unfinished-source defects. These geometry checks do not establish the physical cable's dimensions, printer accuracy, or stomp strength; a first-print fit check remains appropriate.
