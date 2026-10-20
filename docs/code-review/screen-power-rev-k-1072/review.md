<!-- cspell:words autorouting -->
# Bug-focused review — Revision K screen-power completion

Baseline: `9a5798be6c4ea9b0aae2a88fe7168b6751cab441`.
Reviewed working changes and new files for the K routing/model/wiring revision.
Final native board SHA-256:
`d35484d551cf8f526f62c4356accbff0492c28999beb0e8830801c39f00c83da`.
The exact generator/model/source hashes are in the
[verification record](../../reviews/screen-power-rev-k-1072/fabrication-verification.json).

No unresolved actionable bug was found in the completed local scope. This is
not a clean review of every older file in PR1080, and the requested external
model reviews did not complete. Keep `review:pending`.

## Review performed

- Read every authored change and enclosing circuit/placement/routing/export
  contract. Traced route generation through placement, autorouting, zone fill,
  native validation and guarded package publication.
- Checked removed behavior: the all-zones-must-be-ground restriction is replaced
  by mandatory GND on both outer layers and an explicit power-net/layer/name
  allowance. Wrong zone assignments and missing ground remain rejected.
  Removed generic models have direct exact-part replacements and portable paths.
- Cross-checked native schematic, PCB and BOM independently. All 41 references,
  96 connected pins and 27 nets match; relay state tests remain correct.
  Only C1 changes position; part values, drill sizes and connector maps persist.
- Proved power continuity independently with taper zones removed; removing the
  original fuse barrel still leaves the dedicated-via path. Narrowing the new
  C1 feed is rejected. USB data geometry and its continuous return checks pass.
- Reviewed partial power, reverse blocking, live transistor tabs, fuse budgets,
  connector/cable requirements and GPIO shutdown call sites. Corrected the
  system diagram, main-power lead contract and aggregate power accounting.
- Inspected all populated model assignments, final top/perspective renders,
  nominal and maximum capacitor envelopes, full mated-plug clearance and hole
  tolerances. Corrected the model stripe placement and checked its exterior.
- Checked reuse and simplicity: native KiCad tracks plus small named zone
  tapers, existing CadQuery model generation and existing guarded export flow;
  no new dependencies, speculative framework or alternate hardware path.
- Verified fresh independent manufacturing exports against the packaged CAM
  contents; exact artifact/source hashes and unchanged console/ring ZIP hashes.

Independent architecture, convention, test-quality, simplicity and readiness
reports are linked from the [consolidated review](../../reviews/screen-power-rev-k-1072/review.md).
All confirmed local findings were fixed and the affected checks repeated.
Changed Python parses, authored-source whitespace checks pass, and authored documents receive
the repository spelling check. No unrelated app/firmware tests establish any
hardware claim; no Dart, C/FFI, firmware or runtime code changed in this revision.

## Coverage limits

External Claude and OpenCode Go runs reached usage limits before new final
reports. Their [attempt record](../../reviews/screen-power-rev-k-1072/external-model-reviews.md)
is incomplete coverage, not approval. The stacked feature-base PR does not
trigger full repository CI. Physical USB performance, actual voltage/heat,
startup/fuse behavior, enclosure installation and screen shutdown timing remain
unqualified. First bare-board fabrication and production-unit qualification
are separate conclusions.
