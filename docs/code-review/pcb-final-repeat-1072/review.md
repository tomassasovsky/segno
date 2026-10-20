<!-- cspell:words DeepSeek OpenCodeGo GitGuardian -->
# Repeat production review — all three PCBs

**The completed circuit, native PCB and manufacturing-file reviews have no
unresolved actionable findings.** This accepts the bare-board manufacturing
package under the documented assembly bounds; it is not a physical guarantee
or assembled USB certification.

## Revision and scope

PR #1080 comparison base: `5fd9f8bf6856673d07b27054d0b98dd7ba719561`.
Review baseline: `368b9bd72589e12853ea7d47595351f67c843452`, plus the corrected
working tree committed with this report. The final published head is recorded
in PR #1080 after comparing its committed files to the reviewed SHA-256
inventories. This avoids claiming that the baseline contains the new fixes.

Fresh independent reviewers examined the complete console, ring and Revision M
screen circuits, actual native boards, exact parts and pin maps, tolerances,
power and heat calculations, placement/routing, assembly instructions and
manufacturing exports. This pass also covers the encoder generator/model/guard
and R18 correction, including their removed assumptions and failure controls.
The [previous accumulated review](../screen-power-usb-revision-1072/review.md)
covers unchanged routing helpers, lifecycle services, source/export failure
paths and cross-file integration. Its lifecycle tests were rerun in this pass.
No engine or Dart application code changed in this hardware publication.

## Findings closed and independently rechecked

- **Ring encoder:** the listed ALPS part did not match the footprint's mounting
  tabs or the enclosure's threaded mount, and its minimum contact current was
  unsuitable. With the owner's authorization, the exact Same Sky
  ACZ11BR1E-20FD1-20C replaces it. Its seven pad positions, plated holes, body,
  bushing, shaft and separately purchased SJ5-43502PM-nut are checked against
  primary drawings. The shaft centre and power copper are preserved. The
  asymmetric hole tolerance is included; five signal pads were enlarged to
  retain 0.235 mm concentric annulus at the maximum hole diameter. Old generic
  library parts are removed. The old ring archive is withdrawn.
- **Console A2 UART:** R18 is 6.8 kΩ, 1%, replacing 10 kΩ so the continuous
  RP2350 UART input has source-resistance margin against erratum E9. Source,
  netlist, both native board values, BOM and instructions agree. Copper and
  console Gerbers are unchanged. Separate CTRL-presence inputs still require
  the explicitly documented input-enable sampling in runtime #1082.
- **Encoder runtime dependency:** the selected part's clockwise sequence now
  produces +1 per complete click; partial and reversed bounce cancels. The
  correction is separately committed and pushed in PR #1082 at
  `dd46ab0d1a44bc55c7f42bc7db7992773c7a4113`. Its manufacturer-waveform tests,
  independent decoder scenarios and actual XIAO build pass. Nothing was flashed.
- **Assembly instructions:** the current v3 README and soldering override now
  consistently specify the direct AUX star feed, DIN-only J2 and UART-only J6.
  The rear jack aperture description and current runtime revision are corrected.
  Unfitted alternative LED-module models are hidden in the selected 40-pixel
  carrier assembly; STEP export now completes successfully.
- **Final adversarial follow-up:** inaccurate fault-control descriptions and a
  nominal-hole table heading were corrected. The annulus guard now expresses
  the selected part's calculation explicitly. These corrections change no
  native copper or component placement.

## Independent review evidence

