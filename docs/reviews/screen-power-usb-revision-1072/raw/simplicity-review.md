# Revision M simplicity review

Reviewed source range: `355882d..d4fde195` in the screen-power publication worktree, followed by the working-tree resolution of the duplicate pickup calculation. This is a source and validation-code review, not approval of the pending native routing or manufacturing archive.

## Core purpose

Move relay-coil energy off host VBUS, preserve independent host-presence and GPIO qualification of each USB data path, retain the two-layer hand-soldered construction and XH4 cable interface, and provide separate shield-drain pads. The numerical and field-model scripts document bounded engineering evidence for the requested USB assessment.

The circuit change is appropriately small: one extra series MOSFET and two resistors per channel reuse the existing GPIO buffer and coil suppression. No new USB controller, suspend detector, firmware interface, connector adapter, or compatibility path was introduced. The shield pads do not create purchased components or fabricated 3D models. The narrow model-exemption checks preserve validation of actual populated parts.

## Resolved unnecessary complexity

The initial review found one minor duplication in `hardware/kicad/screen_power/check.py:743–768`. `numerical_checks()` computes and checks the initial relay pickup bound from hardcoded coil and driver assumptions, then `usb_power_margins()` independently repeats that same calculation and threshold at lines 594–610. These are not independent validation approaches: both implement `4.75 × 130.5 / (130.5 + 10)`, compared with 3.38 V. Maintaining both can allow the older summary values to diverge from the per-channel USB report when the drive allowance changes.

Suggested simplification: calculate the USB margin result once before constructing the main numerical report, use its per-channel result for any retained summary fields, and retain only the pickup guard inside `usb_power_margins()`. No general-purpose abstraction is needed. Alternatively remove the obsolete duplicate summary fields and calculation if no consumer needs them; project policy does not require backward compatibility.

Resolution verified: the duplicate formula, guard and legacy summary fields have been removed. `usb_power_margins()` now owns the pickup calculation and threshold; the initial-at-23°C limitation is documented beside it. No new abstraction or compatibility path was introduced.

## Removal completed

- Removed the duplicate pickup explanation, formula, check and legacy report fields from `numerical_checks()`, retaining the qualified calculation within `usb_power_margins()` (net reduction: seven lines).
- No document removal recommended.

## Validation complexity assessment

The physical pin contract and directed-body-diode state model serve distinct purposes. The state model catches bypassed host qualification, crossed host channels and reversed drivers through behavior, rather than only comparing an expected table. The mutation controls exercise each of those real failure modes. The missing-element and resistor-value controls intentionally enforce assembly assumptions needed by the numerical bounds. These are useful safeguards in this hardware workflow.

The repeated suspend state makes the intended invariant explicit: suspend does not need a newly implemented detector because relay energy comes from AUX while the host remains connected. Although the ideal model does not simulate USB signaling or timing, the report labels that limit. No additional circuit simulation framework is needed for this check.

The standalone finite-element assessment is isolated under the review directory, relies on existing numerical libraries, includes an analytical control, and is not added to the PCB production dependency chain. Its geometry and mask/domain options support the documented sensitivity study; they are not speculative product configuration.

## Reproduced evidence

Read `AGENTS.md`, the build/test section of `docs/PROGRESS.md`, `docs/TRACKING.md`, the simplicity role and common review contract. Inspected changed circuit, validator, model and schematic handling, the source verification script, impedance model/driver, and engineering assessments.

Using KiCad's bundled Python, loaded the current generated netlist and invoked the pin contract, numerical checks, state model and USB fault controls without editing source or generating PCB output:

- No contract or numerical errors.
- All 48 ideal supply/GPIO/host/suspend states and 96 coil paths pass.
- All 13 USB control results pass.
- Both channels report the same 4.411921708 V initial coil bound and 0.051505051 mA normal host load including the stated leakage allowance.

## Final assessment

Critical: 0. Important: 0. Suggestion: 0 unresolved.

Complexity is low for the requested circuit and evidence scope. The duplicate pickup calculation has been simplified; no redesign or broader framework is warranted. The source contracts, 48 states, 96 coil paths and all 13 USB controls were rerun after the fix and still pass with the same 4.411921708 V coil result. Native placement/routing and manufacturing validation remain explicitly outside this source-only approval.

Rechecked `check.py` SHA-256: `ccbd1f5a71d7f74f687b110e080c0f5e6ad9db3b7c9613d5007fd2d1206006a3`. No implementation files were edited by this reviewer.
