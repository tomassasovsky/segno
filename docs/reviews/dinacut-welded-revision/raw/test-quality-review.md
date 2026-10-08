# Test Quality Review

Reviewed 2026-09-14 against baseline `43c94a27`, using the current uncommitted
welded enclosure revision after final native export and full generation. This
is the test-quality role, not a manufacturing release or structural qualification.

## Coverage summary

- Stack: Python `unittest`, CadQuery/OpenCascade solids, ezdxf, and targeted
  `unittest.mock` patches for filesystem/output isolation and fault injection.
- The two new implementation modules, `lid_fit.py` and
  `manufacturing_package.py`, both have corresponding behavioral test modules.
  Generator changes also have four new and three modified test files.
- Numeric coverage: not measured. The configured CAD environment has no
  `coverage` package, and this enclosure workflow defines no numeric threshold.
- No state-management or UI code changed; those review categories do not apply.

Observed runs, using explicit modules from `hardware/enclosure`:

| Run | Result |
| --- | --- |
| Initial focused archive/shop-fit/lid-budget/rear-joint run | 25 tests passed |
| Final complete enclosure suite, 14 explicit modules | **126 tests passed in 94.280 seconds** |

The final run included `test_coated_supports`, `test_floor_rails`,
`test_floor_supports`, `test_lid_prop`, `test_lid_tolerance_budget`,
`test_manufacturing_fit`, `test_manufacturing_package`,
`test_manufacturing_pipeline`, `test_mid_platform_mount`,
`test_mini_sled_retention`, `test_platform_baffles`, `test_rear_joint_fits`,
`test_screen7_adjustment` and `test_shop_tolerance_fits`. Module names were
loaded explicitly; the known worktree discovery problem was not bypassed by
silently omitting tests.

## Behavioral coverage assessed

- Rear slots are reconstructed from emitted CUT geometry and compared with
  independent stadium solids. All nine front DRILL circles remain covered.
- The new tolerance calculation is checked against actual screw/plate Boolean
  intersections, including simultaneous axial/transverse displacement, paint,
  tilted screws, and an intentionally failing old slot size.
- Washer tests distinguish bearing area from complete slot coverage, exercise
  opposite washer float, reject loss of planar land, and inspect actual native
  lap edges and neighboring fixing pitch.
- Fold-envelope checks include interior angular samples and both sheet faces;
  the production calculation supplies the monotonicity argument rather than
  treating sampled corners as a mathematical proof.
- The rigid-pose tests independently verify all three contact equations and
  explicitly demonstrate that broad seat tolerances do not guarantee the
  proposed front-gap band. Coating checks are conditional on an accepted bare
  assembly and do not present themselves as weld or clamp-load tests.
- Disc/encoder tests include size, coating, bore eccentricity, the purchased
  washer dimensions and actual generated holder geometry. Physical printed
  dimensions remain an explicit release check.
- Removed rivet holes are checked as filled material at their former locations,
  not merely by absence of a source symbol. Front post-weld drilling remains
  non-CUT reference geometry.
- The archive tests cover exact five-part/three-format membership and bytes,
  material/thickness/quantity labels, exclusion of unwanted neighbors, missing,
  empty and stale artifacts, compression failure, changed archive contents,
  partial generation, and preservation of previous complete outputs.
- CAD/reference gates retain behavioral mutation checks for altered geometry,
  wrong rules/bends/drilling, open/crossing/retraced paths and malformed PDFs.
  Focused mocks isolate rendering or publication boundaries; they do not mock
  the geometry being asserted.
- Flat registration now uses laser circle/arc centers, including slot ends,
  rather than allowing deferred drilling to move the whole sheet. The added
  regression rotates and translates a real native lid, shifts all nine front
  deferred holes by a tolerated 0.0001 mm residue, and requires that small
  material difference to remain local. It then moves one drill by 0.10 mm and
  requires rejection. The unchanged whole-profile 0.01 mm² guard still governs.
  An independent synthetic native export also passed the new implementation at
  0.004050 mm² missing/extra and failed the baseline comparator.

## Resolved review finding

### Retarget the two native-flat mutations to retained holes — resolved

Locations: `hardware/enclosure/tests/test_manufacturing_fit.py:627` and `:655`.

The first review reproduced two `StopIteration` errors because the tests still
selected the intentionally removed Ø3.3 corner rivet circles. Both mutations
now select retained Ø2.5 base pilots. They preserve the 1 mm displacement,
content-hash tampering and geometric-mismatch rejection assertions. Both pass
in the final complete run. Native-lid parity failures seen during the first
run also pass after registration and native-row correction.

## Verdict

All tests pass the quality bar; zero unresolved test-quality findings remain.
The complete post-synchronization regression run and native parity checks pass.
This does not remove the independent structural/load hold or qualify
welded/coated joint bearing, physical printed fit, or the separate native
save/reopen preservation review.
