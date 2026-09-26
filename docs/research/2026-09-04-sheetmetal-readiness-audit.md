# Sheet-metal manufacturing readiness audit — 2026-09-04

**Decision: hold the manufacturing release. Updated against `fix/drawing-legibility-1001` at `1d14d701ee9f6c3ad304a63fc60a79e3681afbd1`.** The remote branch head was verified directly. This supersedes the initial assessment of drawing legibility and the missing rear-panel coating BOM row. The branch repairs both, but does not change the mechanical geometry or resolve the fit findings.

All six metal parts' CUT, VENT and BEND geometry were compared with the original audited revision and are identical. The post builder, assembly STEP builder and bend-table definitions are also unchanged. The branch's geometry and paint-BOM assertions pass. All six updated metal PDFs and all four pages of the coating PDF were rendered and inspected; the part scale, note wrapping, bend/mask line patterns and footer spacing are substantially improved. Those presentation findings are closed for this revision. Source-line links below refer to the original audited checkout unless a branch link is given.

This assessment covers the full Segno/VAMP console shown in Fusion, not the separate miniature console. I inspected both open, saved Fusion designs (`VAMP console (populated)` and `VAMP sheet metal`) through Fusion's local API, the current enclosure generator, six metal DXFs and their PDFs, the coating PDF, and exported STEP geometry. The Fusion documents remained unmodified. No manufacturing geometry was changed.

The generator's `--report` geometry assertions passed. All six metal DXFs use millimetres and passed ezdxf's document audit without errors or repairs. The live base and lid are actual sheet-metal bodies: five and two folds respectively, with T = 2 mm, Ri = 2 mm and K = 0.33. Both rear corner brackets are sheet metal too. The drawings already contain quantities, materials, bend tables, directions, general tolerances, through-cut versus reference-layer instructions, and coating masks. Missing basic drawings or missing sheet-metal conversion is **not** the problem.

1. **Resolve the support-post interference before cutting the posts.**

   Temporary-BRep intersections in the populated Fusion assembly measured **376.119 mm³ between the lid and each steel support post**. An independent plane calculation places the post's sloping bearing face approximately **0.575 mm above the lid underside**, whereas the generator intends a **1 mm gap for compressed felt**. This is not confined to the model's square approximation of the bend: the bearing planes themselves overlap. Reconcile post height, floor datum, top bend geometry and placement, then update the flat development and STEP together. Verify the specified felt gap with the feet seated on the base and the lid fully seated.

   Evidence: live `faceplate:1`, `support_post_gen:1`, `support_post_gen2:1`; [post dimensions and height derivation](../../hardware/enclosure/segno_enclosure.py:1386); [post STEP builder](../../hardware/enclosure/segno_enclosure.py:4596). The builder represents the bend with a solid joining block, so the final formed post also needs an accurate bend envelope.

2. **Reconcile the recorded large-screen measurements with the released files, and close the fit.**

   The live screen-case model intersects the lid by **99.534 mm³**; the display body also intersects it by **6.098 mm³**. These are model overlaps, not a claim that the physical monitor necessarily clashes by the same amount. Reconcile them against the real screen and required seating clearance. A recorded September 1 caliper session already gives a **354 × 209 mm** body, **5.3 mm top/side borders and 11 mm bottom border**, a **two-hole horizontal VESA-75 row**, and a raised rear mounting block. The live Fusion model's 354 mm width agrees with that record. My earlier suggestion that the monitor had not been measured was too broad.

   However, the generator at `1d14d701` still contains the old **353 × 208 × 5.8 mm** provisional body and centred VESA assumptions. The missing step is integrating and verifying the measured design in the fabrication source, not repeating an already recorded measurement session. Confirm thread depth, connector clearance and the support-post margin, then verify assembly and lid removal with the stands and cables in place.

   The two buck converters' **56 mm mounting-ear pitch** is also provisional but already produces holes in the base CUT layer. Confirm it before cutting those holes, or explicitly omit them from the laser operation and drill them from the real parts. The purchased encoder knob's underside nut relief is another recorded fit assumption to verify before freezing that stack.

   Evidence: [screen aperture assumptions](../../hardware/enclosure/segno_enclosure.py:309), [screen stands](../../hardware/enclosure/segno_enclosure.py:4450), [buck mounting pitch](../../hardware/enclosure/segno_enclosure.py:2574), [knob relief](../../hardware/enclosure/segno_enclosure.py:4335), and [screen-release plan](../../docs/plan/2026-08-25-feat-screen-mounting-release-plan.md:1). The dated caliper record was checked against the current branch constants and live Fusion dimensions; physical fit completion was not established by this audit.

