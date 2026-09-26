<!-- cspell:words DeepSeek heatsinks silkscreen datasheets -->
# Final PCB production review — issue 1072

This reviews all three complete boards from hardware baseline
`d32bca8b24c543b907ee1f104ebf8b04f6fa6947`, followed by the corrections below.
The [current archive manifest](../pcb-finish-all-three-1072/manufacturing-zips.json)
identifies the final native files, ZIPs and independent verification reports.
It is the source for ordering; earlier delivery folders are superseded.

## Findings and corrections

**The full-white ring needs a different power harness.** The old long 22 AWG
console-to-ring feed does not establish the AHCT buffer's 4.5 V minimum at
hot-wire and aged-contact corners. The selected harness now takes a heavy AUX
pair to a split near the ring, then separate short pairs to the LED strip and
carrier. Only DIN uses J2; only UART uses console J6. This preserves unrestricted
40-pixel white without another PCB change. The [voltage review](ring-voltage-margin.md)
gives the defined supply/length/resistance bounds and remaining regulator limit.


1. **Printed legends were below the manufacturer's minimum.** The old rules
   permitted 0.8 mm text and thinner strokes. Existing visible text is now at
   least 1.0 mm high with 0.15 mm strokes; existing printed outlines are at
   least 0.15 mm. Necessary reference offsets preserve pad and ink clearance.
   Native copper, pads, component positions, models and outlines are unchanged.
   Strict project rules and five new screen fault controls prevent recurrence.
   A separate native polygon check verifies actual ink-to-mask clearance;
   the project DRC alone missed some short gaps.
   Source: [JLCPCB legend capabilities](https://jlcpcb.com/capabilities/pcb-capabilities).
2. **Purchasing instructions selected the wrong ring option.** The BOM now
   selects the existing 40-LED strip at J2, leaves J3/J4 empty and specifies the
   actual ALPS encoder. Obsolete v2 ring-connector prose is removed.
3. **Firmware evidence pointed at the wrong branch.** The completed E9 presence
   workaround and PD reader are in runtime PR #1082 at `92af127d`, not this
   hardware branch's old firmware snapshot. Assembly instructions now state
   that dependency. Runtime integration remains a separate draft.
4. **Console USB programming could energize attached AUX loads.** The service
   instructions now require unplugging J3/J6/J24 before Pico USB, or programming
   the module before fitting. Remove USB before reconnecting; normal in-place
   programming uses SWD. The existing ring USB isolation rule is retained.
5. **The standalone validation report was stale.** The canonical screen
   report and manufacturing package were regenerated from fresh validation. The old exporter already
   ran its own fresh check; it did not consume the stale standalone report.

## Review coverage

| Area | Evidence |
| --- | --- |
| Screen circuit | [Independent complete circuit review](screen-circuit-review.md): all 44 populated components, 115 connected pads and 31 nets match source, fresh schematic export, native board and BOM; primary pinouts, opposed MOSFETs, negative gate supply, default-off control, relay contacts and host-VBUS isolation checked. |
| Console/ring circuit and power | [System review](system-power-console-ring-review.md): 206 console and 63 ring connected pads, Pico/XIAO power domains, MIDI, CTRL, encoder, PD, ring link, full-white current paths, wiring and thermal calculations. |
| Manufacturing and mechanics | [Layout review](layout-manufacturing-review.md): all six copper faces, board outlines, pad/drill allowances, mask webs, fasteners, stock courtyards, ink and exact package provenance. |
| Build/export pipeline | [Toolchain review](toolchain-review.md): source generation, routing/cleanup, validation, negative controls, package publication and independent fresh-CAM comparison. |
| External adversarial review | [Disposition](adversarial-review.md): completed DeepSeek retry with claims checked against actual sources and primary specifications. Claude Cloud stopped at its usage limit; no final Claude approval is claimed. |

The screen enable daemon, systemd dependencies, Weston hooks, Yocto package
installation/dependencies and failure paths were also reviewed. Its 12 host
lifecycle tests passed freshly. The earlier three real-systemd scenarios are
retained as historical evidence; they were not repeated here because the
local container daemon was unavailable. No software behavior changed in this
finishing correction. No device was flashed or reconfigured.

## Final validation

| Check | Final result |
| --- | --- |
| All three native boards | Zero DRC violations and zero unconnected items; screen ERC clean |
| Screen mandatory controls | 61/61 pass, including five new silkscreen faults |
| Console generator controls | 15/15 pass; actual routed-board guard passes |
| Independent ink checks | Minimum mask gaps 0.15874 mm screen, 0.16500 mm console, 0.15871 mm ring |
| Preservation | Exact non-silk geometry on all three routed and both placed boards |
| Screen package | 412 independent assertions pass against fresh KiCad CAM |
| Console/ring package | 175 independent assertions pass; all 22 loose CAM files match their ZIPs |
| Lifecycle software | 12 host tests pass; unchanged behavior |

See the [final correction review](final-delta-review.md),
[screen validation](screen-native-validation.json),
[screen archive check](screen-fabrication-verification.json) and
[console/ring archive check](console-ring-fabrication-verification.json).
Fresh populated native renders were also inspected after the correction. The
independent final harness calculation gives 4.623 V at the AHCT buffer and
4.635 V at the strip input under its stated worst-corner assumptions; assembly
notes round these down to 4.620/4.632 V. The lower 4.75 V supply bound remains
a requirement to check on the assembled system.

## Supported operating envelope

- All three boards remain **two layers**, 1.6 mm FR4 and 1 oz copper.
  Console is purple/white; ring is white/black; screen is purple/white.
  Order lead-free HASL for console/ring and ENIG for screen.
- The requested full-white 40-pixel ring plus normal pills and screens totals
  **7.608 A** on AUX. All 120 pixels at unrestricted flat white with screens
  would total **11.91 A** and is outside the retained 10 A supply budget.
- Screen allowance is **4.25 A shared**. The independent stressed gate-drive
  calculation is **5.218 V**, above the MOSFET's 4.5 V resistance-rating point.
  Estimated loss is **0.461 W per MOSFET**, about **94.5 °C junction** in the
  stated 60 °C ambient / 75 °C/W upright model. No heatsinks are indicated by
  this load model; these are calculations, not measured temperatures.
- Retain the exact external 7.5 A screen-branch fuse and specified harnesses.
  Fuses provide supplementary protection; they are not active current limits
  or a guarantee against every partial overload or indefinite short.
- The selected ring star feed carries 2.64 A in the 16 AWG trunk. Only the
  200 mA controller allowance passes through J1's short 22 AWG branch. The
  LED strip takes its 2.44 A allowance directly from the local split. The
  defined 4.75 V minimum source gives at least 4.620 V at the AHCT buffer.

## Release boundary

No additional pre-PCB prototype or owner measurement campaign is imposed.
CAD review and manufacturing-file verification can support ordering the bare
boards; they cannot guarantee that the first soldered assembly will be faultless.
Actual cable pin order/USB-C termination, touch operation, loaded supply voltage,
startup, shutdown darkness and enclosed temperatures remain first-assembly checks.
The five-second software shutdown delay is provisional until that assembled check.

The screen PCB fits the documented enclosure clearance envelope, but its four
floor mounting holes have not been incorporated in the enclosure manufacturing
CAD. The separate 40-strip housing is also a distinct mechanical design. This
is a PCB release, not approval to manufacture the unchanged enclosure pack.

No order, merge, flash or deployment was performed. Full repository CI does not
run on this feature-base PR; CAD checks run locally. Keep the PR's CI/review
and hardware-verification gates distinct from bare-board fabrication readiness.
