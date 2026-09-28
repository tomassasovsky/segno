<!-- cspell:words DeepSeek -->
# Final manufacturing evidence review

Reviewed September 26, 2026. Hardware PR #1080 baseline/head:
`368b9bd72589e12853ea7d47595351f67c843452`; PR comparison base:
`5fd9f8bf6856673d07b27054d0b98dd7ba719561`. This review covers the final working
files identified by the hashes below, including the console R18 and exact ring
encoder corrections. It is a read-only evidence audit, not inherited acceptance
from earlier generic reports.

**Current repository manufacturing evidence is complete and consistent; no
unresolved actionable evidence defect was found.** The production delivery comparison
and the canonical index status are recorded below; final review-document copies
are synchronized separately to avoid a self-reference.

## Reports present and reviewed

| Evidence | Independently checked result |
| --- | --- |
| `console-ring-fabrication-verification.json` | `passed=true`; exactly 175 assertion records, each true; zero failed checks; all nine subprocess records exit 0. Console/ring DRC has zero violations and zero unconnected items, and native/netlist connected-pad maps agree. |
| `screen-fabrication-verification.json` | `passed=true`; the category counts sum to exactly 412. All source and package artifacts still match its recorded hashes. |
| `screen-native-validation.json` | CAD ready, no errors; every one of 75 named negative controls is true. Native ERC/DRC counts are all zero. |
| `console-review.md` and `console-r18-independent-review.md` | Full original-console review plus scoped repair evidence. The original 10 kΩ UART defect is retained as history; the independent 6.8 kΩ correction review is clean. All 19 current source/runtime hashes in the independent report were checked. |
| `ring-review.md` and `ring-fix-independent-review.md` | Original mechanical/contact/detent findings remain recorded. The exact Same Sky correction, final tolerance repair and selected assembly have independent clean disposition. All 14 content hashes in the final fix report were checked. |
| `screen-review.md` | Full current Rev M review, zero unresolved findings. All 22 recorded screen content hashes match. |
| `deepseek-review.md` | External candidates have explicit primary-source/current-runtime adjudication; neither remains an actionable PCB defect. All eight current content hashes match. Its stated evidence limits remain. |
| `deepseek-fix-review.md` | All eight bounded follow-up claims are adjudicated; final guard/wording corrections are closed and the other evidence gaps are resolved. All 14 hardware/runtime content hashes match. |

No named technical report is absent. Historical original findings were not
mistaken for unresolved final findings, and an earlier clean result was not used
to accept a changed file. Separate runtime encoder behavior was reviewed against
its own three-file scope; the now-published runtime files exactly match those
reviewed hashes. This does not make the entire runtime PR clean.

The screen package's `validation.json` and the independent native report come
from separate invocations. Their generation/ERC/DRC timestamps differ, and the
independent invocation additionally contains the 75 self-tests. Their source
hashes, readiness, error counts and numerical results agree. They were compared
by those substantive fields, without falsely requiring identical timestamps or
claiming that the package ran the additional controls itself.

## Complete input and output inventory check

The verifier's read-only discovery functions were used to rediscover current
files, not merely walk the paths already listed in a successful report. All
reported hashes were recomputed from disk. Missing files, extra inventory entries,
symlinks and duplicate JSON keys are rejected by the audit.

| Inventory | Count | Result |
| --- | ---: | --- |
| Console/ring source inventory | 50 | Exact match with both before/after report maps, including current native boards, generators, shared routing helpers and footprint library. |
| Console/ring loose CAM files | 22 | Exact inventory and byte hashes match before/after maps. |
| Screen production/package sources | 67 | Exact rediscovered source set and SHA-256 values match the report and package manifest. |
| Screen native-validation sources | 63 | Matches the same set excluding the four explicitly documentation-only inputs. |
| Screen packaged artifacts | 70 | Exact inventory and every byte hash agree with the independent report and package manifest; the manifest itself is the sole excluded self-reference. |
| Published ZIP members | 34 | 12 console, 10 ring and 12 screen; exact names, no duplicates or nested paths, CRCs valid, all member byte hashes match the canonical record. |

