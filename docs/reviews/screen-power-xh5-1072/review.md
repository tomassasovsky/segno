<!-- cspell:words fanout DeepSeek -->
# Revision O: removable USB shield connections

September 28, 2026. Issue #1072; PR #1080. **Review complete: no unresolved
actionable finding for the production identities below.** This review covers the delta
from `add2748edce2c274e931e7fc3c524d1695d1ea2c`, with explicitly retained
[Revision N circuit and three-board review](../pcb-revn-adversarial-1072/review.md).

## Result and scope

All four screen-board USB interfaces now use genuine five-position JST XH
headers and XHP-5 housings. Pins 1–4 remain VBUS, D−, D+ and GND; pin 5
connects the cable shield to PCB GND. The separate drain solder pads are gone,
so a cable disconnects completely at its plug. Local placement and routing
clear the longer headers. Board dimensions, two-layer construction, main-power
VH connections, relay circuit and power-trace widths are retained.

The exact USB data copper is unchanged: all 292 track/arc items and all
pre-existing USB connector/relay pad records match Revision N. Fresh final
checks also cover the changed ground fill and neighboring power routes.
Console and ring native boards and manufacturing archives are unchanged.

## Verified corrections

- **O-01:** The wider headers initially collided with power copper and nearby parts.
  Local placement and constant-width rounded routes were repaired without
  weakening clearance or trace-width requirements.
- **O-02:** Independent test review found that two connector-selection mutations could
  pass because generic parity checks masked the intended fault. The fixtures
  now change matching records together; removing the exact selection rule
  causes the corresponding tests to fail.
- **O-03:** A removed-pad mutation used a KiCad wrapper ownership operation that could
  crash later checks. It now uses the native deletion method, verified with
  repeated mutation runs and subsequent footprint access.
- **O-04:** Obsolete zero-quantity shield-pad exceptions were removed from generation
  and validation. All remaining component records require one fitted instance.
- **O-05:** Populated visual inspection found CTRL hidden beneath relocated R7.
  CTRL and the Q5 designator were moved to exposed space, followed by fresh
  DRC, renders and manufacturing verification. Copper and pad geometry did
  not change in this final silkscreen correction.
- **O-06:** DeepSeek overstated the gaps between neighboring headers in its
  first verdict. Native measurement and its completed closeout correct them
  to 1.12–1.75 mm body gaps; these do not establish finger or cable space.
- **O-07:** The manifest's old wording incorrectly implied the unchanged
  baseline ring archive was withdrawn. It now names only the historical
  superseded ring archives.

## Validation

| Check | Final result |
| --- | --- |
| Native screen ERC and DRC | Zero errors, warnings, exclusions or unconnected items |
| Deliberate-fault controls | 123/123 passed |
| Screen independent manufacturing comparison | 415 assertions passed |
| Unchanged console/ring native and manufacturing comparison | 175 assertions passed |
| USB geometry preservation | 292 copper items unchanged; no pre-existing USB pad changes |
| Copper-loss model, nominal | 13.15–13.65 mV at the two mesh resolutions |
| Copper-loss model, conservative material case | 15.93 mV; below the retained 20 mV allowance |
| Populated top, bottom and perspective views | Models present, connectors clear, pin-5 and CTRL legends readable |

Evidence: [native checks](screen-native-validation.json),
[screen manufacturing](screen-fabrication-verification.json),
[console/ring manufacturing](console-ring-fabrication-verification.json),
[USB preservation](usb-preservation.json),
[nominal copper model](ground-return-nominal.json) and
[conservative copper model](ground-return-stress.json).

Release validation and exports use the tracked strict project rules, including
0.15 mm silkscreen clearance, 1 mm text height and 0.15 mm stroke. An unrelated
local project-settings edit was preserved and excluded from release inputs.
An initial isolated configuration lacked KiCad's stock footprint library table;
installing the existing official table in that temporary configuration removed
the 37 library-link warnings. No design rule was relaxed.

## Independent review coverage

The [architecture](raw/architecture.md), [simplicity](raw/simplicity.md),
[test-quality](raw/test-quality.md), [VGV](raw/vgv.md) and
[readiness](raw/readiness.md) roles inspect the current source and evidence.
The [bug-focused gate](../../code-review/screen-power-xh5-1072/review.md)
records the consolidated implementation and publication scope.

[DeepSeek](deepseek.md) completed the initial delta review and a final
silkscreen closeout, both clean with explicit limits. It corrected its initial
mechanical-gap estimate and distinguishes reading evidence from executing
checks or viewing images. [Review provenance](review-provenance.json)
records successful run identities and coverage. The coordinator and VGV role
performed the final populated visual inspection; the
[mechanical measurements](mechanical-gaps.json) bound nominal body clearance.

Claude authored the connector conversion and initial placement/routing work,
then returned a usage-limit error. The remaining repairs used KiCad directly.
That author run is not an independent review or a new Claude approval.
Completed Revision N Claude reviews are retained only for unchanged scope;
the new delta receives independent Codex roles and DeepSeek review.

## Production identities

| Item | SHA-256 |
| --- | --- |
| Screen Rev O native board | `bf870faa7c5e1be2dd9843d1587c76888508ece7549b27b5013d0eb7a77c9fc2` |
| Screen Rev O Gerber ZIP | `4a84d3bd587cf5b7f11941c0d5f6c2bcbc0219a406542d2eb51f7922e8e3dfb2` |
| Console native board | `c23df586f211bb439081ca951dd23dc54ba21f6d89eb3d373bd6f196749f326d` |
| Ring native board | `c53eb16d7531f2c891dc5854faaf40fc1414ebcb2747d0101740e6a35bd1d9ca` |

The [manufacturing manifest](../pcb-finish-all-three-1072/manufacturing-zips.json)
is the complete source for current archive/member identities and order options.
Earlier screen archives are superseded for this five-pin harness.
The three identified archives are accepted as reviewed bare-board fabrication
data within the limits below; assembled-system qualification remains separate.

## Procurement and limits

The updated combined Mouser import has 55 lines and 192 units. Its estimate is
$88.22 before tax, including carried-forward tariffs and shipping assumptions.
Only the three changed connector/contact products were checked again; this is
not a refreshed complete quote or a changed cart. See [harness](harness.md) and
[costs](../../../hardware/kicad/screen_power/COSTS.md).

This is bare-board design and manufacturing-data verification. It does not
establish assembled USB compliance, relay endurance, startup/shutdown timing,
temperature, actual donor-wire suitability or enclosure fit. The known
enclosure-route conflict with the short USB harness limits remains explicit;
this connector change does not resolve it. The 40-pixel ring still uses its
direct AUX star harness. No additional pre-PCB prototype is required here.

Full current-head CI remains pending on the stacked feature base; the main
workflow targets `master`. Keep `autonomy:blocked-verify` and do not infer
`ready-to-merge` from these hardware checks. No order, merge, flash or deployment
was performed.
