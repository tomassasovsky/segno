# Architecture review — welded enclosure revision

Reviewed the working source changes against `43c94a27` on 2026-09-14. This is
an independent architecture review of the manufacturing implementation, not a
fabrication release or a certification of the mechanical design.

## Stack and scope

The changed subsystem is Python, CadQuery/OpenCascade, ezdxf and the Autodesk
Fusion Python API. No Dart, Flutter, Bloc, application presentation layer or
dependency manifest changed, so application-specific VGV layering rules do not
apply here. The applicable repository principles are separation of concerns,
one-way dependencies, simple implementations and removal of obsolete paths.

Reviewed:

- `hardware/enclosure/segno_enclosure.py`: geometry and metadata changes,
  handoff generation, formed-record validation, washer placement and package
  orchestration.
- `hardware/enclosure/lid_fit.py`: bounded section calculations and explicit
  reference-data dependency.
- `hardware/enclosure/manufacturing_package.py`: exact order membership,
  shipping names, artifact freshness and archive publication.
- `hardware/enclosure/fusion_export_formed.py`: native validation and export
  contract after removal of the bracket parts.
- `hardware/enclosure/_fold_from_dxf.py`: removed bracket assembly and obsolete
  collision exclusions.
- Associated new and changed enclosure tests, the implementation plan and
  `FUSION_MODELS.md` release workflow.

## Layer separation

Violations found: 0.

The enclosure generator remains the source of design geometry and drawing
metadata. It imports the packaging helper and supplies the order table and
output directory explicitly. The helper does not import the generator,
CadQuery, Fusion or drawing-rendering code. It is responsible for membership,
filenames, current-run file checks and ZIP contents, while the generator keeps
geometry validation before package publication.

The fit-calculation module depends only on the standard library and its
existing checked-in seat-datum fixture. It does not mutate CAD, write release
artifacts or treat its calculations as manufacturing approval. Native bend
reference checks and independent solid/contact tests connect the reference
calculations to the actual geometry.

## State and lifecycle

Issues found: 0.

`SeatPose` and `RearJointCheck` are immutable result objects. Package writing
checks the complete requested set, stages and verifies each archive, then
replaces each ZIP atomically. The contract correctly describes atomicity per
archive; it does not promise a filesystem-wide transaction. Temporary staging
is scoped and removed on failure. Geometry and native export state remain
outside this helper.

The existing generator run-start freshness model is preserved. A partial run
does not replace the metal order. Obsolete metal archives are removed only
after successful replacement of the complete metal archive.

## Dependency direction

Direction or circular dependency violations found: 0.

- Generator → manufacturing-package helper → standard library.
- Generator → flat-pattern verifier → CadQuery/ezdxf.
- Standalone DXF assembly viewer → generator dimensions.
- Fit calculations → standard library and checked-in seat datums.
- Fusion exporter → standard library, Fusion API and serialized generated
  handoff; it does not load the host generator or its CAD dependencies inside
  Fusion.

The serialized Fusion boundary retains explicit part-set validation,
operation-curve checks, sheet-rule and fold checks, actual front-hole checks,
content hashes and final-flat parity. Reducing the formed set to base and lid
does not weaken those checks for the retained parts. The documented separate
verification of both saved and reopened Fusion documents remains necessary;
the exporter intentionally operates on the populated document.

## Structure and change scope

Issues found: 0.

The two new modules have narrow responsibilities and use existing dependencies.
The package helper intentionally rejects a changed metal part set, quantity or
thickness until the reviewed order contract is updated. This is an explicit
manufacturing constraint, not a generalized configuration system.

The obsolete bracket generator, parameter set, DXF routes, formed-export routes,
assembly builder and bracket-only collision exemptions are removed. Purchased
washers and shim references stay separate from the five fabricated metal parts.
The fit functions keep geometric passage, washer bearing and physical clamp
qualification distinct.

## Validation and limits

- Independently ran `tests.test_manufacturing_package`: 10 tests passed.
- Read the fit-budget, rear-joint and manufacturing pipeline tests, including
  missing/stale/empty package artifacts, exact member bytes, slot solid
  passage, washer bearing and native reference constraints.
- Did not run the generator or modify implementation files; the parent task
  was synchronizing native models and final artifacts concurrently.
- This review does not certify final generated PDF layout, reopened Fusion
  state, supplier capabilities, weld distortion, clamp strength or assembled
  stomp performance. The separate structural release hold is intentional.

## Verdict

Architecture is clean for the reviewed source revision. No actionable
architecture findings.

## Final architecture delta review

Reviewed the subsequent `flat_pattern_check.py` registration change and the
revised current manufacturing contract in `hardware/MANUFACTURING.md`.

The new `_round_centres` helper stays within the geometry-verification layer.
It uses ezdxf's existing primitive expansion and coordinate transformation,
collects circular and slot-end datums, and deduplicates split arcs by geometric
centre and radius. Removing deferred DRILL features from source registration
does not remove them from verification: complete CUT/VENT/DRILL material still
passes through the same independent planar Boolean comparison. The prescribed
mirror convention, rigid transform search and area threshold are retained.
No new dependency, reverse import, compatibility branch or concern mixing is
introduced.

Independently reran both registration regressions: the slotted-lid test with
all nine deferred bores displaced by 0.0001 mm, followed by a rejected 0.1 mm
single-hole error, and the small-drill-residue rigid-registration test. Both
passed. Their temporary fixtures do not modify generated release files.

The manufacturing guide now describes the same five-part, fifteen-file metal
order and separate native, packaging and physical-release responsibilities as
the implementation. It preserves the post-weld/pre-coating front operation
and explicitly separates successful digital checks from structural and
supplier qualification. The parent reported a passing full generator and
126-test suite; this review's own execution evidence remains the ten package
tests and the two registration tests recorded above.

Final architecture delta findings: 0. The architecture verdict remains clean.
