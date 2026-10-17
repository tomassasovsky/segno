<!-- cspell:words Omron Schurter IRLZ NPBF PNP NPN Shapely onsemi -->
# Independent bug review: Revision N and local copper finishing

28 September 2026. **The bug-focused review is complete and clean for the
working source/native/artifact identities below.** No unresolved actionable
finding remains. This is a design and fabrication-data review, not hardware
qualification or a claim that CI passed on a future pushed head.

## Target and evidence boundary

The target is the entire working delta, including untracked source and assets,
from `9f01b49572249e544c84097b574c02f25de851a7` on PR #1080. The preceding PR
scope has separate completed evidence in
[the earlier review](../../../code-review/pcb-claude-followup-1072/review.md).
This pass independently reviews the new relay/input-holder design, its native
circuit and routing, the ring's two local zone exclusions, and the associated
checks and documentation. It does not reclassify every preceding PR change as
newly reviewed or claim new Claude approval.

Reviewed native snapshots:

| Board | SHA-256 |
| --- | --- |
| Screen | `e72850b26ae9076011bc368b69d3f1f1edce758be878bf5fb0decc4f415c5a2f` |
| Ring | `c53eb16d7531f2c891dc5854faaf40fc1414ebcb2747d0101740e6a35bd1d9ca` |
| Console, unchanged | `c23df586f211bb439081ca951dd23dc54ba21f6d89eb3d373bd6f196749f326d` |

The review followed `AGENTS.md`, the build/test guidance, the tracking
contract, and the bug-focused review skill. Other independent role reports
are distinct evidence; their preliminary snapshots are not silently treated
as final coverage.

## Findings

No unresolved circuit, component-connection, native-connectivity, power-width,
USB-preservation, or implementation defect was identified in this snapshot.
This independent pass found two pointed front-ground ends between the
upper-left mounting clearance and the control trace near x=8.2–8.6 mm. The
author corrected both with local pour-only exclusions forming 0.4 mm tangent
caps. The final source, native checks and actual copper crop were rechecked;
both tips now have smooth ends. This finding is **resolved**. See the
[before/after evidence](../screen-copper-finish-audit.md).

The board overview's statement that all ring copper was unchanged was
reported to the owner of that document. It is corrected: routes, pads and
rear fill are retained, while the two front-ground dead ends are removed.

## Completed review angles

- **Changed source and enclosing behavior:** read the circuit, schematic,
  placement, board generator, critical routing, finishing, part geometry,
  model construction and complete checker changes. Read new footprints and
  relay symbol definitions. Generated sheets and native copper were checked
  semantically through fresh netlist export and native geometry, rather than
  relying on UUID-heavy textual differences.
- **Removed behavior:** traced removal of the charge pump, optocoupler,
  opposed power MOSFETs, obsolete sheets/models and their guards. Their
  negative-rail checks are no longer applicable; the new checks instead bind
  the normally open contact, coil driver, clamp, raw/fused supply boundary,
  exact purchased parts and input-holder accessory. The obsolete gate-drive
  sheet is absent from the active hierarchy and exporter inventory.
- **Circuit and partial power:** traced GPIO through Q1/Q2 to DATA_ENABLE,
  the Q5 low-side coil path, D3 across the coil, and F1 ahead of every AUX
  consumer. Verified the retained two series USB drivers per channel and
  independent host presence. A released contact isolates in both directions;
  a closed contact can sustain AUX from an externally fed output until GPIO
  is lowered. Documentation does not claim unconditional source-loss isolation.
- **Cross-file contracts:** followed exact MPNs, values, pin maps and accessory
  quantities from circuit source to component records, purchase BOM, native
  schematic, native PCB and checks. F1 has one electrical footprint and one
  separate holder purchase, with no invented electrical pads. The custom
  root relay symbol participates in both production-input hash inventories.
- **Routing and geometry:** reviewed constant-width power runs, branching at
  the protected F1 terminal, layer transition with three dedicated vias,
  minimum-width checks with all zones removed, and the fuse-barrel removal
  control. USB copper and anchors remain independent baseline invariants.
  Reviewed both actual filled-copper exports and a fresh populated top view.
- **Reuse and simplicity:** no alternate power-stage compatibility path,
  speculative configuration, or duplicate runtime implementation was added.
  The independent expected pin/part maps in validation are deliberate design
  requirements, not a second authoring path. The focused ring finishing hook
  remains in the existing module and is idempotent for its two named zones.
- **Efficiency and failures:** no application or real-time callback code is
  changed. CAD calculations execute offline. Reviewed checker fail-closed
  behavior, source-change detection, missing model/part failures, and the
  existing staged publication/rollback path. No newly introduced repeated
  hot-path work or hidden mutation was found.
- **Fix depth:** the new screen contour removes the geometric intersection
  that produced the mounting-hole pour tips. The ring edits act on local zone
  fill, leaving routed signal and power copper intact. They do not hide
  missing routes with overlays or weaken the electrical rules.

## Component and numerical verification

