<!-- cspell:words datasheets heatsinks -->
# Revision L screen-power verification

25 September 2026. Issue [#1072](https://github.com/tomassasovsky/segno/issues/1072),
PR [#1080](https://github.com/tomassasovsky/segno/pull/1080).
Comparison base: `7dcdc944bea0d22e2fa1fe32ab4ead4681aa11aa`.

**Final Revision L CAD and manufacturing checks pass.** The three archives
below include the completed rounded-copper finish. Revision K and the earlier
Revision L artwork are superseded. No pre-PCB prototype or additional owner
measurement campaign is required for this bare-board fabrication.

## Design change

The retained power MOSFETs now have a through-hole LMC7660 negative supply
and TLP627M optical gate drive. The two relay drivers change to TN0702N3-G.
The screen planning load is 4.25 A; the former 6 A expansion allowance is
retired. The separate ring supply still supports the unrestricted 40-pixel
full-white allocation.

The board retains its 68 × 76 mm outline, 3 mm corner radius, two copper
layers, purple mask, eight connector locations and four M3 mounts. There
are 44 populated through-hole parts. Q4 pin 3 to Q3 pin 3 and Q4 pin 2 to
F101 pin 1 now use a uniform 2.5 mm width from pad to pad, with rounded bends
and no taper overlays. The 4.5 mm distribution trunk, 3 mm fuse branches and
2 mm main-output routes retain their capacity and gain rounded joins. The
new charge-pump loops are explicitly routed north of the USB paths;
low-current control connections complete the remaining routing.

The owner-authorized Claude cloud task authored the placement, critical
routing and silkscreen changes, with the final screen-width correction in
`e9fab839`, ring cleanup in `255a47cf` and console rounding in `2e4b30a5`.
Its remote environment lacked KiCad; the local KiCad 10 build remains the
authority for electrical and layout checks.
Native findings are sent back for correction rather than excluded from DRC.

## Completed engineering checks

- [Independent electrical review](electrical-review.md): actual symbol and
  package pins, default-off states, supply sequencing, gate/pump loading,
  relay drivers and 13 independently rejected electrical mutations.
- [Gate-drive calculation](gate-drive.md): modeled gate drive is 6.110 V,
  or 5.289 V with the 2 V optocoupler stress allowance, versus the 4.5 V
  resistance specification. Maximum modeled gate drive is 8.682 V.
- [Startup and thermal assessment](startup.md): calculated operating losses
  support upright MOSFETs without heatsinks at the planning load. The
  manufacturer's pulse graphs were visually checked independently. No new
  active limiter or pre-PCB prototype requirement is introduced.
- Power budget: 4.25 A screens plus the retained 3.358 A console/normal-pill/
  full-white-ring allocation gives 7.608 A on the nominal 10 A AUX buck.
- The seven-page native schematic exports cleanly and has been visually
  inspected. Native ERC reports zero findings; schematic/netlist/PCB pin
  correspondence and all four relay contact states pass.
- All 44 populated parts resolve portable models. Maximum DIP/capacitor
  envelopes and connector mating access were checked, including the new
  0.90 mm DIP drills and their finished-hole tolerance.
- Final native ERC and DRC report zero errors, warnings, exclusions or
  unconnected items under the committed project rules. All 52 regression
  controls pass, including deliberate electrical, copper, hole and model faults.
- Power checks remove copper pours before testing trace continuity, so a pour
  cannot hide a missing or narrow bus. New controls reject width changes and
  taper overlays on the two uniform 2.5 mm paths. The
  [width assessment](uniform-power-width.md) covers clearance, resistance,
  heating and gate margin at the 4.25 A planning load.
- USB pair lengths remain equal within each pair, with no data vias;
  5,452 samples of the actual front ground fill pass. Power-width continuity
  and the console GPIO17 connection pass the final check.
- Existing GPIO lifecycle tests pass 12/12. No firmware, runtime deployment
  or device settings changed in this revision.

## Finished artwork and independent export

Native build feedback closed the CONTROL_SINK and AUX_5V connections across
the first USB row. They use opposite-layer edge corridors outside the USB
return paths. Claude also corrected the silk/mask overlaps, washer-hidden
labels and exposed right-angle elbows. The latest finish removes the screen
bus's sharp inside joins, the ring J1 power remnants and pointed tap joins,
and adds 1 mm corner fillets to both console power bars. The
[three-board copper review](copper-finish-review.md) verifies the retained
power and ground paths. The final populated previews, component envelopes
and connector access were inspected; the
[layout review](final-layout-review.md) records the final board snapshot.

The standalone [CAM verifier](verify_fabrication.py) regenerated manufacturing
files through KiCad CLI without importing the board generator or validator.
All **406 assertions pass**: 65 source hashes, 70 package artifacts, both ZIP
inventories and all 12 manufacturing files agree. Fresh Gerbers, drills and
job data match after creation timestamps only. Drill-map PDFs match in decoded
drawing content, page geometry and resources. The
[machine record](fabrication-verification.json) identifies the exact source
and artifact hashes. The verifier itself rejects source changes during a run.

The separate [console/ring CAM record](console-ring-fabrication-verification.json)
passes **103 assertions**: fresh CAM matches the updated 12-member console and
10-member ring archives, both boards have clean native DRC, netlist parity
passes, and all 29 audited source files remain unchanged during verification.
All three boards have exactly two copper layers.

Independent [electrical](electrical-review.md),
[validator](validator-review.md) and [DeepSeek](external-model-review.md)
reviews have no unresolved verified finding in their stated scopes. The
[bug-focused review](../../code-review/screen-power-rev-l-1072/review.md)
consolidates this revision's coverage; it is not a clean gate for every
historical change in the stacked PR.

## Manufacturing package

[Screen-power Revision L Gerbers](../../../hardware/kicad/fab/segno_screen_power_rev_l_gerbers.zip)
contain seven Gerber layers, separate plated/non-plated drills, two drill maps
and the job file. Order settings: bare PCB, two-layer FR4, 1.6 mm, 1 oz outer
copper, ENIG, purple mask, white silkscreen and tented vias. No assembly or
stencil service. The nominal finished outline is 68 × 76 mm with 3 mm corners.

- Board SHA-256: `d3577772b4945f93652789e109fd232b479cfc8d119dcb67e499da51d39fa5cf`.
- Screen ZIP SHA-256: `7a52639a561ebebf36695901bd84f27a2770fe900a227a6594deb89c0fde8e23`.
- [All three upload archives](manufacturing-zips.json) identify the updated
  console, white ring and screen files, native boards and individual ZIP members.

The 44 PCB parts total an estimated $41.51 before shipping/tax; allow $45–50.
The complete board parts, required protection, harness and mounting allowance
is $72.32–97.32, excluding the bare PCB, shipping and tax. See the dated
[cost and stock notes](../../../hardware/kicad/screen_power/COSTS.md).

## Qualification boundary

CAD and calculations do not establish assembled USB compliance, enclosure
temperature or shutdown timing. The modeled gate margins and startup/thermal
assessment support this fabrication decision under their stated assumptions;
they do not guarantee an undocumented load or fault. Upright MOSFETs need no
heatsink under the planning-load estimate. The specified input fuse/holder and
main-power harness remain required. The five-second shutdown wait and final
enclosure mounting still need first-assembly confirmation.

Those limits do not impose a new pre-order prototype or measurement campaign.
The PR retains its hardware verification gate; full repository CI has not run
against its feature-branch base. No assembled production qualification,
manufacturing order, merge or device deployment is claimed.
