<!-- cspell:words SKiDL KiCad pcbnew Freerouting GPIO UFP pulldown pulldowns VBUS SMD THT NPTH ERC DRC UUIDs Gerber GPIO17 -->

# Screen-power VGV conventions review

Date: 2026-09-21 local; final validation snapshot 2026-09-22 02:32:45 UTC.
This report replaces the historical VGV review of the obsolete hand design.

## Summary and independence

No unresolved actionable finding in the independently reviewed hardware
workflow. This is a scoped quality review, not a recommendation to merge or a
claim of physical qualification.

The applicable stack is Python/SKiDL, KiCad 10 and Freerouting. The review uses
the repository's hardware conventions and executable CAD gates. Flutter layers,
Bloc lint and app test coverage do not apply to this change. The reviewer read
the repository's build and tracking contracts; the hardware issue remains
blocked on physical verification.

Independent scope covers `pcb.py`, `hand_layout.py`, `route_critical.py`,
`router.py`, `finish.py`, `cleanup.py`, `export.py`, `build.sh`, separately
authored check logic, the console J25 delta and the documented regeneration
contract. This reviewer authored the hand circuit, local RF relay footprint
and symbol, schematic renderer, circuit variant dispatch, and the earlier
process-isolation block in `check.py:main`; those are excluded from independent
implementation approval. Exercising their generated artifacts below provides
parity evidence, not an independent electrical-design review.

## Regressions and scope

The console delta adds J25 and its GPIO17 route without changing existing
interfaces. An independent comparison against the branch's HEAD confirms:

- All 65 existing component records, footprint/pad positions and prior net
  assignments are preserved.
- All 681 existing tracks and vias are preserved. The only 11 added copper
  items belong to GPIO17.
- J25 is the only new connector. The only new physical net members are J25.1,
  J25.2 and Pi-header J2.11; the original 40-pin ribbon remains in place.

The screen carrier uses the requested two-wire signal/ground connector. The
hand variant is checked for THT footprints and individual pad types, including
hidden SMD pads; it uses externally mounted preassembled power modules. The
factory variant remains separate and supports its reflow assembly requirements.
No application or firmware implementation was added to this hardware scope.

## Structure and simplicity

Electrical generation, placement, deliberate critical routing, external router
exchange, finishing, validation and export have separate entry points. The
hand layout is isolated from the factory layout where their relay and IC
architectures differ. This avoids a generic abstraction that would obscure
actual physical pin mapping.

Placed intermediates do not overwrite routed deliverables. Missing footprints
and component-placement mismatches fail explicitly. Both inner layers remain
ground planes. Critical USB and clock networks are restored with their original
precision after router import; subsequent cleanup is bounded by native DRC and
followed by another complete rule check.

The build script propagates failures, validates the deliberately routed
intermediate, invokes the remaining routing sequence, requires final checks
and mutation detections, then exports. Export publication now has tested
recovery behavior rather than deleting the previous complete package first.
No speculative framework, compatibility layer or unused variant path is
required. The final cleanup removed dead helpers, stale placement comments and
an unused import. No further material simplification is identified.

## Reproducibility and generated parity

The README specifies KiCad 10.0.4 with matching libraries, Python 3.12,
SKiDL 2.3.0, Java and Freerouting 1.9.0. The requirements file pins SKiDL.
Tool and library paths have documented environment overrides rather than
requiring the developer's private worktree paths.

An independent temporary-directory regeneration ran schematic/netlist
creation, placement and critical routing for both variants without modifying
the delivered boards. The regenerated component records and BOMs match exactly;
netlist component records and physical net memberships match semantically.

| Regeneration comparison | Hand | Factory |
| --- | ---: | ---: |
| Components | 56 | 72 |
| Named net groups | 36 | 46 |
| Physical pads, including repeated numbers and mounting pads | 171 | 307 |
| Exact critical data/clock segments | 88 | 158 |

Every footprint and pad placement matches at the router's documented
0.1 micrometer coordinate grid. The raw hand difference is a 12 nanometer
rounding adjustment at each of two radial capacitors; this is accounted for by
the router's coordinate precision. Data and clock segment geometry matches
exactly, with no placement tolerance applied to those segments.

This pass does not claim byte-for-byte regeneration of automatic router sessions,
UUIDs or binary/rendered exports. The meaningful comparison is electrical
identity, component/pad geometry and critical routing; the delivered routed
boards separately pass native connectivity and rule checks. The final
source-only edits after regeneration were inspected and change no behavior.

## Testing and conventions

All 13 Python sources parse successfully, the shell build script passes syntax
checking, and the scoped text-source Git whitespace check passes. A generic
whole-diff whitespace check encounters generated STEP formatting; those
manufacturer-format artifacts are not hand-edited to satisfy source formatting.
No separate Python linter or code-coverage threshold is configured here.

