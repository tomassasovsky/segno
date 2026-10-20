# VGV code and project-convention review — Revision K

Reviewed 25 September 2026 against baseline
`9a5798be6c4ea9b0aae2a88fe7168b6751cab441`.
Final native board SHA-256:
`d35484d551cf8f526f62c4356accbff0492c28999beb0e8830801c39f00c83da`.

## Summary

No actionable convention, layering, regression, or unnecessary-complexity
finding was identified in the intended Revision K working change. The change
stays within the screen-board generator and its assembly/wiring documentation:
it improves power transitions, repairs capacitor representation and connector
clearance, and records the real system limits. It preserves the corrected
Revision J circuit and exact populated BOM. This role approves that local
change within its stated scope; it does not supply a PR-head review, CI gate,
manufacturing-export comparison, or assembled-system qualification.

Critical: **0**. Important: **0**. Suggestion: **0**.

## Scope and applicable conventions

Read the repository instructions, tracking contract and build/test notes, the
VGV role and build reporting contract, and PCB-layout workflow. The applicable
stack is Python/SKiDL, pcbnew/KiCad 10 and CadQuery. The application uses
Dart/Flutter, but none of its presentation, state-management, repository,
native audio, firmware, or dependency code changes here. Bloc/widget coverage
and native audio tests would not exercise this revision.

Reviewed all seven changed Python sources, the schematic/netlist changes,
placed/final native boards and validation record, the three added and three
removed STEP models and their assignments, screen-board and hardware READMEs,
external BOM, cost document, system wiring document and progress entry. The
untracked review material was checked as supporting evidence, with historical
input findings distinguished from final-snapshot rechecks. The final export
and publication verification record are a separate review scope.

## Regressions and breaking changes

- The removed generic capacitor STEP models are deliberately replaced by
  exact-BOM-named models. Native model assignments resolve to the replacement
  files, and no active assignment retains the removed STEP filenames. Their
  old footprint names remain valid: footprint geometry and model filenames
  are different identifiers. Historical model credits are not executable
  references.
- No part value, MPN, signal interface, GPIO choice, connector pin order or
  relay contact changed. An independent fresh native XML comparison against
  PCB pads, component records and BOM confirmed 41 references, 96 connected
  pins and 27 nets on the final board.
- No public API or dependency changed. CadQuery already generated the relay,
  fuse and VH models; the capacitor shapes reuse that established workflow.
- No existing tests or fault injections were removed. The geometry rule was
  narrowly extended from GND-only zones to named power tapers on explicitly
  permitted net/layer combinations, while preserving both required GND pours.
- The sole component move, C1, is followed by deliberate rerouting and a new
  minimum-width check. It is not an isolated footprint move on stale copper.

## Architecture, conventions and maintainability

The existing separation remains intact: circuit definitions own connectivity;
layout owns placement; critical routing owns manually specified power and USB
geometry; finishing owns labels; validation checks native results; export owns
publication. Revision letters are updated in the native schematic and board
sources. Critical power routing remains explicit and locked before leftover
routing, consistent with the project's PCB workflow.

The small `taper` helper expresses one concrete operation used eight times.
It adds copper over continuous tracks, assigns net/layer/clearance explicitly,
and creates no fallback circuit or configuration layer. Its endpoints are fixed
and distinct at every call site, so the unguarded length normalization has no
reachable zero-length input in this generator. Expanding it into a generic
polygon framework or adding speculative runtime options is unwarranted.

The capacitor helper serves the two actual electrolytic variants and records
polarity and pin pitch. The separate film-capacitor builder is clearer than a
parameterized cross-family abstraction. The reference-to-model mapping is
small and explicit. Documentation distinguishes simplified nominal CAD from
maximum assembly envelopes; it does not mislabel homemade models as vendor CAD.

The changed Python follows the surrounding CAD-script style. No Python linter
or formatter contract was found in the applicable hardware manifests/CI.
All seven changed Python files parse successfully; the entire tracked diff
passes the whitespace/error check. No new suppressions or hidden dependencies
were added.

## Documentation and system contract

The system diagram now routes main and touch power through the screen board,
keeps its current off the console ribbon, and makes the two-wire GPIO link
explicit. Main leads have a concrete length/gauge/contact contract. The
requested hand-soldered, two-layer design and ready-made touch-lead approach
remain intact; no new USB module or ribbon was introduced.

The load arithmetic counts the bleeder once, distinguishes a full-white ring
from all pills also showing unrestricted white, and records the 5.0 V minimum
at board J1 as a calculation assumption rather than a property guaranteed by
a nominal 5 V buck. Manufacturer ratings, owner observations and unverified
assembly behavior remain distinct. The cost sheet preserves its dated price
snapshot and states that unchanged quantities were not newly repriced.

The documents retain first-assembly USB, shutdown, thermal and voltage
boundaries without turning every unmeasured property into a new prerequisite
for buying prototype bare boards. The tracking contract still requires a
current PR-head review and appropriate CI/authorization before merge; this
working-tree report does not set those labels.

## Testing assessment

Directly executed by this reviewer on the frozen final native board:

- Fresh native schematic XML export and independent BOM/value/MPN/pad-net
  comparison: all 41 references, 96 connected pins and 27 nets agree.
- Manufacturer-contact graph across four relay states and 16 upstream data
  paths: correct channel/polarity and isolation behavior.
- All eight taper polygons inspected for their actual filled outline, net,
  layer, dimensions and priority.
- Twelve minimum-width physical power connections checked after removing all
  zones, all vias and tracks below the relevant width from disposable boards:
  all pass. A separate shared-power bypass passes with F101's barrel removed.
- Fresh native DRC including every severity, all track errors and refilled
  zones: zero findings and zero unconnected items. Board hash remains unchanged.

The saved final validation contains 36/36 passing fault controls and zero
ERC/DRC findings. The independent test-quality role additionally ran that suite
and demonstrated relevant negative cases for the C1-width check, invalid taper
name/net/layer and missing actual GND pour. That is stronger evidence than tests
matching generator text. These extra mutations are review evidence, not falsely
counted as additional committed suite cases.

The retained suite checks real connectivity and rejects assembly and electrical
faults. Model coverage establishes visible/resolvable models, not their physical
accuracy; the separate assembly review supplies the dimensions/fit evidence.
No software test can certify the actual cable, relay USB channel, screen inrush,
installed heat or deployed shutdown timing. No such claim is made here.

## Simplicity assessment

- Removable new lines identified: **0**.
- Unnecessary abstractions: **none**.
- Speculative features or compatibility layers: **none**.
- Complexity verdict: **appropriate to the bounded CAD correction**.
- State-management and UI-test coverage: **not applicable to this change**.
