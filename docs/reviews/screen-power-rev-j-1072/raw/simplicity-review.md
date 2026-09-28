# Revision J simplicity review

## Simplification Analysis

### Core Purpose

Correct the screen relay wiring to use the physical common contacts, route the
changed USB connections, strengthen the shared power copper, and verify the
result against the relay mechanism and delivered board geometry.

Reviewed the working changes in `hardware/kicad/screen_power/check.py`,
`route_critical.py`, `switch_circuit.py`, and `finish.py` against
`e98256a5a36f5341b9a521d63b6b951ca2b67f70`.

### Unnecessary Complexity Found

None that warrants an actionable finding in this focused correction.

- The relay checker uses physical terminals as graph vertices and adds the
  contact edges for all four coil states. This is a compact independent model
  of contact behavior, not a second circuit generator. Removing it in favor of
  pin-name comparisons would lose the protection against the original fault.
- Mutation inputs are ordinary local copies. The small pin-remapping table
  shares the repeated mutation procedure without introducing a general test
  framework. The cross-channel and grouped no-connect cases retain separate
  code because their transformations and expected outcomes differ.
- The routing helper's additional breakout option serves the two concrete
  termination geometries now present. Its small local `spread` helper keeps
  the new geometric construction legible without adding an external API or
  speculative configuration.
- The power-width, capacitor-feed, and via checks address separate physical
  requirements. The via-to-track distance calculation checks actual copper
  contact; a nominal count of matching net names would not serve the same
  purpose. The additional board copies isolate deliberate faults from later
  checks and follow the existing validator's approach.
- Rounded keepout ends directly address the relay contact spacing. The
  revision and title changes are direct updates with no compatibility path.

### Code to Remove

None. Estimated LOC reduction: 0.

### Simplification Recommendations

Keep the present scope. Extracting a reusable graph library, route framework,
or mutation runner would add indirection for this board's small fixed cases.

### YAGNI Violations

None found. New behavior is tied to the corrected relay contacts, present
power paths, and Revision J identification.

### Validation and Limits

Independently parsed all four Python files successfully. Reviewed the added
checks and mutations statically; did not rerun the parent's full KiCad
validation or treat its reported results as independent verification here.
The test reviewer is separately evaluating the power-via bypass requirement
with the F101 pin 1 plated terminal removed; this report does not settle that
behavioral question.

### Final Assessment

Total potential LOC reduction: 0%.

Complexity score: Low for the required physical checks.

Recommended action: Already minimal.

Critical: 0. Important: 0. Suggestion: 0.