The final combined gate reports zero CAD findings for both variants, exact
native schematic/netlist/pad parity, and all required deliberate-fault
detections. Independent scratch probes additionally exercise electrical
contract mutations, numerical overload, cleanup boundaries, source changes
during export and six publication outcomes. The paired test-quality report
records these results and the three resolved findings.

These are meaningful checks of real boards and observed failure paths, not
assertions that merely mirror source text. No remote CI result or quantitative
Python coverage claim is inferred from them.

## Acceptance boundary

The completed fabrication packages were independently checked: all 28
manifested files and source hashes match for each variant, both 15-entry
Gerber/drill archives pass integrity checks, and every archived entry matches
its loose file. The recorded board hashes match the delivered boards.
Physical USB signal quality, power sequencing, relay lifetime and temperature
behavior, fuse clearing/inrush, screen compatibility and enclosure fit remain
explicit bench or fabricator gates. No merge authorization, component purchase
or production fabrication approval is implied by this review.

## Reviewed input hashes

| Repository-relative input | SHA-256 |
| --- | --- |
| `hardware/kicad/screen_power/build.sh` | `ae5821c708b0aefd5192e126bc61fded08f7c0b98a59a5caa575077408fbbcb5` |
| `hardware/kicad/screen_power/check.py` | `7ea4ff595c8f09deb551ab4f899e4594b31cdd66bb94e3a6265a4b2ce237c697` |
| `hardware/kicad/screen_power/hand_checks.py` | `084d5dcdd63addb2ebfa6b21364909a3ddb32d674b31ef8bfdd9dbd5089239a6` |
| `hardware/kicad/screen_power/cleanup.py` | `5e50d23156b182ea79efc09164ad884eae662e835441acb9bf29072c31745bcb` |
| `hardware/kicad/screen_power/export.py` | `21711b1eb73ea15f5a12a9c4e028e08d7e26d1c684afc8f3153d7cb96a6e7965` |
| `hardware/kicad/screen_power/pcb.py` | `369f6083485dff8439ceb4f454cbf6c1d44be3bb069c8f63e50d98db1fa8dbeb` |
| `hardware/kicad/screen_power/hand_layout.py` | `d1b241a5ade4c3f3d367b091d642b671e7b3e01e3841c02a2231c005ad8052e1` |
| `hardware/kicad/screen_power/route_critical.py` | `bab5cb5c65301095e6783ba40d494d94fa12b6ce3d189fdcdccd69bae525680b` |
| `hardware/kicad/screen_power/router.py` | `3209b6af268eb1d1e6c108d5486fb0325c13b89872475d5badd5ca338ec81f63` |
| `hardware/kicad/screen_power/finish.py` | `dc2dc4b7c91e6071b5318296c12719c61ebaeeca856e95f0a2c44914f0cb1d55` |
| `hardware/kicad/screen_power/requirements.txt` | `798e9198f14f2f59acd0cfc3379d64e653314b0e31686caf35097b934f73183d` |
| `hardware/kicad/screen_power/hand_circuit.py` | `7bd76765d3f9dbbf1710068330dcc0946a7fae0c8c3f1381e82d7d2a319b71e6` |
| `hardware/kicad/screen_power/circuit.py` | `bb71e31c515d9a5321870b7772169f9069f94d811099d2f4470eccf48916a627` |
| `hardware/kicad/screen_power/schematic.py` | `6087ef98670b9e1973780487f2b2db58e119f3eb5b1f3a78324c748371f8dbb2` |
| `hardware/kicad/screen_power/hand/screen_power_hand.kicad_pcb` | `0362adac5630fb1871472aeded0f62d113e94ccb73a770ef520a6ec007d757b3` |
| `hardware/kicad/screen_power/factory/screen_power_factory.kicad_pcb` | `d047ab2bc52f89caec3ef808c306aa1cff9b533ac3ffef7bfe16c130e9def464` |
| `hardware/kicad/console_board.net` | `3941f8fb2da7211e872820f826d3ecee82cfbe57da18fd0c8a5ff58d8f1cd49f` |
| `hardware/kicad/out_console/segno_console_board.kicad_pcb` | `d4a735337159ee083228dbfa23bc4f16c329b2a44fe26847d5a04fc99004b360` |
| `hardware/kicad/screen_power/hand/fabrication/manifest.json` | `0ef127e33af22101e9e2d8ce63964d9aed3fb0e019c85a81ebecd3da7897c5a0` |
| `hardware/kicad/screen_power/factory/fabrication/manifest.json` | `2ce544d3f00a46cdcc6abfad7beddce6c87edc9bdc543ef4bb01523469d585a9` |
