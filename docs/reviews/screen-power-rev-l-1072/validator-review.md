# Revision L validator and model-source review

Date: 2026-09-25. Updated: 2026-09-26 UTC. Issue: #1072.

<!-- cspell:words Ucamco Soldermask -->

Base and checkout HEAD: `7dcdc944bea0d22e2fa1fe32ab4ead4681aa11aa`.
Target: the uncommitted changes to the five files below, including the new
fabrication verifier. The hashes identify the reviewed working files.

## Result

No unresolved findings in the five reviewed files. A separate reviewer
completed the fabrication-verifier review. Its confirmed finding and a
subsequent end-to-end assertion error have been fixed and rechecked.
The corrected verifier completed 406 assertions against the final Revision L
package. The separate final console/ring CAM audit passes 103 assertions.
The final uniform-width screen board passes all 52 validator controls,
including the six new power-route controls below. The checker changes received
an independent source review with no unresolved finding. This remains a bounded
source/CAD review, not whole-PR approval or qualification of assembled hardware.

## Resolved findings

The new fabrication verifier originally calculated its own source hash only
when returning success. Editing the verifier during the CLI exports could
therefore associate a passing result with code that had not executed.
It now captures that hash at the start of `verify()`, rejects a changed hash
before success, and records the captured value. The revised control flow was
inspected after the fix.

The first final-package run exposed a false rejection in the file-function
assertions. The verifier incorrectly reused KiCad's job-file strings for the
Gerber layer headers. Raw final mask headers use `Soldermask,Top` and
`Soldermask,Bot`; the outline header uses `Profile,NP`. KiCad's job file uses
`SolderMask,Top`, `SolderMask,Bot` and `Profile` respectively. All fresh CAM
comparisons had already passed before that metadata assertion failed.

