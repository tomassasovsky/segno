<!-- cspell:words SKiDL KiCad pcbnew Freerouting GPIO UFP pulldown pulldowns VBUS SMD THT NPTH ERC DRC UUIDs Gerber GPIO17 -->

# Test quality review — through-hole hand carrier and factory variant

Date: 2026-09-21 local; final validation snapshot 2026-09-22 02:32:45 UTC.
This report replaces the earlier review of the obsolete hand design and closes
the three findings from the through-hole implementation review.

## Scope and independence

Independent review covers the separately authored contract, numerical,
connectivity and assembly checks in `check.py` and `hand_checks.py`, cleanup,
export publication, and the build entry point. The reviewer authored the hand
circuit, RF relay footprint and symbol, schematic renderer, variant dispatch,
and earlier process-isolation block in `check.py:main`. Those implementations
are not independently approved here. Circuit architecture and schematic
presentation require the other reviewers' evidence.

The stack is Python/SKiDL and KiCad, with `build.sh`, native ERC/DRC, and
`check.py --self-test` as its validation entry points. Flutter tests and Bloc
conventions do not apply. No Python coverage threshold is configured for this
hardware directory, and no measured coverage percentage is claimed.

## Findings

No unresolved Critical, Important or Suggestion finding in this review scope.

Three earlier findings are resolved:

1. The integrated hand checker now calls the hand numerical checks while
   retaining the shared GPIO margin calculation. A deliberately overloaded
   attachment pullup is rejected by both the integrated and standalone gate.
2. The console gate now requires physical copper connectivity between Pi
   physical pin 11 and J25 pin 1. Removing all 11 added GPIO17 copper items is
   rejected even though the pad net names remain correct.
3. Package publication now stages a complete sibling replacement, preserves
   the previous package until installation succeeds, restores it on a failed
   installation, and retains the backup if restoration itself fails. The
   original failed-copy probe now preserves the previous package.

## Independent failure-path evidence

These probes exercise the real checking functions and real KiCad board, pad,
footprint and trace objects. Only disposable copies or fixtures are mutated.
External rendering commands are simulated solely in the export error-path
fixture; simulated files are never described as valid fabrication output.

| Fault or boundary | Result |
| --- | --- |
| Current hand contract | Pass, zero findings. |
| Host VBUS connected to AUX | Rejected. |
| Data and power relay low-side nodes joined | Rejected. |
| Data relay flyback reversed | Rejected. |
| Power-relay discharge moved to normally open contact | Rejected. |
| Two-pin control signal moved to ground | Rejected. |
| Enable pulldown ground removed | Rejected. |
| Data relay contact changed | Rejected. |
| Excessive attachment pullup current | Integrated and standalone checks reject the 6.457 mA case. |
| THT footprint baseline | Pass. |
| Footprint marked SMD | Rejected. |
| SMD pad hidden in a THT footprint | Rejected. |
| Plated through-hole pad with zero drill | Rejected. |
| All GPIO17 console copper removed | Rejected by physical connectivity gate. |
| Cleanup segment containment | Eight cases pass, including the 2 micrometer tolerance boundary, crossing, different net/layer, excessive width and beyond-endpoint cases. |
| README changes while export is running | Export fails and preserves the prior fixture package. |

The independent publication fixture also passed all six cases: first
publication, successful replacement, partial-copy failure, backup-rename
failure, installation-rename failure, and installation plus rollback failure.
The last case retains the complete previous package at the reported recovery
location. These tests cover caught filesystem errors; they do not establish
crash consistency across process termination or support concurrent exporters.

## Final board and persistent regression checks

An independent combined run at 02:32:29 UTC passed both variants. The only
subsequent source delta was a placement docstring/comment cleanup and removal
of an unused import. Those changes were inspected. The implementation owner's
fresh final combined run at 02:32:45 UTC also passed, and every recorded input
hash was independently compared to the current files before this report.

Both runs report zero ERC/DRC errors, warnings, exclusions and unconnected
items under the configured KiCad rules. Native exported schematic component
records and all physical net memberships match the generated netlist; every
connected PCB pad also matches. Native rule reports retain their list of
ignored rule categories, so this is not a claim that every possible KiCad rule
is enabled.

The persistent hand self-test detects all five required faults: host-power
bridge, cut USB copper, cut console control copper, SMD footprint flag and SMD
pad hidden in a through-hole footprint. The factory self-test detects its
three applicable faults: host-power bridge, USB cut and console control cut.
The baseline must pass for the delivered board to receive a passing result.

The final hand numerical output includes a 0.9575 mA maximum attachment-output
load, within the checked 1 mA test condition. It explicitly states that its
0.8 A fuse is not a current limiter and that USB suspend compliance and relay
temperature qualification are not established. Factory touch-current limits
remain separately calculated and checked.

## Integrity and acceptance boundary

Validation hashes the board, netlist, native sheets, support libraries, source
scripts, BOM and the actual console board/netlist before and after its run.
Export adds the README, builds the archive and content hashes in temporary
storage, requires fresh passing CAD checks and unchanged inputs, then publishes
the completed package with recovery on caught publication failures.

Final manufacturing exports are complete. An independent comparison verified
all 28 manifested files and every recorded source hash for each variant,
including the exact current board hash. Both 15-entry Gerber/drill archives
passed their integrity checks and match the loose files byte for byte. No bench
qualification, USB compliance, fuse clearing time, shutdown ordering, thermal
performance, enclosure fit, remote CI, current-head code-review gate or merge
readiness is claimed. The issue remains blocked on physical verification.

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
