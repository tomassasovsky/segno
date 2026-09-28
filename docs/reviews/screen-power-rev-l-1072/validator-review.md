# Revision L validator and model-source review

Date: 2026-09-25. Updated: 2026-09-26 UTC. Issue: #1072.

<!-- cspell:words Ucamco Soldermask -->

Original review base: `7dcdc944bea0d22e2fa1fe32ab4ead4681aa11aa`.
Target: the uncommitted changes to the five files below, including the new
fabrication verifier. The hashes identify the reviewed working files.

## Result

No unresolved findings in the five reviewed files. A separate reviewer
completed the fabrication-verifier review. Its confirmed finding and a
subsequent end-to-end assertion error have been fixed and rechecked.
The corrected verifier completed 406 assertions against the final Revision L
package, including the AUX follow-up and fillet-closure correction. The separate
final console/ring CAM audit passes 103 assertions. The current screen board
passes all 56 validator controls, retaining the prior 52 and adding four AUX
controls. The checker changes received
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
  `94ffa2a0ad3d428451798306c24dc087cbdf3e122cecefa7753c840033321a2b`
  and published ZIP
  `03ce82f332b01c18a1def9772984f28fe49d5641490f315303f4769e8f0187c0`.
  Both on-disk hashes independently match the record. This result supersedes
  the earlier pre-contour and pre-AUX manufacturing audits.
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

## Original uniform power-route follow-up

Reviewed the native result of routing source `e9fab839` against frozen
pre-contour board
`53a3a19d9598feac3f9622b5945d709a394ee10cfb09c81ac7841f46a78624d6`.
That stage's screen board SHA-256 was
`d3577772b4945f93652789e109fd232b479cfc8d119dcb67e499da51d39fa5cf`.
Its native DRC reported zero errors, warnings, exclusions and unconnected
items. The AUX follow-up below supersedes this board and checker snapshot.

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
- All 52 positive and negative controls passed at this stage. The six additions reject each
  uniform run reduced to 2.49 mm, the missing bus beneath retained fill, a
  middle section widened to 3 mm, and a forbidden taper on each target run.
  Each new result is mandatory; the existing controls remain required.
  The previous neck/taper/band board fails the new uniform-width contract.

The curved helper was also checked on its actual caller geometry: finite
coordinates, retained endpoints, no zero-length or reversing corner and
positive inner radii. Its circular paths are represented by fine native track
segments so routing interchange preserves them; the maximum checked chord
deviation is 12.04 micrometers. The source comment now states the correct bound.

## AUX input follow-up

Reviewed the checker delta from `29828131` and Claude routing source
`42f7653c`, followed by hidden fillet-closure correction `ffaca8b6`.
Current native board SHA-256:
`94ffa2a0ad3d428451798306c24dc087cbdf3e122cecefa7753c840033321a2b`.
Current routing source SHA-256:
`30b5f8ce2b49e073d40773af9e0791a92cdcf0513d1804e4c46b06d9283d0016`.
The [validation report](../../../hardware/kicad/screen_power/validation.json)
matches the on-disk board, routing source, circuit source and checker hashes.
ERC and DRC report zero findings and unconnected items. No unresolved finding
remains in this bounded checker follow-up.

- J1.1 to Q3.2 now requires a continuous 2.0 mm path with every zone removed.
  Exact 2.0 mm uniformity applies only to AUX front tracks wider than 1.5 mm,
  leaving the 1.5 mm C2, 0.8 mm C1 and smaller control branches separate.
  COMMON_SOURCE and the rear Q4.2 feeder retain their 2.5 mm contracts.
- `POWER_FILLET` is accepted only on AUX front copper. The actual AUX branch
  fillets pass; disposable copies changing their layer to rear copper or
  their net to COMMON_SOURCE or GND are rejected. Legacy AUX `POWER_TAPER`
  remains forbidden. Other power-zone permissions are unchanged.
- All 52 earlier control keys remain present and pass. Exactly four mandatory
  controls were added, bringing the total to 56. Independently repeated
  native mutations remove the AUX main route, reduce it to 1.99 mm, widen
  an interior segment to 3 mm and rename an actual AUX branch fillet to
  `POWER_TAPER`. All four fail their intended assertions; the unmodified
  native board passes. Widening alone fails uniformity without falsely
  reporting an electrical disconnection.
- The retained narrow-FET control now narrows the whole AUX main run to
  1.5 mm. This preserves its intent when adjacent curved track caps can still
  reach the pad after only its terminal segment is narrowed.
- Independent semantic comparison to the frozen pre-contour board still
  preserves all 48 footprint and 126 pad contracts, models, drills, net names,
  outline and stack. All 40 USB segments match exactly. The electrical
  circuit source retains hash `9869038ee6a4a3c8d7459db4d09ee7e4bdb20d54c6102d3a10e4fd16c95164ec`.
- The final closure correction changes only four AUX fillet zone outlines.
  Comparison to the preceding AUX board preserves every track, via and native
  invariant above. The refreshed source hashes, zero DRC findings and all
  56 passing controls identify the corrected native board.

The refreshed screen CAM audit passes all 406 assertions for this corrected AUX
board and its published ZIP. Whole-PR `review:pending`, `ci:pending` and the
hardware verification gate remain in place.
Matching CAM proves source/package agreement; it does not replace circuit,
mechanical or assembled-device verification.

## Reviewed source hashes

```text
hardware/kicad/screen_power/check.py
bf91b700ccac02e07ccf033dcf29bcebcf36b7ac2329d048a4c392f80c0e367d
hardware/kicad/screen_power/hand_checks.py
92e6f017791bd62e2accb6adf20ade2c4ad0ea7652942574c6d03fb5ae35e655
hardware/kicad/screen_power/pcb.py
7d50aacdb44947ba1fc7beb3006c4c8eee2b8cc140dfdc713899f5b6a7d46d9a
hardware/kicad/screen_power/model_geometry.py
37b7e49ece74315e77e22654cca75c0bf3113b33001c297ee5f2679da280b288
docs/reviews/screen-power-rev-l-1072/verify_fabrication.py
6562b79480450314016ed7ead7329e5875548a0112a0ec36aeec93f6969df9e7
```