The fix keeps separate, exact expected maps for the two representations.
No case folding, suffix removal or other loose normalization was added.
All seven raw headers and the job inventory were checked independently;
incorrect mask case, absent profile plating and plated-profile substitution
remain rejected. The layer values also agree with
[Ucamco's 2026.05 specification, pages 143 and 146](https://www.ucamco.com/files/downloads/file_en/554/gerber-layer-format-specification-revision-2026-05_en.pdf).
The earlier helper smoke checks did not exercise this combined metadata
assertion, so they had not exposed the mistake.

The power-path guard retained filled zones while removing undersized tracks.
On a disposable board, deleting the 4.5 mm distribution spine, or reducing it
to 0.25 mm, still passed because the filled power overlay bridged the route.
Removing zones from those same boards exposed the expected missing paths.
`check_power()` now removes every zone locally from each connectivity copy,
including the fuse-barrel bypass copy. USB reference checks still use the actual
filled ground planes. The unchanged prior tracks passed with all zones removed;
the corrected final board also passes that independent baseline.

## Coverage and evidence

- Read every changed hunk and the enclosing functions. Traced the build into
  placement, validation, deliberate fault checks and package publication.
  Checked that exceptions and failed numerical assertions prevent CAD-ready
  results, and that validation checks schematic/netlist/board agreement.
- Confirmed the removed diode contract is replaced by explicit optocoupler,
  negative-rail and control-node boundaries. The removed six-ampere scenario
  is replaced by the documented 4.25 A screen budget; old numerical report
  keys have no code consumers. Numerical assumptions remain identified as
  engineering estimates rather than component guarantees.
- Exercised 12 focused cases: clean circuit/numerical baseline; five wrong
  component/value cases; four incorrect electrical connections; and both DIP hole
  cases, accepting 0.90 mm and rejecting 0.80 mm drills. All passed.
- Checked the new capacitor model assignments and optional unpolarized body
  against their callers. Existing polarized models retain their previous
  geometry path. Nominal previews are distinguished from maximum fit
  envelopes in the model documentation.
- The independent CAM checker received 25 smoke and mutation checks against
  the previous Revision K portable board. All 12 fresh CLI manufacturing
  files matched. Timestamp-only changes passed; changed Gerber geometry,
  drill diameter, layer count, PDF drawing/page/resources and ZIP contents
  failed. At that stage, these exercised the comparison machinery without
  certifying a Revision L export.
- The final [screen CAM audit](fabrication-verification.json) passes 406
  assertions: 65 source files, 70 artifacts and all 12 manufacturing files.
  It identifies board
  `d3577772b4945f93652789e109fd232b479cfc8d119dcb67e499da51d39fa5cf`
  and published ZIP
  `7a52639a561ebebf36695901bd84f27a2770fe900a227a6594deb89c0fde8e23`.
  This supersedes the earlier pre-contour CAM result. The final native file
  and published archive independently hash to those recorded values.
- The final [console/ring CAM audit](console-ring-fabrication-verification.json)
  passes 103 assertions with zero failures. Exact native/netlist pad parity,
  empty DRC violation/unconnected lists, ZIP inventories and fresh CAM parity
  pass for both updated boards. The shared timestamp-only normalization
  remains unchanged; production sources and archives stayed unchanged during
  the audit.
- All five files compiled. Changed source whitespace checks and the new
  verifier's spelling check passed. No additional architectural layer or
  obsolete hardware path was introduced. Independent regeneration intentionally
  does not reuse exporter/validator helpers, so it can detect their mistakes.

## Uniform power-route follow-up

Reviewed the native result of routing source `e9fab839` against frozen
pre-contour board
`53a3a19d9598feac3f9622b5945d709a394ee10cfb09c81ac7841f46a78624d6`.
The final screen board SHA-256 is
`d3577772b4945f93652789e109fd232b479cfc8d119dcb67e499da51d39fa5cf`.
The source snapshot in
[the validation report](../../../hardware/kicad/screen_power/validation.json)
matches this board and the checker hash below. Its native DRC reports zero
errors, warnings, exclusions and unconnected items.

- All 48 footprints and 126 pads retain their positions, orientations, net
  assignments, shapes, drill definitions and model transforms. Net names,
  outline geometry and the two-layer stack are unchanged. `switch_circuit.py`
  retains the electrical review's hash
  `9869038ee6a4a3c8d7459db4d09ee7e4bdb20d54c6102d3a10e4fd16c95164ec`.
- All 40 USB segments match the baseline exactly. The actual filled ground
  passes 5,452 reference samples; the four pairs retain their equal lengths.
  The router made incidental changes to low-current AUX, enable, host-supply
  and gate branches. Their physical pads remain connected; these traces are
  not represented as geometrically unchanged.
- The common-source bridge has 19 segments over 16.161 mm; the rear switched
  feeder has 37 over 25.523 mm. Every power segment on those runs is 2.5 mm,
  and neither run has a taper overlay. Their 0.25 mm control branches retain
  separate treatment. AUX's 1.9 mm minimum, the capacitor feeds, 2 mm main
  outputs and 0.8 mm touch paths remain enforced.
- Both the delivered filled board and a disposable copy with every zone
  removed pass the power-path guard. The three 0.45 mm drill stitching vias
  still bypass the F101 plated barrel. An independent geometric calculation
  places each complete 0.9 mm via disk inside qualifying tracks on both
  faces, with a smallest remaining copper margin of 0.20 mm.
- All 52 positive and negative controls pass. The six additions reject each
  uniform run reduced to 2.49 mm, the missing bus beneath retained fill, a
  middle section widened to 3 mm, and a forbidden taper on each target run.
  Each new result is mandatory; the existing controls remain required.
  The previous neck/taper/band board fails the new uniform-width contract.

The curved helper was also checked on its actual caller geometry: finite
coordinates, retained endpoints, no zero-length or reversing corner and
positive inner radii. Its circular paths are represented by fine native track
segments so routing interchange preserves them; the maximum checked chord
deviation is 12.04 micrometers. The source comment now states the correct bound.

The [rounded-copper review](copper-finish-review.md) has no unresolved scope
findings for the final screen, ring and console boards. The final CAM evidence
above now completes their source/package comparison. Whole-PR `review:pending`,
`ci:pending` and the hardware verification gate remain in place.
Matching CAM proves source/package agreement; it does not replace circuit,
mechanical or assembled-device verification.

## Reviewed source hashes

```text
hardware/kicad/screen_power/check.py
7b3ec8d2a5e9af32bd87617dde999d115cab15d51db3c1cb28817bbdc40f7bc2
hardware/kicad/screen_power/hand_checks.py
92e6f017791bd62e2accb6adf20ade2c4ad0ea7652942574c6d03fb5ae35e655
hardware/kicad/screen_power/pcb.py
7d50aacdb44947ba1fc7beb3006c4c8eee2b8cc140dfdc713899f5b6a7d46d9a
hardware/kicad/screen_power/model_geometry.py
37b7e49ece74315e77e22654cca75c0bf3113b33001c297ee5f2679da280b288
docs/reviews/screen-power-rev-l-1072/verify_fabrication.py
6562b79480450314016ed7ead7329e5875548a0112a0ec36aeec93f6969df9e7
```
