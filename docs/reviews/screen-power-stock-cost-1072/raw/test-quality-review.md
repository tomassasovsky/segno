# Test Quality Review — screen power revision N

**Final test-quality review: clean, with no unresolved actionable finding.**
The final native board passed all 103 controls and native ERC/DRC. Ground
model and all three boards' fabrication evidence match current inputs.
The screen package passes 415 independent fabrication assertions. This
review applies to the identities below, not an unverified later board or
assembled hardware qualification.

Baseline: `9f01b49572249e544c84097b574c02f25de851a7`. Review date:
28 September 2026. The scope is the working hardware diff, new relay/fuse
assets, and `docs/reviews/screen-power-stock-cost-1072`.

## Coverage summary

- Stack: Python, SKiDL, KiCad native geometry and CLI, with a NumPy/SciPy/
  Shapely DC sheet model. This diff does not change Dart, Flutter, firmware,
  state management, repositories or UI. Their test-pattern requirements do
  not apply to this hardware change.
- Executed the existing source circuit, BOM, state and mutation checks
  independently: **51/51 controls passed; zero source-check errors**.
- The final recorded native mutation suite passes **103/103 controls**.
  Independently executed the complete suite on an earlier private snapshot:
  102/103 passed, with only the existing silk-mask baseline conflict failing.
  The final delta explicitly confirms that prerequisite is now resolved;
  the earlier failed snapshot was never accepted as a clean result.
- Historical native SHA-256 for that independent run:
  `53cdf6ab90619885a0872c31d25b3eb12729e2b84486431a84982f9b234bf29b`.
- Line-coverage percentage is not collected by this KiCad/SWIG checker. A
  numerical percentage would not establish copper, pin-map or manufacturing
  coverage. Positive baselines, deliberate physical faults and independent
  export comparison are the relevant evidence here.
- No missing unit-test file was identified as an actionable defect. The new
  source and geometry responsibilities are exercised through the established
  checker and its mutation suite rather than mock-based per-file tests.

## Positive and negative controls

The circuit contract is independent of the SKiDL generator and verifies
terminal-level topology rather than importing the generator's expected maps.
It checks that F1 is the only connection from raw J1 power to every downstream
load; verifies the power-relay coil/contact assignment and driver/clamp;
rejects the obsolete pump/opto/MOSFET stage; and retains independent host
presence and USB channel boundaries.

The source controls deliberately change fuse, holder, relay, transistor,
clamp, resistor value/tolerance and purchasing records. Missing and duplicate
holder purchases, obsolete branch clips, a fuse bypass, a raw-input load,
wrong contact terminals and reversed MOSFET body-diode paths are rejected.
Successful baselines precede these controls, so a pre-existing failure cannot
make an incorrect mutation appear detected.

USB behavior is exercised with 24 AUX/GPIO/host combinations and 48 coil
paths. A separate contact graph tests energized and released relay throws,
cross-channel coupling and polarity swaps. These are correctly described as
ideal switch/state checks; the numerical drive calculation and the eventual
assembled USB operation remain separate evidence.

Native controls remove or narrow physical copper and alter real via/hole
geometry. The new power checks strip filled zones before connectivity checks,
so an overlay cannot hide a missing or undersized trunk. Via tests require
three adequately drilled, connected barrels inside both copper landings,
then remove the fuse barrel to prove an independent layer transition.
The 4.5 mm distribution-spine control rejects a narrowed spine independently
of endpoint continuity. Lead-pitch, mirrored relay, hole tolerance, SMD,
missing/disabled model and mounting-clearance faults are covered.

No new tautological assertion, mocked design-under-test, or assertion-free
test was found. Exact MPN duplication in the checker is intentional independent
verification of selected parts, rather than implementation mirroring.

## Preserved USB and other-board scope

Independently loaded the committed baseline board through `git show` and
confirmed that `usb-layout-baseline.json` exactly represents its USB copper
and fixed anchors. The current board preserves **292 copper items and
18 anchors**, allowing only the documented J1.1 net rename to `AUX_5V_IN`.
This comparison therefore checks a real pre-redesign baseline, not merely a
new board against a newly generated expected value.

Deliberately moving a USB route vertex by 0.01 mm and rotating an anchor by
0.1 degree both change the captured geometry and are detected. The verifier
also records arc midpoints if present; the actual preserved USB routing in
this snapshot uses segment items.

