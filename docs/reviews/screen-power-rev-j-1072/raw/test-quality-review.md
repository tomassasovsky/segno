<!-- cspell:words nonqualifying -->
## Test Quality Review

### Scope and method

Reviewed the working change from `e98256a5a36f5341b9a521d63b6b951ca2b67f70` in `hardware/kicad/screen_power/check.py`, together with the changed relay mapping in `switch_circuit.py` and physical routing in `route_critical.py`. Applied the test-quality role to the repository's Python/KiCad validator and its built-in fault injections. Flutter test-file and state-management conventions do not apply to this scope.

### Final coverage summary

- **PASS** on stable final inputs at `2026-09-25T18:45:26.978075+00:00`: **36/36 self-test results true**, zero validation errors, and zero DRC/ERC findings or unconnected items.
- Reviewed final `check.py` SHA-256: `485dc24f5a5310ebc56504076fafb7a9512b6dbd9fe1764843f714861198ceb9`.
- Fresh complete report: `/tmp/segno-screen-claude-review/rev-j-reviewed-final-validation.json`; log: `/tmp/segno-screen-claude-review/rev-j-reviewed-final-validation.log`.
- The final run includes the regenerated Revision J schematic titles, fresh native schematic export/parity, 4 contact states, 16 upstream reachability cases, and 5,452 USB ground-reference samples.
- Line/branch coverage was not instrumented; no percentage is claimed. The final suite adds the redundant-via-island regression to the eleven added cases described below.

### Initial review evidence

- Fresh native run: **PASS**, `check.py hand --self-test`, using the KiCad Python selected by `build.sh`.
- **35/35 self-test results true**; CAD errors: 0. Fresh DRC: 0 errors, warnings, exclusions, and unconnected items. Fresh ERC: 0 errors, warnings, and exclusions.
- Report: `/tmp/segno-rev-j-test-review.json`; log: `/tmp/segno-rev-j-test-review.log`.
- Contact behavior exercises **4 relay-coil combinations and 16 upstream reachability cases**. These are explicit state/path counts, not line or branch coverage percentages.
- Line/branch coverage was not instrumented. No Python CAD coverage percentage is claimed. Tests are embedded in `check.py`; the absence of separate test files is not itself a gap in this existing workflow.
- Eleven added results cover the relay baseline, previous terminal mapping, wrong throw, polarity swap, cross-channel short, no-connect isolation, FET neck, capacitor feed, absent vias, insufficient via drill, and disconnected vias.

### Relay and routing test quality

The new relay graph represents physical terminals and applies a fixed contact mechanism independently of the generator's named-net contract. Expected connector reachability depends on the relay state and connector polarity, not on the generator's relay mapping. All four coil combinations also exercise one channel enabled while the other is disabled.

Independent checks performed during review:

1. Loaded the actual old generated netlist from the base commit. `check_relay_contacts` rejects it with **8 `relay_behavior` errors**, demonstrating that the previous two-NC-terminal wiring cannot pass the new test.
2. Renamed every connected net to arbitrary names while preserving physical terminals. The contact behavior check still passes, confirming independence from signal labels.
3. Retained only one, two, or all three of the current dedicated vias on disposable board copies. The power checker rejects counts one and two and accepts three.
4. Removed F101 pin 1 and tracks narrower than 1.9 mm from a disposable copy of the delivered board. Q4.2 remains connected to F201.1 through the added vias. The actual design therefore passes the intended stronger bypass property.

The FET and capacitor mutations assert the relevant physical-path failure, rather than merely comparing assigned widths. The capacitor mutation accounts for neighboring copper overlap, avoiding the false premise that narrowing only the final segment must disconnect the wide path. Contact positive controls require a clean original graph, and the overall validator independently requires the original board to pass before CAD readiness can be reported.

### Resolved finding — original evidence

**Important — Prove the via path bypasses the fuse barrel**

Location: `hardware/kicad/screen_power/check.py:438` (qualifying-via connectivity), with the missing fault case in the via mutations at line 672.

The initially reviewed reachability test used the complete board graph, including F101 pin 1's plated barrel. A via could consequently reach both Q4.2 and F201.1 through its bottom connection and that barrel even if its top copper was an isolated island. Requiring wide copper under the via on both faces did not prove that the upper copper continued to the distribution bus. The initial missing/small-drill/disconnected fault cases did not exercise this failure.

Reproduction on a disposable copy:

- Remove the three current SWITCHED_5V vias, the four thin F.Cu router tails associated with those vias, and the two original F.Cu stitching-spur segments.
- Place three through vias, each with a 0.45 mm drill and 0.9 mm diameter, at `(39, 20)`, `(40.1, 20)`, and `(41.2, 20)` on the existing 3 mm B.Cu feeder.
- Join them with one 3 mm F.Cu track from `(39, 20)` to `(41.2, 20)`. This top island has no onward path to the distribution bus except through the vias back to the lower feeder and the original fuse barrel.
- The initially reviewed full validator reported **CAD ready**, **35/35 self-tests**, and **zero DRC/ERC findings**. Mutation: `/tmp/segno-rev-j-redundant-vias.kicad_pcb`; report: `/tmp/segno-rev-j-redundant-validation.json`.
- Remove F101.1 from this mutation and discard sub-1.9 mm tracks: Q4.2 no longer reaches F201.1. The same check passes on the actual delivered board.

Requested fix: on a disposable board, remove F101.1's pad, strip narrow tracks, retain qualifying vias, and verify physical Q4.2-to-F201.1 connectivity. Add the connected-but-redundant top-island mutation as a regression case. This proves the intended alternate path without claiming calculated current sharing among individual vias.

### Resolution verification

The final implementation removes F101.1 from a disposable board, strips sub-1.9 mm tracks and nonqualifying vias, rebuilds connectivity, and requires Q4.2 to reach F201.1. The added `redundant_power_vias_detected` self-test expects exactly the `power_via_bypass` failure on the island mutation, so unrelated failures cannot make this regression case pass.

Independently reran `check_power` against both the actual native board and the original DRC-clean mutation retained from this review. The actual board returns no errors; the original mutation now returns exactly one `power_via_bypass` error. Targeted evidence: `/tmp/segno-rev-j-bypass-recheck.json`.

The first full recheck overlapped the parent's schematic title regeneration and correctly failed its source-stability guard, although 36/36 self-tests and DRC/ERC passed. That run is not used as final readiness evidence. The subsequent complete run on frozen sources passed and is recorded in the final coverage summary above. No implementation or board changes were made by this reviewer.

### Verdict

**All tests meet the quality bar; no unresolved findings.** The relay regression checks reject the actual previous defect, and the strengthened via guard rejects the demonstrated false-pass mutation while accepting the unchanged native board. These results establish CAD connectivity only; they do not establish thermal performance, USB signal integrity, or assembled-device behavior.
