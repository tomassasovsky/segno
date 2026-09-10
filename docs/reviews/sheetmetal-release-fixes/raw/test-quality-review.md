## Test Quality Review

### Scope and evidence

Reviewed the Python enclosure changes against `1d14d701ee9f6c3ad304a63fc60a79e3681afbd1`, including the new test file, native export script, native STEP manifest, plan and release record. The applicable stack is Python `unittest`, CadQuery/OpenCascade and ezdxf. There are no Dart, state-management or UI changes in this scope.

The documented test command passed all five tests. A second run with an in-memory assembly-placement mutation also passed all five tests; that result exposes the finding below. Both runs wrote generated files only into temporary directories. No Fusion operations or source edits were performed.

### Coverage Summary

- Test run: **Pass**, five tests, approximately three seconds of test execution.
- Coverage: no enclosure coverage threshold or coverage-enabled CI job is configured; the available CAD environment does not contain `coverage.py`. No percentage is claimed.
- Files with automated tests: one of the two changed/new production Python files is exercised directly (`segno_enclosure.py`).
- `fusion_export_formed.py` has native Fusion validation evidence recorded by the author, but no automated test file. Its live application dependency limits ordinary headless execution; author-only native checks are distinct from CI.
- Existing generator assertions provide additional geometry, drawing and package validation. The author reports a successful full generator run; this reviewer did not regenerate production artifacts.

### Regression test quality

- Post geometry: useful independent live-plane fixture, coating gap, floor datum and cylindrical bend-radius checks. These assertions would catch the previously incorrect post height and joining-cube model.
- Buck/front DXFs: useful readback of actual generated entities, including supplier pitch and the deferred DRILL/CUT distinction.
- Monitor and stands: actual STEP round-trip, single-solid validity, floor seating and solid interference are checked. The invoked production builder also checks monitor contact.
- Native cache: meaningful negative tests alter an actual DXF mounting hole and exported STEP bytes, then verify rejection.
- Metal assembly: validity and eight-part count are checked, with useful base/lid/post assertions. The two rear brackets, removable rear panel and ring disc have no independent placement assertions.

### Findings

**Important — Verify every metal part's assembly placement**

Location: `hardware/enclosure/tests/test_manufacturing_fit.py:99`.

The test is named `test_generated_metal_assembly_has_all_eight_parts_in_their_seats`, but only base, lid and post seats are examined. The new `build_step()` trusts placement matrices from `formed/manifest.json` and calculates the rear-panel and ring placements separately. Those paths can put otherwise valid solids in the wrong assembly positions without failing any current test.

Confirmed with an in-memory mutation: wrap `_formed_record()`, deep-copy its returned record, and add **100 mm** to `matrix[0][3]` for both `segno_corner_bracket_rear` placements. Run the entire unchanged test module with that wrapper. **All five tests still pass**, including the assembly-seat test. This is a coverage gap, not a claim that the current checked-in brackets are displaced.

Add independent geometric checks for both bracket seats and their mating-hole axes, the removable rear-panel plane/hole alignment, and the ring's shaft axis/seating plane. Use released assembly datums or measured mating geometry as the oracle rather than deriving expected placement from the same manifest matrices being tested. Include a deliberate misplaced-part case, such as the +100 mm bracket mutation, to demonstrate that the check detects the failure.

### Anti-Patterns Found

No tautological assertions, mocked units under test, missing assertions, or unrelated framework conventions were found. Numeric fixtures for measured hardware are appropriate here. The assembly test's broad name currently promises more coverage than its assertions provide; the finding above addresses the behavior rather than requesting a naming-only change.

### Recommendations

1. Complete the assembly placement coverage for the four currently unchecked solids and verify rejection of a deliberately displaced part.
2. Keep the release record explicit that native Fusion sweeps, visual PDF inspection and physical first-piece checks are separate from these headless regression tests.

### Verdict

Fix **one Important test gap** before treating the assembly placement regression coverage as complete. The current tests pass; they do not themselves prove fabrication release, and the rear-panel finished-thickness hold remains explicitly open.

### Re-review addendum — assembly coverage correction

The finding is **resolved**. The updated assembly test verifies both bracket seats and all ten rivet-hole axes against the base, the rear-panel seat and its four mounting-hole axes against the base, and the ring's shaft axis and seating plane against the lid aperture and independently recorded plane. Expected seats are recorded assembly measurements rather than values read from the manifest under test.

The test includes deliberate displacement of the brackets and requires detection. I also independently repeated the original mutation at the `_formed_record()` boundary, shifting both bracket placement matrices by +100 mm in X before assembly generation. The updated test fails at the bracket-seat assertion (`100.1 != 0.1`), confirming that the original failure is now caught end to end.

All **six** tests passed without mutation. The additional headless test directly exercises the native forming validator using the captured Fusion record and rejects modified sheet thickness, fold angle, fold sign, source line, drill position, radius and through-depth. Both changed/new production Python files now have direct automated coverage, while actual Fusion extraction remains separately validated in the live application by the author.

Current test-quality verdict: **no unresolved findings**. This updates the earlier five-test result and finding; physical release conditions remain outside the headless test verdict.

### Re-review addendum — converter correction, 2026-09-05

The earlier converter coverage was insufficient for the populated Fusion assembly. The original test checked the generated base mounting holes, not the identity, count, placement or visible geometry of imported converter instances. The user subsequently found floating parts and plain clearance blocks. The author's investigation found that old nine-body `buck_10a` occurrences had survived proxy deletion, a naming collision renamed the newly imported blocks, and a name-based check examined the old geometry. Neither the earlier passing tests nor my earlier test-quality verdict established that the live converter replacement was correct.

For this bounded re-review I examined `_buck_reference_solid()`, `build_buck_reference_step()` and the new converter regression test. The source now distinguishes the approximate visible housing from a separate conservative clearance envelope. The test reads both exported STEP files back and checks single-solid validity, the supplier's 63.7 ×57.6 ×22 mm dimensions, the floor datum, envelope containment, both Ø6.5 mounting axes at 53.9 mm pitch and 2.5 mm transverse offset, and clearance over the mounting ears. It avoids requiring particular face counts or fin construction details, which are deliberately approximate.

All **seven** tests passed in this review. I independently replaced the visible-housing builder in memory with the previous full-height box and two through-holes. The new converter test rejected it at the ear-access intersection check (approximately **571.86 mm³**, limit 0.001 mm³). This confirms that the previous block representation no longer passes the source-artifact regression test.

No unresolved test-quality findings in this small source change. These tests still do not inspect the active Fusion document or prove removal of old occurrences, exactly two replacements, or their live placement. The author's reported removal and reimport must be supported by corrected native assembly evidence independently of this headless result. No Fusion operations or production artifact regeneration were performed by this reviewer.
