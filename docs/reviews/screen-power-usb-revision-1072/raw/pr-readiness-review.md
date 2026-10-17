<!-- cspell:words unconfigured -->

# Revision M interim PR-readiness review

Scope: `355882d..d4fde195` plus the current working changes for the USB Revision M correction. Readiness was checked while native Revision M placement/routing, its 75-control run and new CAM publication were explicitly pending. Their pending state is not reported as a defect. This is not a complete review of the stacked PR or approval to merge/order.

## Formatting and static checks

- `git diff --check 355882d` passes.
- AST parsing passes for all eight changed Python sources/evidence scripts.
- The repository's workflow configuration declares Dart/Flutter formatting and analysis; this correction changes neither Dart nor Flutter. No project Python formatter or linter configuration was identified, so no unconfigured formatter was imposed.
- Checked changed source and evidence scripts for merge markers, TODO/FIXME/HACK and temporary skips. No actionable artifact found. Printing numerical output in the standalone evidence utilities is intentional, not production debug logging.
- Local Markdown links in changed non-raw documents resolve.

Full CI and native build gates remain pending and are not inferred from these source checks.

## Resolved release-status contradictions

### Resolved — Replace stale fabrication acceptance in PR and issue bodies

Locations: PR #1080 body (Result, Verification and Remaining gates); issue #1072 body (Current implementation, Evidence and files, Remaining gates).

At the initial review both began with a correct Revision M order hold. Later, however, their Remaining gates sections still state without historical qualification that the current bare-board fabrication files are accepted. Their implementation text calls the 7.608 A AUX budget current, and the verification section presents the previous 61-control/old-CAM result as the current release. The actual revised source budget is 7.708 A, the planned full screen run is 75 controls, and the screen archive remains Revision L and withdrawn. The hold banner does not remove these later contradictory directions.

Fix: rewrite those bodies around the current Revision M status, or explicitly fence the previous numbers/results as historical Revision L evidence. Keep the current-head CI/review labels pending and retain the specific instruction not to order the old screen ZIP. This does not require waiting for routing: a correct in-progress description can be published now and replaced by actual native results later.

Observed PR head: `d4fde1951cdfd384eced740d9f599c255ebe2b95`. Labels correctly remain `stage:in-review`, `autonomy:blocked-verify`, `ci:pending`, `review:pending`. The only reported head check was a neutral GitGuardian result; it is not full repository CI. `Closes #1072` and the stacked base dependency are present.

### Resolved — Synchronize the circuit assessment's source provenance and review status

Location: `docs/reviews/screen-power-usb-revision-1072/circuit-assessment.md:140` (and its concluding review-state paragraph).

The printed `check.py` SHA is `ccbd1f5a71d7f74f687b110e080c0f5e6ad9db3b7c9613d5007fd2d1206006a3`, while the current file and `circuit-evidence.json` both report `b68482bb0bd5350531708bda32114d4c0f38c3f8074dbea83a5087ed01a5539d`. The assessment's conclusion also says independent circuit review is still pending while the current revision disposition records completed circuit/source reviews. The numerical evidence itself is current; the prose snapshot is stale after the state-axis cleanup.

Fix: copy the exact validated source hashes from the evidence and distinguish completed source/circuit reviews from pending native layout/release review. Preserve limitations and historical raw-review hashes; do not claim those old snapshots reviewed the later file.

## Positive consistency checks

- Source hashes in `circuit-evidence.json` match the current `check.py` and `switch_circuit.py` exactly.
- `impedance-evidence.json` records analysis model SHA `885546038498869f7d1e7df3d52151b9e29f3e7ab91d6febf1bfedf8e8135e04`, matching the current script.
- The source/netlist records contain 50 populated components across 26 purchased MPNs; bare shield pads are omitted from the purchasing BOM. Mounting-hole records do not become purchased components.
- The component cost table totals 50 fitted parts and $44.95. Every line extension and the grouping sum agree; $44.95 + $7.81 + $23–48 = $75.76–100.76. Optional donor cables replace the original cable allowance, and default donor/contact quantities are zero.
- The updated AUX arithmetic is 4.250 + 0.100 + 2.400 + 0.498 + 0.120 + 0.140 + 0.200 = 7.708 A. Its nominal 10 A headroom is 2.292 A. All-120-pixel white totals 12.010 A with the stated idle/control/screen allowances, so the documented exclusion is consistent.
- The 0.10 A relay/control allowance is separate from the 4.25 A MOSFET-switched screen budget; MOSFET loss calculations are not incorrectly raised by coil current that bypasses them.
- Cable pin maps agree between README, circuit records, wiring notes and external BOM: 1 VBUS, 2 D−, 3 D+, 4 GND; host VBUS feeds only sensing, device VBUS is switched; four shield drains go to separate corresponding GND pads. Main power retains separate heavier conductors. USB-C legacy attachment remains in the factory C plug and is not falsely assigned to an XH pin.
- Cable construction, minimum supply floor, hot restart, mask/etch tolerances and full-channel qualification limits are explicit. The field-model target is not advertised as supplier-guaranteed impedance.
- The manufacturing manifest is correctly marked screen hold, with the old screen archive withdrawn. Console/ring files remain outside this correction.
- The source commit is descriptive and contains no assistant attribution. Generated schematic/netlist/BOM and numerical evidence are intentional review/manufacturing source artifacts in this repository; the generic convention against arbitrary build outputs is not a reason to delete them.

## Corrections independently verified

1. Re-read PR #1080 and issue #1072 through GitHub after their complete rewrite. Both now state the Revision M hold consistently, identify the retained Revision L archive as withdrawn, give the 7.708 A AUX budget, and distinguish 24 current source states/13 controls from the pending 75-control native run. Historical results are expressly historical. Labels remain pending; no merge or fabrication approval is claimed.
2. Re-read the local circuit assessment and hash the actual source. Its printed `check.py` SHA now matches `b68482bb0bd5350531708bda32114d4c0f38c3f8074dbea83a5087ed01a5539d`; the conclusion correctly distinguishes complete independent source reviews from pending native layout/CAM verification.
3. Re-ran the scoped whitespace check after the fixes; it passes.

## Verdict

Both documentation/tracking findings are resolved. Critical: 0; Important: 0; Suggestion: 0 unresolved. No new circuit, harness or cost inconsistency was found in this scoped pass. Native layout, 75 controls, exact manufacturing export comparisons and final publication review must still occur as already planned. Do not mark the whole PR reviewed, merge-ready or fabricated from this report.
