## Architecture Review

Review date: 2026-09-15. Scope: the four-corner preparation delta against the
saved September 15 pre-preparation baseline, not the entire branch diff against
Git HEAD. This is a Python/CAD manufacturing change within a Flutter repository;
Flutter presentation, Bloc, repository and FFI rules do not apply to these files.

### Layer Separation

- Violations found: 0.
- The generator remains the authority for the fabrication perimeter, bend
  development and functional feature coordinates. The new gap and overlap
  parameters replace the obsolete circular-relief and end-trim parameters;
  there is no second geometry mode or compatibility path.
- Native Fusion construction consumes that perimeter. Its temporary return-end
  trims and subsequent restoration are construction operations, not a separate
  manufacturing definition. The final native flat must match the generator.
- Rechecked the revised rebuild recipe: it now trims only the two planar
  return ends, preserves the rear web and widening ramp, and restores only
  those two faces. Its corrected tangent formula uses the base's upper bend.
- The native exporter and manufacturing package retain their existing separate
  responsibilities. No Fusion API imports, desktop state, supplier operations
  or package publication logic entered the geometry calculation.
- Clean files: the changed generator, new corner regression module and reviewed
  manufacturing/process documentation.

### State Management Assessment

- `dxf_base`: appropriate deterministic geometry generation. Parameters derive
  both mirrored corners and the rear web-to-return transition from the existing
  bend allowance and fixed datums. It does not move functional stations or
  encode a speculative weld bead.
- Native construction: the two restored planar return ends reproduce the final
  source perimeter. The complete planar lid seat is preserved; the narrowed
  rear web widens only through the existing upper bend band.
- Review evidence and fabrication authority remain distinct. The preparation
  documents retain Dinacut's process acceptance and the separate structural
  hold; successful native folding is not represented as load qualification.

### Dependency Direction

- Direction violations: 0.
- No new runtime dependency, package, import cycle or reverse dependency was
  introduced by this delta.
- The existing sequence remains generator/DXF, native formation and export,
  geometry verification, then packaging. `_formed_record` still rejects an
  export whose source signature, STEP hash, native flat hash or full perimeter
  comparison does not match. Native feature-health and forming checks remain
  in the exporter.
- Source formulas use the base's own upper-bend datum. The lid screw row must
  not be used to recompute the base return's construction-trim tangent.

### Package Structure

- Existing enclosure module: complete for this delta; no additional package or
  abstraction is warranted.
- The new regression module checks a single connected cutting contour, the
  supplier-derived corner gap/overlap, preservation of the front clearance
  circles, widening confined to the upper bend band, and all pre-existing
  functional cuts, drills and bends. Its geometry fingerprints pin a baseline
  invariant without shipping a second fabrication drawing.
- Independently ran the five `tests.test_welded_corner_profiles` tests: all
  passed. No Flutter checks were run for this Python/CAD-only scope.

### Independent Geometry Evidence

- Proposed DXF: all 216 non-outline CUT/VENT/DRILL/BEND entities matched the
  preceding drawing. Both front R3 circles and both ridge R1.7 circles retain
  their underlying geometry.
- Proposed native STEP: one valid solid, 569 faces. The maximum bounding-box
  change against the preceding native STEP was approximately 0.0000001 mm.
- Four measured straight joints: gap 0.500000 to 0.500002 mm and projected
  overlap 0.999998 to 1.000000 mm. The upper ramp reaches the complete original
  return width at its planar tangent.
- All 309 functional cylindrical surfaces were accounted for, including the
  32 diameter-2.5 pilots. Two existing beam-ear holes differ from their former
  native operation by 0.0000672 mm in depth; the other corresponding axes match
  at numerical precision.
- All 514 complete faces outside the defined corner prisms matched in both
  directions. This statement excludes faces crossing those prisms rather than
  claiming a complete Boolean proof of every changed volume.
- The upper planar return seat retains its plane, normal, bounds and hole axes;
  its area changes by only 0.0000382 square millimetres.
- With the original placements, valid lid intersections reproduce the same
  three pre-existing contact films: 5.421408033 cubic millimetres before and
  after, with a difference below 0.000000001 cubic millimetres. This is unchanged
  contact evidence, not a claim of zero interference.
- Global old/new solid differences produced invalid compounds and were
  discarded. They were not used to certify locality or material volumes.

### Final Export and Numerical Evidence

- Independently inspected the actual updated `formed/segno_base.step`, in
  addition to the native proposal described above. It is one valid solid with
  569 faces. Identity-verified native face data matches all 569 exported face
  bounds, with a maximum difference of 0.00000256 mm. This is face-bound
  evidence, not a complete surface-distance proof.
- Native volume is 945049.614091 mm³; OpenCascade reports 945039.659586 mm³
  for the delivered STEP, a difference of approximately 10.54 ppm. An
  independent constant-thickness sheet integral from the delivered planar and
  cylindrical faces gives 945049.626011 mm³, within 0.012 mm³ of the native
  value. Analytic bend face areas differ by at most 0.000115 mm²; the largest
  face-area differences occur on the ten curved relief/ramp faces.
- Sampled exported relief/ramp surfaces remain within approximately 0.0015 mm
  of their source-derived angular cut geometry. This finite sampling supports
  the artifact assessment; it does not establish a universal translator error
  bound.
- The 50 ppm volume comparison is accepted as a calibrated consistency guard,
  with the existing 0.05 mm³ absolute floor. It is not a dimensional tolerance
  or standalone guarantee against missing material. Solid validity, one-solid
  count, 0.005 mm overall bounds, complete native flat-profile comparison and
  source/export staleness checks remain independent requirements.
- Independently ran the new mass-guard regression: it passes the measured
  native/export pair and rejects volume drift beyond 50 ppm, a 0.01 mm
  translation and a duplicate-solid compound. The regression passed.
- An earlier claim that native and STEP-reimport meshes were identical was
  based on selecting a different document with the same `Untitled` name. That
  evidence is withdrawn. Identity-verified STEP reimport in Fusion gives a
  different mass and mesh: approximately 945010.551 mm³ body volume, compared
  with 945049.614 mm³ native. Its cylindrical bend face areas also differ more
  than those of the delivered STEP interpreted by OpenCascade. The reimported
  body is a separate diagnostic artifact, not the saved native design or the
  delivered STEP. No round-trip shape-equality claim is made.

### Evidence Boundary

The coordinator reports that both actual Fusion models have five healthy
folds, equal base volumes and preserved 42/434 occurrence placements and
unrelated geometry. This review independently checks the delivered base STEP
and source-derived corner geometry; it does not certify every final package
operation or qualify the separate reimported Fusion body. The evidence supports
the prepared digital artifact within the stated checks. Dinacut's process
acceptance and the structural release hold remain outside this approval.

Source reviewed: `segno_enclosure.py` SHA-256
`2f01aeed2885d511250f31ef0f62e5577b83d466c8eca40c4cba68820eb087f7`;
corner regression module SHA-256
`c86e36db4652b218bbd0a8cd484afcdaf8ffb980e3802600b4e58acbcdb3fd3f`.

### Verdict

Architecture is clean within the stated source/native-proposal scope. Final
manufacturing readiness remains governed by the current export, package and
physical-release checks; this report does not release fabrication.