The screen portable native board matches the source board byte-for-byte. Its
published ZIP and packaged loose manufacturing files also match byte-for-byte.
Console/ring member hashes match their report entries and current loose CAM.
The recorded fresh KiCad exports match published CAM with only the verifier's
strictly recognized creation-date fields normalized; the normalization code's
hash was rechecked. No production export or full test suite was rerun in this
narrow evidence pass.

## Current manufacturing files

| Board | Native SHA-256 | ZIP SHA-256 |
| --- | --- | --- |
| console-v3 | `8bf99b025248c1e5fc704610dbdd14410f5089645d7e03e61a2e03418c295082` | `919667b6141639590da8dd36319b236e5c434c4d8f2f3799644374e81da97fc3` |
| ring-white | `e6e1d1bcda4258391ed43a441f9bf8231839abab3b1551660f1b817472f8f62b` | `d5cad80522c7a80d797470d423e96bfb97473849b6e237a3c56789f99e28a4f4` |
| screen-power-rev-m | `8a467b1c6a881cbf7dd117d38366cfda466f1a51c64553296cc374b4ca52cb27` | `25a35f9a546fe6235a9641b1259ac763a74c6c09e31af1ee345e11c711cc7af6` |

Each Gerber job declares exactly two copper layers, F.Cu and B.Cu, at 0.035 mm
copper thickness. Both actual copper member files contain nonempty geometry.
The canonical order settings preserve 1.6 mm FR4, 1 oz, five copies, hand
assembly/no stencil, console/screen purple mask and white legend, ring white
mask and black legend, console/ring lead-free HASL and screen ENIG.

The previous ALPS-footprint ring archive is explicitly withdrawn and identified
by its old SHA and baseline Git revision; the same pathname now identifies the
new hash above. Screen Rev L remains explicitly withdrawn. Neither is treated
as a valid current option.

## Failure-case review

Temporary fixtures exercised the actual `verify_console_ring.run_board` code
for both boards, using the real published member bytes and controlled native/
export responses. These are verifier failure tests, not fabricated KiCad runs.
The fixture baseline passed for each board, then:

- a Gerber job claiming zero layers was rejected by `job_board_stack`;
- an empty successful exporter output was rejected by `fresh_cam_inventory`;
- a changed copper coordinate in fresh CAM was rejected by
  `fresh_cam_matches_zip_except_timestamps`.

Thus a successful process exit or a stale success JSON cannot stand in for the
required layer/inventory/content checks. The screen verifier was also inspected:
it independently requires its exact manufacturing inventory, both copper layers,
strict normalized content equivalence, source completeness and current source
hashes. Its recorded 412-pass result was validated against those current inputs.
The retained DRC reports disclose ignored check categories; zero reported
findings is not represented as proof that every optional KiCad rule was enabled.

## Assembly and runtime contract

`MANUFACTURING.md`, `RING_ASSEMBLY.md` and `segno_wiring.md` pin runtime PR #1082
to `dd46ab0d1a44bc55c7f42bc7db7992773c7a4113`. The exact encoder sketch/tests/README
at that Git object match the separately reviewed decoder correction, and its
presence helper matches the independent A2 E9 review. The hardware checkout's
older firmware is expressly excluded from the current assembly contract.

The selected harness is consistent across current instructions: console J6.3/.4
carry UART, J6.1/.2 stay empty; ring J1.1/.2 take their own local AUX pair;
strip power takes a separate local AUX pair; J2.3 is DIN only and J2.1/.2/.4
remain unconnected. J3/J4 are empty for the selected 40-strip build. Console
R18 is explicitly 6.8 kΩ, 1%; R17 remains 10 kΩ. The v2 soldering guide clearly
marks its old rows as historical and gives current-v3 overrides.