3. **Make the front-hole machining instructions agree with the DXFs.**

   The base and lid drawing footnotes require the front screw holes to be drilled **after bending**, because they are within the V12 die opening. Nevertheless, all nine base Ø2.5 pilots and all nine lid Ø3.4 clearance holes remain circles on **CUT**, which the same drawings define as through-cut. Their centres are approximately 5.045 mm and 5.238 mm from their respective bend lines; the quoted 3.8/3.5 mm distances are approximately the hole-edge clearances. A shop following the cut layer would make the holes before the operation that the note says must precede them.

   Supply a laser profile with these deferred holes excluded, plus a dimensioned post-bend drilling/tapping operation referenced to the formed part. Alternatively, obtain an explicit, validated shop process for cutting and finishing them. Reconcile the M3 tapping/coating sequence as well: MANUFACTURING.md describes tapping after bending with masking or chasing, while drawing and coating notes describe tapping after painting.

   Evidence: [lid front-hole generation](../../hardware/enclosure/segno_enclosure.py:2784), [base front-hole generation](../../hardware/enclosure/segno_enclosure.py:3004), [drawing footnotes](../../hardware/enclosure/segno_enclosure.py:4969).

4. **Resolve finished fit and obtain shop acceptance of the bending process.**

   The live lid front-lip inner plane is at depth −1.910800 mm; the base front outer plane is approximately −1.910841 mm. That is effectively zero bare-metal clearance. The existing instruction requests **0.3 mm clearance after coating**, achieved by opening the lip slightly, but the model and nominal bend table still describe the flush joint. Make the finished fit an explicit acceptance requirement, define where it is measured and how screw alignment is maintained, and agree how the shop will set the bend before coating. A roughly 0.16 mm two-face coating build would interfere at the current nominal fit.

   The base drawing also records only **0.06 mm** between the side-wall rear edge and the rear wall. That is smaller than the drawing's ±0.5 mm across-bend tolerance. Bend order alone does not establish a robust clearance under that variation. Establish a workable corner allowance or an agreed controlled fitting operation.

   Have the shop confirm the actual 1050 stock condition/temper, thickness, achievable Ri and bend development; V12 tooling; a segmented punch no longer than 410 mm for the side walls; forming/straightening around the perforated lid; and acute tooling for the post's **77.5° included angle**. The existing notes describe these requirements, but do not establish that the selected shop can meet them. Supplier-specific calibration matters: [Protolabs explains that bend development depends on material and forming process, and uses tooling-specific K-factors](https://www.protolabs.com/resources/design-tips/the-basics-of-bend-radii-in-sheet-metal/).

   Evidence: [lid fit specification](../../hardware/enclosure/segno_enclosure.py:933), [bend tables and footnotes](../../hardware/enclosure/segno_enclosure.py:4934).