Independently reopened the primary
[Omron G6C data sheet](https://components.omron.com/us-en/system/files/2026-03/datasheet_pdf/K018-E1.pdf)
and checked the chosen single normally open contact, 5 V coil, and bottom-view
terminal drawing against the custom symbol and footprint. The conversion to
top view is consistent: coil 1/8 and contact 3/4. The 10 A resistive rating is
not treated as a capacitive endurance guarantee.

Checked the [Schurter OGN drawing](https://www.schurter.com/en/datasheet/typ_ogn.pdf)
against the holder footprint: two terminals, 22.5 mm pitch, with no central
mounting drill. Checked the
[Bel 0697H data](https://www.belfuse.com/media/datasheets/products/circuit-protection/ds-cp-0697h-series.pdf)
against branch values, 5.08 mm pitch, maximum body and lead geometry.
The onsemi [1N4007G data](https://www.onsemi.com/pdf/datasheet/1n4001-d.pdf)
and actual 1.1 mm native drills support the retained axial flyback package.

Reviewed the explicit 4.25 A screen allocation, 60 mA bleeder, 4.31 A switched
load and 4.46 A input bound. The input-fuse, holder, copper and driver drops
remain separate. The 45.5 mV modeled hot-pickup margin is evaluated before the
normally open contact admits screen current; the loaded 100 °C sensitivity
has only 2.4 mV reserve and is not advertised as a large guaranteed margin.
The USB hot-coil model retains approximately 110 mV. Unknown enclosure
heating, startup capacitance, aged contacts and screen-end operating voltage
remain explicit limits, not unverified assertions or extra prototype demands.

Read the finite ground-return model's extraction, whole-cell admission,
annular terminal treatment, finite barrel conductance, reciprocal solve and
worst allowed current allocation. The earlier independent synthetic controls
are retained. Final results bind to the exact final native and current model:
13.158 and 12.760 mV for the two nominal mesh resolutions, and 15.366 mV for
the thinner-copper/barrel sensitivity case. All remain below the 20 mV copper
allowance under the recorded material, temperature and current assumptions.

## Observed checks

- Independently executed the screen native checker on the initial reviewed
  screen snapshot, `5335675f9e678028ac6e6aaf61e86330f338137fd15b8a1ff9f16fced52fa6de`:
  **pass**, fresh ERC/DRC **zero findings**, and fresh schematic/netlist/native
  parity. This independent invocation did not duplicate the long mutation
  run; inspected the author's same-hash report with **103/103 controls passed**.
  After the two H1 tips were cut back, inspected the final same-source/native
  validation: CAD ready, zero errors, and **103/103 controls passed** on the
  final `e72850...` board. Read the new pour-only source routine and inspected
  the final copper at close scale; no further source or copper change followed.
- Independently ran USB preservation: **292 copper items and 18 fixed anchors**
  match the pre-redesign baseline, allowing only the documented J1.1 raw-net
  rename. Widths, coordinates, layers, pad geometry and arc midpoint handling
  are included. Repeated this independent check on the final `e72850...` board.
- Independently loaded the ring baseline through Git and compared it with the
  recorded final native: **564 tracks/vias and 73 pads identical**, including
  nets and geometry; rear filled-ground contours identical.
- Applied `finish_ground_edges` to that baseline only in memory. Both new
  rule areas exactly reproduce the native geometry and zone-only permissions.
  No production board was saved by the review.
- Independently ran ring DRC: **zero violations and zero unconnected items**.
  The retained ring power guard passed and rejected all **seven** injected
  faults. The final ring area/parity report records 3.2204 mm² of front ground
  removed from dead ends, with live U2 ground paths retained.
- Independently evaluated `ground_outline(68, 76)`: its 356-point polygon is
  simple and valid, stays within the intended edge offsets, and maintains the
  4.55 mm mounting-center clearance. The source contour exactly reproduces
  both native ground-zone outlines.
- Reviewed the console/ring final native/CAM verifier report: **175 assertions
  passed**, with exact inventory, layer count, native net parity, ZIP CRC and
  fresh Gerber/drill drawing comparison. Timestamp-only differences are
  explicitly normalized; drawing geometry is not discarded.
- Reviewed the final screen native/CAM/package verification: **415 assertions
  passed**. Independently recomputed every one of its **138 source and artifact
  hashes** from disk; all match. The native board and manufacturing ZIP hashes
  match the report. Final ground reports also match the board and model hashes.
- `git diff --check` passed at the reviewed point. No Dart, Flutter, firmware,
  native audio engine or application runtime source changed in this delta;
  their unrelated suites were not used as hardware evidence.

KiCad emitted its known headless assertion/debug diagnostics during some
read-only API operations. The commands exited successfully and the reports
showed no validation exceptions; diagnostics were not mistaken for findings
or silently relabeled as passed failed checks.

## Final artifacts and limits

The final screen manufacturing ZIP is
`abf39dbf1b7569a1ad25640c081f3e4fb126c94cd8d36d63fb1e559c7c2f8808`.
The ring ZIP is
`d25b01306dec7ab2e62ad1db727eb4854e3bb1777295e05be4fbe468f92b0dfd`;
the unchanged console ZIP is
`1f50cfc2816fdb3cab0fbaef07b91aad07ee06584f8dac8437a2431869465383`.
The reports enumerate the complete source and export identities:
[screen](../screen-fabrication-verification.json),
[console/ring](../console-ring-fabrication-verification.json).

No source/native/CAM delta remains pending in this review. External delivery
folder publication and the pushed commit identity are owned by the publishing
agent. A pushed head needs matching current review evidence; CI is a separate
required gate. No new completed Claude review is claimed. No commit, push,
merge, order, flash or deployment was performed by this reviewer.

The [bug-gate report](../../../code-review/pcb-stock-cost-1072/review.md)
records this completed delta review with retained earlier PR evidence.
This does not prove USB compliance, real enclosure temperatures, capacitive
contact endurance, or a manufactured assembly's behavior. The design's stated
operating bounds and hardware qualification limits remain in force.

Final staging note: the scoped whitespace check passes with STEP model files
excluded. Their preserved vendor/generated serialization contains trailing
spaces and CRLF line endings; no source or documentation whitespace errors
remain. The final staged model bytes match the reviewed fabrication manifest.