The exact Same Sky encoder and separately sourced nut are specified by current
BOM/assembly documents, and the final native footprint/model hashes agree with
the independent physical correction review. USB-programming disconnection rules
remain explicit. The no-new-prototype requirement is preserved.

## Evidence identities

| Report | SHA-256 |
| --- | --- |
| `console-ring-fabrication-verification.json` | `d88cfc867bb784431254f1599ee288b758aee218df7c1f51b90221b8e3d3594a` |
| `screen-fabrication-verification.json` | `2aec8c004890ca4031882316f400c8ca64449f73572b4fe620c262e98d2939d2` |
| `screen-native-validation.json` | `77538dc4ecc204f6f7f6eb18245e7296b609da59c4737a60752d0ab4a21c3f7c` |
| `console-r18-independent-review.md` | `bf27c53d7e751143311effb4fd8c39287748ebd75054b827dcc2041488fa7811` |
| `ring-fix-independent-review.md` | `41766cfbb125a87687d95d33c3acf607f78c6911c9b9d376371537d6f591bb8a` |
| `screen-review.md` | `2c98683dfad4a5ff5d8fa2a1aed4fae2009514b7615d13b6e5edd81663988741` |
| `deepseek-review.md` | `9820262fd47c7297bfc08990aaa4ff2aac5fc6b7026d9d588a83cd9dfd3c5323` |
| `deepseek-fix-review.md` | `91031e3717c353e289c1804d7ed11b46af22cd956dc44d6c884e9a4c9b403b9f` |

## Delivery/status completion

The repository evidence and canonical archive/member records pass. The final
canonical status is `bare-board-review-clean`; its SHA-256 is
`95076ec2a8fcbc4ab4c4c0a68ba774fa2c1a5c6494afe462bc39d79e242327fd`.
After the final ring-guard refinement, the 175-check console/ring report was
regenerated and every source inventory/hash was independently checked again.
The native/CAM hashes in the table above remain unchanged.

The final pre-commit delivery map contains **98 exact copied files**. Every mapped file
was compared byte-for-byte with its current source; none was missing. At the final
snapshot, only `ORDER.md` and `delivery-sources.json` were additional files.
All three renamed upload ZIPs match the canonical hashes. The screen package,
BOMs, assembly instructions and six preview copies match their mapped sources.
The order sheet preserves the exact encoder/nut, R18 tolerance, direct AUX
harness, runtime pin, board options and limits; its referenced assembly files
exist. The aggregate `review.md` was assessed for scope: it distinguishes
bare-PCB acceptance from runtime/device/enclosure qualification and pending CI.

Order-sheet SHA-256:
`5ee701af8626bccbf65484c975d7a9e59adb0d9db0075edef8f9bfc402e6ffce`.
Final pre-commit mapping SHA-256:
`0103c5179666612ee1f2865ed80ad0dda1ee05f4d1bc347d3a906ee86b67eaa7`.
All technical review reports are final and their delivery copies match. This
release report is deliberately excluded from that 98-file comparison to avoid
a self-reference; the coordinator will add its frozen final bytes as the 99th
mapped source, then record the final Git revision and hash inventory after
commit. No Git revision marker or those later metadata files are claimed before
they exist. The coordinator owns that final metadata-only completion.

## Final generated-model normalization

The STEP exporter left trailing whitespace in the new encoder model. Before
publication, only that whitespace was removed. The token sequence is identical
before and after; geometry, transforms and all native/CAM files are unchanged.
The three model-review hash entries above were updated to the normalized file.
The source/CAM inventories do not include this STEP file; their bytes and
verification results are unchanged. Final delivered review copies are refreshed
by the coordinator after this metadata-only correction.

## Limits

This is a bare-PCB CAD/manufacturing-data review. It does not establish assembled
USB compliance, thermal/startup behavior, regulator output under all loads,
enclosure readiness or runtime integration. The documented two-layer USB
impedance and component-temperature assumptions remain conditional. No order,
publication, merge or device deployment was performed by this reviewer.
