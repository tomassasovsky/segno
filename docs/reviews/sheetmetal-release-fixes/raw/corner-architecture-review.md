# Corner completion: architecture review

Date: 2026-09-05. Worktree: `codex/sheetmetal-release-fixes`, uncommitted corner completion on top of the earlier converter and rear-panel work. Review scope is the difference from the source snapshots in `/tmp/segno-corner-release/`, plus the new comparison module and its tests. Earlier unrelated changes were not re-reviewed.

## Layer separation

Violations found: 0.

- `segno_enclosure.py` remains the source of manufacturing dimensions and generated DXF geometry. The Ø6.5 mm corner relief and 0.15 mm front trim are defined once and reused by geometry and drawing notes.
- `fusion_export_formed.py` remains the adapter for Fusion's native API. Autodesk imports occur only in functions that need Fusion. Its data handoff uses DXF, STEP and JSON, so the ordinary Python test suite can inspect the exported evidence without loading Autodesk APIs.
- `flat_pattern_check.py` is an independent geometric comparison module. It imports the existing CadQuery and ezdxf dependencies and standard Python utilities; it imports neither Fusion nor the enclosure generator. It reads its explicit input paths and performs registration in memory without modifying them.
- `_formed_record()` owns the release decision. The Fusion exporter supplies the final native flat and its checksum; the generator validates that file against the current source cutting and deferred-drilling geometry before accepting the native formed part.

## State management and failure behavior

Issues found: 0.

- Temporarily setting occurrence/body visibility is confined to STEP export and restored by `finally`, including export exceptions. This is consistent with the reported native preservation checks and keeps inspection visibility separate from the artifact's geometry.
- Base CUT validation intentionally uses the final unfolded body, because subsequent native construction trims can make the initial CUT sketch historical. VENT, BEND and DRILL checks, native bend/rule validation, and lid/bracket CUT checks remain in the exporter.
- The geometric checker accepts only supported closed contours and one connected sheet. It rejects contours wholly outside the sheet before subtraction, avoiding the previously reported disappearance of such contours. Registration permits translation and four proper rotations; a failure to register or a material mismatch fails the gate.
- Deferred front drilling participates in the final formed-body comparison without becoming laser CUT geometry. This keeps the fabrication operations distinct while still verifying the finished part.
- Missing files, changed source signatures, changed STEP or native-flat bytes, and matching-checksum but incorrect native geometry fail before a formed model is consumed. The existing all-solid and dimensional validation remains downstream. An interrupted exporter can invalidate the old cache but cannot cause a mixed cache to be accepted by these checks.

## Dependency direction and package structure

Direction violations: 0. New dependency flow is generator → comparison module → CadQuery/ezdxf, with no cycle or dependency on Flutter presentation, state management, firmware or audio-engine packages.

This is an existing Python CAD-tool directory, not a new application package. The small, single-purpose comparison file and its tests fit that structure without introducing a separate package, manifest or speculative abstraction. Flutter-specific architecture and state-management rules do not apply to these files.

## Validation

Independently ran the enclosure unittest suite using the established CAD Python runtime. All **10 tests passed** in **11.600 seconds**. This includes the source/native contour mutations, the outside-contour regression, the generator integration test that first rejects a changed checksum and then rejects incorrect geometry after the checksum is updated, and the eight-piece formed assembly test.

Native save/reopen, final archive-byte verification, supplier tooling acceptance and physical first-piece validation are owned by the parent task and are outside this architecture review. The test run and clean architecture assessment do not establish physical production approval.

## Verdict

Architecture is clean for the reviewed corner completion. No actionable Critical, Important or Suggestion findings.
