# Test-quality review — Revision K

Reviewed 25 September 2026, independently of the routing implementation.
Baseline: `9a5798be6c4ea9b0aae2a88fe7168b6751cab441`.
Reviewed native board SHA-256:
`d35484d551cf8f526f62c4356accbff0492c28999beb0e8830801c39f00c83da`.
This final recheck includes all eight tapers, including the front AUX approach
and rear switched-power approach, and the explicit permitted layers per net.

## Result

No actionable test-quality defect found in this focused revision. The existing
behavioral and fault-injection suite passes on the actual saved board. Additional
independent mutations demonstrate the newly added C1 guard and the revised
zone allowlist reject their relevant faults. The underlying power routes also
pass with every taper zone removed, so the taper fill is not hiding a missing
minimum-width track path in the reviewed board.

This review covers the changed routing/C1 placement, new capacitor model
assignments and validation changes. It does not independently approve the final
manufacturing publication, unfinished documentation, full historical PR, or an
assembled board. The reviewer previously authored the wiring documentation
changes; those documents are explicitly outside this independent code/test
verdict.

## Executed verification

- Ran the project's `check.py hand --self-test` with KiCad 10's Python against
  the saved board, writing results outside the repository. **36/36 checks
  passed**, with no validator errors. Native ERC and DRC each reported zero
  findings, and DRC reported zero unconnected items.
- Confirmed the board hash before/after the independent experiments matches
  the hash above. No repository implementation or native board was modified.
- The validator sampled **5,452** points below the USB tracks on the actual
  ground fill. Schematic/netlist/native-pad parity, relay contact behavior and
  actual copper connectivity passed.
- Inspected the successful full-build log: generation, placement, critical
  routing, remaining routing, finishing, self-tests, fresh export validation
  and package publication reached completion. I did not rerun the mutating
  full build while other reviewers were inspecting the frozen board.
- Reviewed the export gate: it performs fresh validation, rejects unresolved
  zone checks, compares source hashes before publication, verifies portable
  model coverage, and only replaces the prior complete package after the new
  package exists. This is source-path inspection, not a new independent CAM
  equality comparison.

The applicable stack is Python/SKiDL/pcbnew plus native KiCad, not Dart/Flutter
state-management code. The project uses native CAD checks and fault injection
for this board. No line-coverage percentage is available or claimed; a line
percentage would not establish physical connectivity or component correctness.

## Independent mutations for the Revision K changes

All experiments used disposable copies of the frozen board. Expected outcomes
were asserted; the script exited successfully.

| Mutation | Observed outcome |
| --- | --- |
| Narrow all three 0.8 mm AUX segments feeding C1 to 0.25 mm | Revision K specifically rejects the J1.1 → C1.1 path for lacking continuous 0.8 mm copper. |
| Run the same narrowed C1 board through the baseline Revision J power checker | Baseline accepts it, proving the new check catches behavior the old validator missed. |
| Remove all eight `POWER_TAPER` zones | All required minimum-width power paths and dedicated-via bypass still pass. The reviewed board has continuous underlying track copper. |
| Rename a taper to an unapproved zone name | Rejected by `ground_planes`. |
| Give a taper an unapproved power net | Rejected by `ground_planes`. |
| Move a common-source taper from its permitted F.Cu layer to B.Cu | Rejected by the per-net layer allowlist; the now-unfilled layer is also rejected. |
| Remove F.Cu GND while retaining the front taper zones | Rejected because the actual ground pour is missing; the allowed power zones cannot substitute for it. |

These additional experiments are review evidence, not extra tests already
counted in the committed 36-check suite. They exercise real board objects and
validator behavior rather than matching source text or reproducing the
production routing formula.

## Quality of the retained coverage

The test suite preserves the important protections from Revision J:

- Relay graph behavior is evaluated with both relays independently on/off,
  checking correct endpoint reachability. The prior disconnected-common
  mistake, wrong throw, swapped polarity and channel crossing are deliberate
  failure cases rather than merely another copy of a pin-map assertion.
- Power checks rebuild physical connectivity after deleting thin tracks and
  inappropriate vias. The dedicated-via test removes F101's shared pad and
  rejects a mutation in which three apparently connected vias rely on that
  pad instead of providing a real bypass.
- USB track cutting, missing reference fill, wrong header pitch and an illegal
  host-power assignment are rejected. Assembly checks reject inadequate lead
  holes, a mounting-hardware short, missing/disabled models and surface-mount
  substitutions.
- Revised C1 placement and the wider common-source bends reach the actual
  saved board; native checks and the independent minimum-width experiments
  operate on that result. No broadening of the new taper allowlist to arbitrary
  nets or inner layers was observed.

The model coverage guard proves models are assigned, visible and resolvable;
it does not prove their body dimensions. Manufacturer-body dimensions and
connector-mating clearance belong to the separate component/assembly audit.
Likewise, the tests do not establish MOSFET thermal/SOA performance, fuse
coordination, actual USB compliance or five-second screen discharge timing.
Those limitations remain explicit and are not counted as passing tests.

Critical: 0. Important: 0. Suggestion: 0.