| Review | Result |
| --- | --- |
| [Complete console](console-review.md) | Initial electrical/document findings fixed; exact final R18 delta reviewed separately. |
| [Console R18 correction](console-r18-independent-review.md) | Primary RP1/RP2350 limits, pad map, arithmetic, source and BOM agree; no unresolved finding. |
| [Complete ring and correction](ring-review.md) | Initial part, footprint, contact-current and direction findings fixed. |
| [Independent ring correction](ring-fix-independent-review.md) | Exact drawing, fit, tolerances, pad nets, preserved power copper and native DRC checked; no unresolved finding. |
| [Complete screen power](screen-review.md) | Fresh source/datasheet/native review, independent switch graph, pair geometry and thermal arithmetic; no actionable finding. |
| [DeepSeek full-board review](deepseek-review.md) | Completed external adversarial review; each claim checked against primary evidence and current runtime. |
| [DeepSeek correction follow-up](deepseek-fix-review.md) | Completed bounded external review; verified corrections closed and remaining claims resolved against independent evidence. |
| [Release evidence](release-review.md) | Exact current native/source/CAM/report inventories and delivered copies independently checked. |

Claude was attempted as an additional reviewer: the full cloud review rejected
the large accumulated PR, local review hit a session limit, and the narrow
cloud retry reported exhausted usage credits. None produced a completed new
review, so no Claude approval is claimed. The mandatory independent review
angles were completed by the reviewers above; OpenCodeGo/DeepSeek supplied the
completed external adversarial review. The small local footprint correction
was independently inspected after Claude proved unavailable.

## Verification

- All three native boards retain **two copper layers**, with zero native DRC
  violations or unconnected items and clean circuit ERC.
- Screen: **75/75** deliberately broken-design controls, 24 modeled switching
  states, 50 fitted models and 6,264 USB ground-reference samples pass.
  [Current native report](screen-native-validation.json).
- Console: 23 circuit controls, 15 layout controls and 11 power controls pass.
  Ring: six generator controls, eight encoder controls and seven power controls
  pass. Source/native net parity and silkscreen checks pass.
- Fresh independent export comparison: [175 console/ring assertions](console-ring-fabrication-verification.json)
  and [412 screen assertions](screen-fabrication-verification.json), all passing.
  Native/loose CAM/ZIP contents and source inventories agree. Final inspection
  covers both faces of all three boards and the populated carrier STEP.
- Runtime dependency: eight firmware suites, 58 codec fixtures and 530 separate
  sanitized decoder scenarios pass; real XIAO build uses 64,072 bytes flash and
  10,812 bytes RAM. See the review committed with runtime #1082.
- Lifecycle: 42 host checks pass (12 screen-power, eight Wayland wait, six reboot,
  16 Weston log). The unavailable systemd container runtime prevented that
  additional fixture; no target deployment is claimed.
- Scoped spelling and whitespace checks complete before publication. The
  encoder STEP exporter's trailing whitespace was removed with an identical
  token sequence; model-review hashes were updated without a geometry change. Final
  committed production files and delivered copies must match these inventories.

The [current manufacturing record](../../reviews/pcb-finish-all-three-1072/manufacturing-zips.json)
is authoritative for all three ZIP hashes, native PCB hashes and order settings.
It explicitly withdraws the previous ring archive and Revision L screen archive.
The console copper archive is unchanged; its assembly BOM has the new R18 value.

## Remaining limits and merge gate

The selected full-white 40-pixel ring requires the documented direct AUX star
harness. The assessed AUX budget is 7.708 A with normal pills; all 120 LEDs at
full white exceed the nominal 10 A budget. Screen input is assessed down to
4.75 V. The documented MOSFET/relay temperature and startup calculations remain
conditional engineering bounds. USB paths are matched and referenced, but the
approximately 90.8 Ω modeled impedance is not a controlled-impedance fabrication
warranty. Finished cable construction and assembled electrical, thermal and
USB behavior have not been physically qualified.

Runtime #1082 remains an integration draft. The existing knob's undocumented
relief remains an enclosure-model assumption, and the screen board's floor
holes/40-pixel strip housing are separate enclosure integration work. These
limits do not require a new owner measurement campaign or pre-PCB prototype
for this bare-board release. No board order, merge, flash or deployment occurred.

The main CI workflow only runs against `master`; this feature-base PR has no
full CI pass. Once the committed tree is verified, source/CAD `review:clean`
is justified, while `ci:pending` and `autonomy:blocked-verify` remain. Do not set
`ready-to-merge` or merge on this evidence.