The console native remains byte-identical. The subsequent ring finish change
removes two local front-ground protrusions using zone-only exclusions; its
564 track/via items, 73 pads and back-ground contours are unchanged. Reviewed
the source finish function, anchor assertions, pipeline placement and parity
evidence. Independently reran the retained ring-power checks (7 deliberate
faults rejected) and encoder checks (13 deliberate faults rejected); all pass.
The screen checker retains its independent physical console GPIO connection
check, including a negative control that cuts the copper.

## Ground-return model

Reviewed actual filled-copper extraction, conservative whole-cell admission,
finite plated-barrel conductance, graph connectivity, the sparse Kirchhoff
solve, reciprocity and the constrained worst-current allocation. These are
an engineering sensitivity, not a guaranteed manufactured resistance or
measured thermal result.

One issue was identified and repaired by the model owner during review:
subtracting drill holes only from pad annuli allowed a same-net track polygon
to restore copper inside a drilled void. The model now subtracts the union
of all drilled voids after combining the plane, track and pad regions. This
closes the geometry issue without changing the physical PCB.

Independent synthetic checks of the corrected model passed:

- A connected two-layer fixture solves with a maximum KCL residual below
  `2.5e-12 A`.
- Doubling both copper foil and barrel plating gives a loss ratio of
  `0.50002478`. The small departure from exactly one half is expected from
  the fixed finite numerical terminal ties; the absolute ratio tolerance
  was `0.0001`.
- A complete 0.01 mm clearance slit across both layers is rejected even on
  a 0.25 mm mesh. The model does not bridge the subcell slit by sampling only
  cell centers.

The updated 4.46 A total input and 4.31 A switched allowances intentionally
include the conservative rounded bleeder/control contributions. Documentation
records these allowances consistently. Final nominal and stress model
evidence matches the completed board hash.
Nominal losses are 13.158/12.760 mV on 0.15/0.10 mm meshes; the thinner-material
stress is 15.366 mV. All remain below the retained 20 mV allowance, with no
omitted terminal faces and KCL residual below 1 nA.

## Source, native and export consistency

Reviewed the checker path through fresh schematic netlist export, full
component/connectivity comparison, native ERC/DRC, source hashing before and
after checks, staged manufacturing publication, portable models and the
independent CAM verifier. The new root custom relay symbol is included in
both production-input inventories. Obsolete `gate_drive.kicad_sch` is deleted,
so the export glob no longer copies the abandoned power circuit.

The independent fabrication verifier does not import the exporter or native
checker. It verifies manifest inventory and hashes, portable native identity,
the accepted validation report, exact ZIP members, fresh Gerber/drill content
and the two-layer 1 oz stackup. Timestamp-only normalization preserves actual
manufacturing drawing data. Its final revision N result is accepted below.

## Final delta and artifact evidence

The final [screen validation](../screen-native-validation.json) at native
SHA-256 `e72850b26ae9076011bc368b69d3f1f1edce758be878bf5fb0decc4f415c5a2f`
reports **103/103 controls passing, zero ERC/DRC errors, warnings, exclusions
and unconnected items**. Every recorded source hash matches live input files.
The source checker, hand-assembly checker, netlist, component records and BOM
remain byte-identical to those independently exercised above. The prior silk
prerequisite is resolved, and the last local ground-contour edit is included
in both this validation and the refreshed nominal/stress models.

The refreshed [console/ring fabrication verifier](../console-ring-fabrication-verification.json)
reports **175 successful assertions and zero failures**. Its native,
archive and source identities match current files. The earlier stale
screen-generator input hashes were corrected by a full rerun after freezing
the final sources; no report is accepted on the basis of filename alone.

The final [screen fabrication verifier](../screen-fabrication-verification.json)
passes **415 assertions**, bound to the same `e72850b...` native board and
manufacturing ZIP SHA-256
`abf39dbf1b7569a1ad25640c081f3e4fb126c94cd8d36d63fb1e559c7c2f8808`.
Independently checked every recorded source and artifact hash against live
files: no stale or missing inputs/artifacts. The verifier's own source hash
matches its current implementation. Packaged native identity agrees with the
manifest and fresh validation, the packaged CAD report is clean, and no
obsolete gate-drive sheet remains in the portable project.

**Verdict:** tests and verification meet the quality bar for this final
hardware revision. No unresolved test-quality defect remains; the earlier
model geometry issue is repaired. This role does not claim USB certification,
measured thermal performance or physical assembly qualification, and introduces
no separate pre-PCB prototype requirement.
