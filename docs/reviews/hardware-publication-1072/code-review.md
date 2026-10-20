> **Screen-board correction, 25 September 2026:** This is a historical report. Its screen relay-pinout approval is superseded: IM02TS commons are 3/6, NC contacts are 2/7, and NO contacts are 4/5. Revision I Gerbers are withdrawn. Use the [corrected Revision J record](../screen-power-rev-j-1072/verification.md). Console and ring findings are unaffected.

# Hardware and GPIO publication code review

Reviewed 25 September 2026.

- Base: `4ef6109ae902a85c4fa144a51d11081cf0af80f3` (`origin/feat/console-board-5v-1062`).
- Head: `355bf319b776fb8a4fec8e7915e2ebeb87657431`.
- Scope: the committed hardware and screen-power lifecycle change, 200 changed paths against that base. The exact commit was exported to a temporary directory before inspection. Uncommitted new-v3 firmware, protocol and application work was excluded.
- Result: **no actionable introduced defects identified** in this scope. The source/CAD review is clean for this head. This report is published in a documentation-only follow-up whose implementation is identical. This is not assembled-hardware acceptance, remote CI evidence or authority to merge/order.

## Coverage

Reviewed the changed hand-authored screen circuit, placement, explicit USB/power routing, cleanup, schematic construction, export, validation and model helpers; console circuit/placement changes; ring changes; GPIO helper, systemd units, recipe, CI entry and behavioral tests. Traced the final netlist/PCB pads and manufacturing outputs instead of treating the generator alone as the delivered board.

The generated CAD, Gerber and STEP groups were reviewed through native KiCad loading, net/geometry checks, actual renders, and manufacturing-layer comparisons; this was not a manual line-by-line reading of generated STEP entities or Gerber coordinates. Historical review files were treated as dated evidence, not substituted for checks on this head.

Completed review angles:

- Circuit/state and failure paths: GPIO defaults, common-source opposing MOSFETs, D1 isolation, relay normally-open contact mapping, host-VBUS separation, fused output branches, discharge path, daemon termination and interrupted enable, acknowledged commands and failed-owner reclaim.
- Removed behavior and invariants: factory assembly is absent from the final board; hand-only checks enforce through-hole parts. The CTRL analog bias now follows the Pico's own rail; the Pi rail is not shorted to it. Geometry changes retain final signal/net connectivity and ground pours.
- Cross-file interfaces: Pi ribbon physical pin 11 to console J25 pin 1 to screen J2 pin 1, ground pin 2; USB D+/D− and supply boundaries; connector holes and actual pad maps; new connector placement and labels; recipe installation and runtime dependency declarations; Weston/app shutdown ordering.
- Reuse/simplicity/efficiency/fix depth: existing KiCad and libgpiod facilities are used; the GPIO owner is outside the audio path, blocks only its own command lifecycle, and does not silently enable on failure. No new actionable duplication, real-time violation or incomplete local workaround was found.
- Project conventions: no application-layer dependency violations in this scope; board review distinguishes fabrication geometry from hardware qualification and preserves the hardware validation gate.

## Independently executed checks

- GPIO lifecycle suite: **12 tests pass**, including real Unix-socket request handling and process termination, interrupted re-enable, missing-owner fallback, bounded busy retry and GPIO errors.
- Screen `check.py hand --self-test`: **pass**. Native ERC/DRC, schematic/netlist/PCB parity, supply boundaries, actual USB/control connectivity, filled return-plane sampling, minimum-width power paths, two copper layers, hand assembly, lead-hole allowances, fastener clearance and model coverage pass. **All 24 intentional fault cases are rejected**.
- Fresh console and ring full-severity DRC with all-track-errors and zone refill: **0 violations and 0 unconnected items on each board**.
- Console routed fabrication gates: **pass**, including connector drills, physical pad/netlist parity, rail minimum widths and via/legend checks.
- Console placement/assembly self-test: **all 15 deliberate fault controls pass**.
- Regenerated manufacturing data into a temporary directory: **all 29 Gerber/drill layers across the three committed ZIPs match the exact native boards** after removing only export-time/identity metadata. The console/ring were compared with their existing export options; the screen's export additionally subtracts mask from silk. No native board or original package was modified.
- Fresh top-side KiCad renders of the screen and console were inspected. The screen board contains its complete through-hole population and consistent connector orientation; the console's PD, ring, screen and Pi-power connections match their final placement.
- General `git diff --check` reports only whitespace in generated STEP/netlist data and bundled upstream credit files. It is not a clean whole-diff whitespace check; no hand-authored source whitespace defect was found.

Manufacturing ZIP fingerprints:

| Package | SHA256 |
| --- | --- |
| Console v3 | `93dc849e1950138fa5018f3916ef894e0d452159b3ce3764b68acfbc2437485e` |
| Screen power revision I | `25370578cbb1184f6d2bc1913c88746ff87ce91809779c7878d62f4af735a878` |
| White ring carrier | `e79e97d122088814b1ee34b1e33ecbe281fb9ee7a6f27c9b05a437ad16fccc74` |

Cross-checked the specified power-device resistance conditions against [Vishay's SUP70101EL data sheet](https://www.vishay.com/docs/77632/sup70101el.pdf), the exact relay-driver ordering variant/drive condition against [the manufacturer's 2N7000 data sheet](https://www.onsemi.com/download/data-sheet/pdf/nds7002a-d.pdf), and Python packaging against the [pinned Poky manifest](https://raw.githubusercontent.com/yoctoproject/poky/d0b46a6624ec9c61c47270745dd0b2d5abbe6ac1/meta/recipes-devtools/python/python3/python3-manifest.json) and [pinned gpiod recipe](https://raw.githubusercontent.com/openembedded/meta-openembedded/07330a98cf93806b7a4e0170a541b94962ff3960/meta-python/recipes-devtools/python/python3-gpiod_2.3.0.bb).

## Material limits

No physical board, cable, screen, thermal, transient, USB signal-integrity, enclosure-fit or shutdown-rail measurement was performed. The one-second startup and five-second discharge waits are provisional. The existing first-fabrication decision remains a fabrication decision; these checks do not prove the panels extinguish before actual HDMI loss.

The ring carrier retains alternative direct-mount 24/16-LED footprints and J2 strip wiring pads. Their presence is not a new power rating or mechanical qualification for a 40-LED strip; the documented copper budget remains distinct from firmware limits and the strip's housing. New-v3 firmware is outside this reviewed commit. A full Yocto image build and live systemd/device test were not rerun here; the existing integration fixture was inspected, while fresh host lifecycle tests were executed.

No further reviewer was spawned because all four shared agent slots were occupied. This independent review covered the grouped source/CAD angles above. Any subsequent changed head needs a delta review before using this result for `review:clean`.
