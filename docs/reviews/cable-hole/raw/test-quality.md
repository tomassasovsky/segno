# Test-quality review: closed stadium cable hole

Scope: the current change to `hardware/enclosure/tests/test_platform_baffles.py` and its corresponding source delta against `/tmp/segno-cable-hole/before`. Python `unittest`, CadQuery and OpenCascade are the applicable tools; Dart and Flutter checks do not exercise these CAD changes.

## Execution and coverage

Independent focused run: `/Users/Tomas/Documents/Work/opensource/loopy/hardware/enclosure/.venv/bin/python -m unittest discover -s hardware/enclosure/tests -p test_platform_baffles.py`.

Observed result: all 5 tests passed in 1.520 seconds. No numerical code-coverage claim is made; the checks exercise generated and reimported STEP solids for both collar heights.

## Behavior verified

- The hole is a closed 8.6 by 13.5 mm vertical stadium, with R4.3 ends and a 4.9 mm straight section.
- The lower and upper limits are 6.95 and 20.45 mm above the bare case underside. Test datums are independent of the source cable-cut constants.
- The expected passage is constructed from cylinders and a box, independently of the source `slot2D` operation. Bidirectional void comparisons reject a rectangular opening or a different radius.
- Full-thickness solid probes at the bridges, side edges and outer corners prevent a missing rear wall, oversized opening or open-top slot from passing an empty-intersection assertion.
- The two approximate measured vertical placements, 7.45 and 8.5 mm above the case underside, each admit the assumed 7.6 by 11.45 mm stadium fitting with a 0.5 mm profile offset across the complete wall thickness.
- Existing 2.4 mm collar walls, four M3 through-hole stations, original sled seating and 0.2 mm sliding clearance remain covered.

## Quality assessment

No actionable findings. These tests inspect resulting geometry instead of matching source text or mocking the operation being checked. Shared generation happens once per class, temporary exports are cleaned, and test names identify the relevant geometric behavior.

The stadium-envelope test explicitly excludes an unmeasured rectangular fitting. Physical cable shape, connector passage, PETG printing tolerance and structural strength remain outside this test's claims.
