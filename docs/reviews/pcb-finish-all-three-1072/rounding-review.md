# Shared route-rounding review

This is a bounded code, integration and native-geometry review for issue #1072,
starting from `2b45a6adb804044baebfe6ecb7b225ac98c97ded`. It covers the new
[rounding helper](../../../hardware/kicad/round_routes.py), its
[native regressions](../../../hardware/kicad/test_round_routes.py), and the
console, ring and screen build calls. It does **not** mark the whole PR or the
manufacturing packages approved. Exact source and board hashes, test results
and limits are in [rounding-regressions.json](rounding-regressions.json).

No additional actionable finding remains in this bounded source review.
The review read the complete helper and runner, followed all three callers
through refill and DRC, checked source-manifest coverage, and tested the
serialized native output. The corrective native-contact and keepout changes
were reviewed separately by the coordinating reviewer before import.

## Geometry and regression coverage

All **13 fixtures pass** under native KiCad. They exercise an interior track
T-contact, a pad touched only by a trace edge, board and footprint track
keepouts, pad/via landings, different-width and locked branches, rotated and
custom foreign pads, two newly rounded chains, and explicit USB exclusion.
Every fixture's second run is byte-identical. Connectivity, clearance and
keepout checks inspect actual native copper shapes rather than source text.

The minimum-radius fixture reproduces the ring's closely spaced 45-degree
turns. The original helper rejects a mathematically valid 0.05 mm inside
radius because floating-point arithmetic returns it just below its floor;
the fixture fails on that source and passes with integer-IU eligibility.
The correction also removes both real ring `RING_DATA` residual corners and
the two console `+3V3` residual corners observed in the diagnostic trial.

The helper retains each local same-net copper contact before accepting an
arc, including track-interior and pad-edge contacts that endpoint degree alone
misses. It includes board and footprint track keepouts in native obstacle
queries. New geometry enters the obstacle index as each chain is replaced,
so later chains are checked against the copper already emitted. Locked
routes, explicit skipped nets, widths and terminal anchors remain preserved.

## Build integration and source coverage

The console and ring calls run after rail widening and before refill/final
DRC. The screen call runs after endpoint finishing and before cleanup's refill
and final DRC. All calls run under KiCad Python and propagate failures through
`set -e`; successful rounding alone does not permit export.

The screen passes all eight USB data-net names explicitly. The helper's
standalone default does not protect USB by name. Matched-pair routing remains
owned by the critical-route source and its separate USB checks.

Runtime inventory checks confirm that screen validation hashes the shared
helper. The independent screen fabrication verifier lists it independently;
the console/ring source inventory includes the helper, runner and all three
pipeline entrypoints. Python compilation and shell syntax checks pass.

## Native board observations

The reviewed screen candidate reports zero violations and zero unconnected
items after refill. Its 990 pre-existing locked tracks and every route at
least 1 mm wide are exact. Other footprint, pad, model, via, zone-definition,
stack and outline geometry is unchanged. The helper changes only 0.25 mm
tracks. Independent USB review finds the input data routes exactly unchanged,
with 0.160 mm minimum pair gap, less than 0.000001 mm skew, and all 6,268
native ground-reference samples passing. Both filled-copper faces were
inspected; remaining degree-two non-USB turns lie within pad/via landings.
This candidate is recorded separately from release/export approval.

The imported ring native reports zero violations and zero unconnected items.
All locked power geometry and tracks at least 1 mm wide remain exact, while
0.30/0.55/0.65 mm routed bends receive the smooth finish. The 1.5 mm strip
supply and its accepted vertical taps are preserved. The full-white power
guard and all seven injected fault controls pass. No unresolved routed corner
is reported. Native SHA-256:
`188fd6ee4d395d1152fd5d840536ab0699a499cb50bf74539e2bb27273ddcbf2`.

The combined console candidate now includes the corrected C20 placement,
source-matched rear power fillet and smooth Pico supply join. It passes
zero/zero native DRC, the corrected power guard and all **eleven** injected
fault controls. Its second helper run is byte-identical. All 91 locked tracks,
routes at least 1 mm wide, other native metadata and source-matched C20 pads,
references, models and ground stitch remain exact. No residual routed corner
is reported; both filled copper faces and the two changed local regions were
inspected. Native SHA-256:
`27e690947142c2a31af171c4e2fc82c74b66183d790098299b0fb33b412b75aa`.

The actual rear copper union fills the former 0.050 mm slot completely and
retains 0.220 mm track/bar overlap. Its blend has no internal hole and a
9.561° maximum meaningful chord turn; the preserved rejected fixture has
48.125°, so the contour test distinguishes the sharp artifact. The rounded
1.7 mm bend retains 0.276252 mm clearance to `IND_DATA_OUT`. Sampled connector
pad annuli remain fully represented in the physical pad/track/zone union.
These are results for the exact candidate hash above, ready for coordinating
import and subsequent manufacturing-package verification.

## Limits

These are two-layer geometry checks, not a general custom-rule solver or an
assembled hardware qualification. Ordinary filled zones are refilled rather
than treated as immutable routing obstacles. Native DRC, the power guards,
USB checks and final CAM verification remain required. Byte stability is
observed for the tested fixtures and board inputs; it is not asserted for
every possible board. This review did not rerun a complete Freerouting build
or approve the manufacturing archives.
