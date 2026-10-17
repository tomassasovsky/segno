# Code simplicity review: unrestricted full-white 40-pixel ring

<!-- cspell:words busbar autorouter autorouting -->

Reviewed on 2026-09-25 against hardware publication head
`f8d6f889ba51bf1a8cb5e29b6f00fd852465ee2d`, including the working changes
and the new `ring_power.py` and `console_ring_power.py` modules. Fabrication
exports and the consolidated verification document were still being refreshed
by the author. This report reviews implementation simplicity; it does not
claim independent physical, thermal or signal-integrity qualification.

## Simplification Analysis

### Core Purpose

Provide a dedicated supply and return for one 40-pixel strip at unrestricted
RGB white, preserving the existing two-layer, 1 oz boards, outlines,
component positions and connectors. The source must reproduce the wider
paths, the autorouter must preserve them, and fabrication must stop if their
essential copper or return paths are lost. Lower-current logic and the
alternative direct-mount LED modules retain their existing branches.

### Review Scope

- `hardware/kicad/ring_power.py`: fixed feed installation, return vias,
  continuous-path verification, copper-thickness verification and fault tests.
- `hardware/kicad/console_ring_power.py`: fixed supply installation, parallel
  power vias, ground-thermal overrides, stitching exclusions, fabrication
  checks and fault tests.
- `hardware/kicad/widen_power.py`: grow-only behavior for mixed-width rails
  and its regression coverage.
- `hardware/kicad/console_board_pcb.py`: placement integration and export guard.
- Both routing scripts: power-path installation before signal autorouting and
  verification before fabrication export.
- Console/ring generators, native PCB changes and current assembly/power
  documentation, to check whether the helpers introduce disconnected or
  unnecessary configuration.

Flutter conventions are not applicable to this Python/KiCad change and were
not applied.

### Unnecessary Complexity Found

No actionable complexity finding.

The two helpers remain board-specific and use ordinary coordinate tuples,
small functions and the existing KiCad API. Combining them into a configurable
routing framework would obscure the different requirements: the console
crosses layers through four parallel vias and starts in the pill busbar;
the carrier uses a continuous front-layer path and a separately checked
ground return. Their small coordinate and pad helpers do not justify a
shared abstraction.

The carrier's graph walk is directly useful. It verifies the actual wide
copper reaches both connector pads without requiring the route to retain
one specific segment partition. The console's exact segment checks preserve
the deliberately selected path and via fan-out. These are concrete guards
for this layout, rather than speculative routing capabilities.

The export checks intentionally overlap DRC only where they protect a
different requirement. DRC does not establish current capacity; minimum
width, parallel barrels, return thermals, expected nets and layer selection
therefore remain meaningful checks. The injected faults demonstrate why
those checks should not be removed for a smaller line count.

The widening change is minimal: existing wide tracks are retained while
narrower tracks can grow. It reuses the established clearance analysis and
adds one mixed-width regression case. It does not introduce a second width
configuration or an alternative routing implementation.

Power-budget documentation clearly separates the new ring's hardware
capacity from the existing firmware appearance and the shared 10 A AUX
limit. This separation is relevant to the requested hardware capability;
removing it would hide a system constraint.

### Code to Remove

None required. Estimated implementation LOC reduction: **0**.

The working `.kicad_pro` diff contained KiCad's known zero-UUID
`top_level_sheets` write-back. The author was notified to omit this generated
noise from explicit staging after export. It is not a functional or
simplicity finding in the implementation.

### Simplification Recommendations

Retain the current small board-specific helpers and the physical fabrication
guards. No additional extraction, configurable abstraction or workflow
layer is recommended.

### Validation Observed Independently

- `python3 hardware/kicad/widen_power.py --selftest`: passed with zero failed
  checks, including retention of the existing 1.5 mm branch.
- `ring_power.py ... --self-test` under KiCad Python: the native board passed
  and all seven deliberate faults were rejected.
- `console_ring_power.py ... --self-test` under KiCad Python: the native
  board passed and all seven deliberate faults were rejected.
- `bash -n` for both routing scripts: passed.

The KiCad Python process emitted its existing wxApp/image-handler diagnostics
while loading boards; both suites completed with exit status zero. No
implementation or native-board file was edited by this reviewer. A full
autoroute and independent regeneration of fabrication exports were outside
this simplicity review.

### YAGNI Violations

None found in the reviewed change.

### Final Assessment

**Critical: 0 | Important: 0 | Suggestion: 0**

Total recommended LOC reduction: **0%**. Complexity score: **Low**.
Recommended action: **Already minimal**.
