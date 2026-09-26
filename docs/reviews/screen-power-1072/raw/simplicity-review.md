# Screen-power code simplicity review

<!-- cspell:words ADuM TPS GPIO pcbnew SKiDL Freerouting swig -->

## Simplification Analysis

This review covers the corrected two-wire control design and the all-through-hole
hand carrier. It replaces the earlier review of the obsolete ribbon pass-through
and hand SMD design. Review date: 2026-09-22 UTC.

### Core Purpose

Produce two reproducible screen-power prototypes that switch main power and touch
power from AUX, keep the Pi USB supply separate, and accept GPIO17/GND from console
J25. The hand carrier uses through-hole relays and two external assembled USB-C
source modules; the factory board integrates its source and USB isolator circuits.
The generated native schematic, netlist, PCB, and manufacturing package must agree.

### Scope and Independence

Read the circuit builders, placement and critical-routing sources, router bridge,
finishing logic, native schematic serializer, hand-specific checker, build script,
ignore rules, requirements, and final design plan. The current generated validation
report was inspected for context. Reviewed source hashes are recorded below.

This reviewer previously authored the general `check.py`, console J25 change,
`cleanup.py` overlap helper, `export.py` publication helper, and parts of the plan,
README, external BOM, and progress documentation. Those authored portions are
excluded from this independent review verdict. They require the separate reviewer
coverage assigned by the coordinator. Reading or mechanically checking them here
does not constitute independent approval.

### Unnecessary Complexity Found

No unresolved simplification finding remains. The owner removed the unused
placement-local `pad`, `track`, and `join` helpers, their `math` import, the unused
factory `parts` dictionary, and the unused `json` import in the critical router.
The placement description now identifies its actual job, and the obsolete claim
that both assembly variants share identical USB sections is gone. The factory
route and finish code contain no unreachable hand SMD branches after dispatch.
The final delta was reread before recording this result.

### Code to Remove

None identified. Estimated further LOC reduction: 0.

### Simplification Recommendations

1. Keep separate hand and factory circuit/critical-route bodies. The actual devices,
   reference pins, discharge paths, and copper geometry differ; forcing them into
   a configurable common circuit would add conditionals without serving a requirement.
2. Keep the shared build, placement primitives, native schematic export, router
   exchange, and package flow. Each directly serves both requested variants.

### YAGNI Violations

No speculative product features, extra assembly variants, fallback hardware paths,
or new general-purpose routing framework remain. The two-wire connector is the
only screen-control interface. Legacy 40-pin names in the validators are rejection
checks, not a supported alternative. The hand source contains no ADuM, clock,
surface-mount touch switch, or ESD-array assembly path.

The explicit USB routes, same-layer differential geometry, retained ground planes,
and validation of physical connectivity are necessary constraints, not simplification
targets. Channel loops avoid copying whole circuits. Small local helpers expose
actual parts or copper primitives and do not create a broad abstraction layer.
The native schematic serializer reuses SKiDL symbols and is justified by its stated
placer limitation; it does not introduce another circuit authority.

### Validation Context

All screen-power Python sources parsed successfully; `build.sh` passed shell syntax
checking. The inspected `validation.json` at 2026-09-22 02:32:45 UTC reports both
variants passing, zero DRC/ERC findings or unconnected items, and successful fault
injection for host-power bridging, cut USB traces, and cut console control copper.
The hand checks additionally reject an SMD footprint and an SMD pad. These are CAD
checks; relay USB behavior, suspend current, power faults, HDMI back-power, timing,
impedance, temperature, and assembly fit still need physical qualification.

The refreshed validation inputs match the final source snapshot. Package export
verification is recorded separately by the PR-readiness role.

### Final Assessment

- Critical: 0; Important: 0; Suggestion: 0.
- Total potential further LOC reduction: 0%.
- Complexity score: Low for the two physical implementations requested.
- Recommended action: Already minimal; no circuit or module restructuring.
- No manufacturing, USB-compliance, or merge approval is implied.

### Reviewed Source Snapshot

Paths below are relative to `hardware/kicad/screen_power/`. Hashes identify exactly
what was read, including the explicitly excluded author-owned files for clarity.

| File | SHA-256 |
| --- | --- |
| `circuit.py` | `bb71e31c515d9a5321870b7772169f9069f94d811099d2f4470eccf48916a627` |
| `hand_circuit.py` | `7bd76765d3f9dbbf1710068330dcc0946a7fae0c8c3f1381e82d7d2a319b71e6` |
| `pcb.py` | `369f6083485dff8439ceb4f454cbf6c1d44be3bb069c8f63e50d98db1fa8dbeb` |
| `hand_layout.py` | `d1b241a5ade4c3f3d367b091d642b671e7b3e01e3841c02a2231c005ad8052e1` |
| `route_critical.py` | `bab5cb5c65301095e6783ba40d494d94fa12b6ce3d189fdcdccd69bae525680b` |
| `router.py` | `3209b6af268eb1d1e6c108d5486fb0325c13b89872475d5badd5ca338ec81f63` |
| `finish.py` | `dc2dc4b7c91e6071b5318296c12719c61ebaeeca856e95f0a2c44914f0cb1d55` |
| `hand_checks.py` | `084d5dcdd63addb2ebfa6b21364909a3ddb32d674b31ef8bfdd9dbd5089239a6` |
| `schematic.py` | `6087ef98670b9e1973780487f2b2db58e119f3eb5b1f3a78324c748371f8dbb2` |
| `build.sh` | `ae5821c708b0aefd5192e126bc61fded08f7c0b98a59a5caa575077408fbbcb5` |
| `requirements.txt` | `798e9198f14f2f59acd0cfc3379d64e653314b0e31686caf35097b934f73183d` |
| `check.py` | `7ea4ff595c8f09deb551ab4f899e4594b31cdd66bb94e3a6265a4b2ce237c697` |
| `cleanup.py` | `5e50d23156b182ea79efc09164ad884eae662e835441acb9bf29072c31745bcb` |
| `export.py` | `21711b1eb73ea15f5a12a9c4e028e08d7e26d1c684afc8f3153d7cb96a6e7965` |
