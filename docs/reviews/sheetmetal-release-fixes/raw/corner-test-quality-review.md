# Corner follow-up: test-quality review

Reviewed on 2026-09-05. Scope: final native base flat-pattern comparison,
approved corner geometry, generator enforcement through `_formed_record`, and
the new regression. No live Fusion operations or implementation edits were
performed by this reviewer.

## Coverage summary

- Final test run: **Pass — all ten tests**, 11.529 seconds, exit status 0.
- Framework: Python standard-library `unittest`, CadQuery and ezdxf.
- Coverage percentage: unavailable; the CAD environment has no `coverage`
  module, and the inspected CI has no enclosure coverage threshold.
- `flat_pattern_check.py` has behavioral coverage in
  `tests/test_manufacturing_fit.py` through the real source and native DXF
  fixtures. Existing assembly tests also exercise the successful generator
  integration.
- The base-specific native-flat checksum and material-parity failure paths
  are covered by the added generator integration regression.

Executed from the review worktree:

```sh
MPLCONFIGDIR=/tmp/segno-fab-audit/mpl \
  /Users/Tomas/Documents/Work/opensource/loopy/hardware/enclosure/.venv/bin/python \
  -m unittest discover -s hardware/enclosure/tests -v
```

## Behavioral quality

The new test uses the actual exported native flat and the generated source
DXF. Its success assertions require more than 100 reference holes and at most
0.01 mm² missing or extra material. The comparison is based on material faces,
including deferred drilling, rather than contour counts or a shared signature.

The four negative cases make meaningful engineering changes: restoring the old
6.0 mm relief diameter, removing the approved 0.15 mm front trims, moving a
mounting hole, and removing a deferred-drill hole. Matching the specific
`flat-pattern mismatch` failure ensures an unrelated DXF parse, open-wire or
registration error cannot satisfy the test. Independent temporary documents
prevent one mutation from contaminating the next. The test does not mock the
checker or reproduce its Boolean subtraction logic.

Additional read-only reviewer experiments transformed a temporary copy of the
actual native DXF:

- A 90-degree rotation plus a (31, -47) mm translation passed with 107 matched
  holes, zero missing area and zero extra area.
- An X reflection failed with 14,532.719926 mm² missing and extra material.

These checks support the registration behavior and the prohibition on mirrored
flats. They were temporary review probes, not additions to the committed test
suite.

The exporter retains non-CUT sketch and forming validation, captures the actual
base flat, and records its checksum. The generator checks the current source
signature, STEP checksum and native-flat checksum before comparing material.
The hidden-part visibility handling is straightforward `try/finally`; its live
Fusion evidence and state preservation are outside this review's tools.

## Resolved finding: generator rejection of a wrong native flat

Location: `hardware/enclosure/tests/test_manufacturing_fit.py:217`.

The initial review found that direct comparator failures did not protect the
generator integration from accidental removal. This is now resolved by
`test_generator_rejects_altered_or_geometrically_wrong_native_flat`.

The new regression copies the actual base source, native flat, STEP and manifest
into a temporary directory, first checks a valid `_formed_record('segno_base')`,
then moves one native 3.3 mm hole by 1 mm. It requires the checksum failure with
the old recorded checksum. Updating only that checksum simulates a fresh export
whose final material still disagrees with the source; the same generator
entrypoint must then reject it with `flat-pattern mismatch`. Both conditions
passed. Removing either enforcement now causes a meaningful regression failure.

The additional outside-contour negative case adds a real, closed 10 by 10 mm
laser contour beyond the sheet. It requires the dedicated outside-sheet
failure, covering the previous possibility of silently discarding an exterior
contour during Boolean subtraction. The existing successful geometry includes
boundary-crossing corner reliefs, so that valid case remains protected as well.

## Other quality checks

No tautological assertions, implementation-mirroring tests, unscoped mutable
fixtures, or assertion-free tests were found. State-management and UI test
conventions do not apply to this CAD-only change. No unrelated test expansion
is requested.

## Verdict

**All ten tests pass the quality bar for the bounded corner follow-up.** The
integration failure-path finding is resolved; no unresolved critical, important
or suggestion findings remain. Digital tests do not establish shop tooling,
bend repeatability or physical fit.

## Final targeted re-review: isolate the corner-relief mutation

The relief-negative subtest now selects only CUT circles with a 3.25 mm radius
at the four fold intersections: x = 0 or 846 mm and y = 0 or 419 mm. It asserts
that exactly four were selected before reducing their radii to 3.0 mm. This
excludes the same-diameter M6 grounding hole and ensures the expected mismatch
comes from the corner relief changes alone. The specific parity-error assertion
remains in place.

Independently reran the affected test on that final correction: **Pass**, one
test in 4.979 seconds, exit status 0. The command was the same CAD Python
`unittest discover` runner above with
`-p test_manufacturing_fit.py -k test_native_base_flat_matches_all_cut_and_deferred_drill_geometry -v`.
No implementation artifacts changed, and no new findings were identified.
