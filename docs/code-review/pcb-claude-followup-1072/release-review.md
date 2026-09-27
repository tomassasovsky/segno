# Independent release integrity review

27 September 2026. **No actionable discrepancy found in the audited working-tree release files.** This review covers the exact file identities below. Final committed delivery verification remains a separate step; this report does not claim that the delivery folder or final Git revision has already been accepted.

## Scope and evidence

Read-only inventory and SHA-256 checks were performed independently of the CAD edits. The fabrication verifiers' current inventory functions were used, then every reported source, package file and manufacturing ZIP member was read and hashed again. File inventories reject missing, additional, duplicate or symlinked package entries. Source and artifact hashes were checked again at the end of the audit.

- **97 unique production inputs** match the current reports: 50 console/ring inputs and 67 screen inputs, with shared paths deduplicated. The screen native report covers 63 inputs; its four additional fabrication inputs are documentation/license files.
- The current console/ring fabrication report records **175 passing checks**, no failures, successful subprocesses and clean native DRC for both boards. Its 22 loose CAM files match the current ZIPs and its independently regenerated CAM under the strict timestamp normalization.
- The screen fabrication report records **412 passing checks**. Its complete package has **70 hashed artifacts plus its manifest**, including portable native files, models, assembly information, renders and its manufacturing ZIP. The current package/source inventories and all manifest hashes match.
- The screen native report records **77 passing self-test controls**, no native errors, clean DRC/ERC and 50 populated component models. The source identities still match; this audit did not rerun the electrical tests.
- All **34 manufacturing ZIP members** were independently read: 12 console, 10 ring and 12 screen. Exact member names, uniqueness, CRCs, archive hashes and member hashes match the candidate manufacturing manifest. No stale ZIP was substituted.

Evidence reports checked against their current verifier implementation:

| Report | Checks | SHA-256 |
| --- | ---: | --- |
| [console-ring-fabrication-verification.json](console-ring-fabrication-verification.json) | 175 | `a527fe870e29e078df589dc7952d09c10ecca1126ab168e6800cb50b389c9ecd` |
| [screen-fabrication-verification.json](screen-fabrication-verification.json) | 412 | `fa646552dd41c3c1d2461c567d416bbe5d7e8b4b24168d5cfc6381a949276fe0` |
| [screen-native-validation.json](screen-native-validation.json) | 77 | `9f198f3c295ae15afdd40fdced84a924326c426fcaa350770777412d84fcbb5a` |

## Native boards and manufacturing archives

All three ordering records specify two copper layers. The native and archive identities checked are:

| Board | Native PCB SHA-256 | Manufacturing ZIP SHA-256 |
| --- | --- | --- |
| console-v3 | `c23df586f211bb439081ca951dd23dc54ba21f6d89eb3d373bd6f196749f326d` | `1f50cfc2816fdb3cab0fbaef07b91aad07ee06584f8dac8437a2431869465383` |
| ring-white | `2a2d139d824a981edb4f455533b4d57a190f456496606b1f80d9dc52b9c097cb` | `b7486b4a8139de9c070c85f095e1710997a0f2e3d6e0fc3174d36d129b250759` |
| screen-power-rev-m | `28959e56ab6ce29fb26532883fc9604daacedd37c85e59271ccd54fc5a53a36e` | `544bb5dde53a130dcc040bcbf5a4f62e5cfed521597e8a88601a2bf631741e2f` |

Exact filenames are recorded in the [manufacturing manifest](../../reviews/pcb-finish-all-three-1072/manufacturing-zips.json). Earlier ZIPs remain superseded; this review does not alter their historical hashes.

## STEP exports and visual checks

All three assembly STEP files have complete ISO-10303-21 envelopes and nonempty product inventories. The refreshed console export retains its 62 selected model references across 66 footprints; the four references without models are mounting holes. Its whitespace cleanup preserves every non-whitespace token. The ring STEP hash and selected-product inventory match its fresh export record. The screen STEP is included in the fully matched fabrication package. These assembly exports are visualization/fit artifacts, not manufacturing copper files.

| Assembly STEP | SHA-256 |
| --- | --- |
| `hardware/kicad/out_console/segno_console_board.step` | `30ab780bea058ec9cb99be7a91a4ba38e727d9643283e093b82894c0c6e8f663` |
| `hardware/kicad/out_ring/segno_ring_board.step` | `10e39b645014281a33f87c2be84ab8d7082ecce17288517b3ebf8c6b9571c040` |
| `hardware/kicad/screen_power/hand/fabrication/board.step` | `2102ab73e7bbcbad79970748e262709e23fdcacdd20ec6759b094819e8e65ad8` |

Both faces of all three boards were visually inspected. The console and screen retain purple mask and their selected components; the carrier retains white mask, the selected threaded encoder, controller and passives. The board outlines and component models are present without clipping or missing functional component bodies. Ring capacitor models remain generic footprint envelopes; the exact part fit is defined in the encoder/assembly documentation.

The six final preview hashes and actual dimensions are below. Each file postdates its native board and matches its export record; the screen previews are byte-identical to the package previews. KiCad's requested 1600-pixel setting produces 1568-pixel images on this build; the console command compensated for that behavior. No image rescaling or image editing was used.

| Preview | Pixels | SHA-256 |
| --- | --- | --- |
| `console-top.png` | 1600 × 1600 | `fcb3f465a8d0e0ee0643f46804586c9f27843db719f26d5482a73aa8f1edd9a6` |
| `console-bottom.png` | 1600 × 1600 | `3ae5d816f429257b08802f331fc82c5735337f3cc0205a575437863b54b62420` |
| `ring-top.png` | 1568 × 1568 | `34d2aee6a16eb7c34821ddb633685c133b5364f11a9123ebfb09c582252e281a` |
| `ring-bottom.png` | 1568 × 1568 | `287d5899b5bd35dca16103947e988e504fd0a584a5342a62c2ae00e1749c69cb` |
| `screen-top.png` | 1568 × 1568 | `2eea6f1ae22580d6f7522000ec9232fa15e98c93db594886d36037b45ebdb6e2` |
| `screen-bottom.png` | 1568 × 1568 | `1301f6410016d11706ea822fb6d74bd22541cacb08f30320199309629166788c` |

## Boundaries

No PCB, project, circuit, CAM, package, ZIP or manifest was edited by this audit. It verifies file consistency and export evidence for the identified working-tree snapshot. It does not replace the linked circuit/correction reviews, assert a completed final Claude verdict, certify assembled operation or USB compliance, or claim final committed delivery/CI acceptance. No order, merge, flashing or deployment was performed.