5. **Replace incomplete 3D references and make the drawings usable for inspection.**

   The on-disk `segno_faceplate.step` is a **406.636 × 849.8 × 2 mm flat plate**, without either flange. It is neither the complete developed blank nor the folded lid. In `segno_assembly.step`, the bottom is an unperforated six-face box; the side walls lack the DXF ventilation; the lid also lacks its folded flanges. These omissions come from `build_step()`, so simply regenerating the current exporter will repeat them. The STEP quote list also has no individual base, corner-bracket or rear-panel STEP.

   Replace misleading references with current, complete formed geometry, or supply proper formed-part drawings that fully define those parts. Add dimensioned side/section views and inspection datums for the lid seat, wall heights, post contact and mating screw rows. The PDFs presently emphasize flat outlines and bend tables. The note wrapping, small drawing scale and overlapping coating footers identified initially are **fixed by this branch**.

   The new coating note distinguishes development from folded dimensions, but still labels **850 × 407 × 2 mm as the folded lid size**, taking that value from the unchanged, flat `segno_faceplate.step`. The improved wording therefore does not resolve the inaccurate 3D reference. [Latest size-note implementation](https://github.com/tomassasovsky/segno/blob/1d14d701ee9f6c3ad304a63fc60a79e3681afbd1/hardware/enclosure/segno_enclosure.py#L5671).

   Evidence: [assembly/STEP exporter](../../hardware/enclosure/segno_enclosure.py:4740), [STEP pack contents](../../hardware/enclosure/segno_enclosure.py:5910).

6. **Complete the coating specification, including the removable rear panel.**

   The omitted `segno_rear_panel` is **fixed**: the latest coating BOM includes its 1.5 mm stock, the area total is now 1.4135 m², and page 4 defines its PANEL_BOND mask. The generator also includes its drawing in the coating package and checks BOM/masking-page coverage.

   One instruction still conflicts: coating-cover note 4 says **only** the M6 earth-stud land is unpainted, while the base and rear-panel drawings also require **PANEL_BOND** masks. Remove that exclusion and make the coated faces, masks and thread treatment consistent. [Latest coating implementation](https://github.com/tomassasovsky/segno/blob/1d14d701ee9f6c3ad304a63fc60a79e3681afbd1/hardware/enclosure/segno_enclosure.py#L5567).

   Check finished thickness at the CTRL jacks: [Neutrik specifies 1.2–1.5 mm panel thickness for NJ6FD-V](https://www.neutrik.com/en/product/nj6fd-v). The selected rear sheet is already 1.5 mm before coating and stock variation. If both seating faces receive powder, the mounting stack can exceed that range. Specify and verify a suitable finished mounting land/stock thickness; a nominal 1.5 mm CAD plate does not settle the snap-cap fit.

   Evidence: [paint BOM](../../hardware/enclosure/segno_enclosure.py:5195), [coating instructions](../../hardware/enclosure/segno_enclosure.py:5327).

For context, the targeted live sweep found zero solid overlap between the lid and the 7-inch screen/tower, either large-screen stand, either corner bracket, and the rear panel. Base-to-bracket, base-to-post and base-to-rear-panel intersections were also zero. Base-to-lid overlap was 5.428 mm³, similar in scale to the contact films already documented in FUSION_MODELS.md; this does not establish coating clearance. The sweep covered 21 selected body pairs, not every body, fastener, cable, tolerance combination or removal motion.

Release sequence: reconcile the measured dimensions and interference findings; agree the forming, drilling and finished-fit process with the shop; synchronize the generator, Fusion models and accurate exports; regenerate and validate the vendor packages; freeze the exact revision supplied. Prior project records say a package was already sent from master after #994. The absence of ZIPs in the main checkout does not prove otherwise; this audit did not inspect the exact previously transmitted package. Treat subsequent files as a clearly identified revision and establish which revision the shop will manufacture. Agree a first-piece fit check before coating. Repeated foot-load, thread-service and transport-retention validation belongs to prototype qualification before production quantities; no structural qualification was established by this audit.

PDF sources reviewed (all pages; original versions below and the corresponding versions at branch commit `1d14d701`):

- [segno_base.pdf](../../hardware/enclosure/out/segno_base.pdf)
- [segno_faceplate.pdf](../../hardware/enclosure/out/segno_faceplate.pdf)
- [segno_post.pdf](../../hardware/enclosure/out/segno_post.pdf)
- [segno_corner_bracket_rear.pdf](../../hardware/enclosure/out/segno_corner_bracket_rear.pdf)
- [segno_rear_panel.pdf](../../hardware/enclosure/out/segno_rear_panel.pdf)
- [segno_ring_disc.pdf](../../hardware/enclosure/out/segno_ring_disc.pdf)
- [segno_paint_quote.pdf](../../hardware/enclosure/out/segno_paint_quote.pdf)
