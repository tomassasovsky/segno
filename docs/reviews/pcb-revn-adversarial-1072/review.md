# Revision N: all-three-board adversarial review

28 September 2026. PR #1080, issue #1072. **Fresh multi-model review incomplete:
Claude's console closeout is pending after a session-limit failure.**
This record covers the current screen, ring and console design at
`44edd9483518768506533a3b6fe30e85d6d530c4`, plus the documentation corrections
identified below. No native board, circuit, BOM or manufacturing archive has
changed during this pass.

## Coverage

| Review | Scope | Result |
|---|---|---|
| [Claude screen](claude-screen.md) | Fresh Revision N circuit/native review, new-part primary drawings/data, USB geometry and targeted closeout | Complete; no unresolved actionable board defect |
| [Claude ring](claude-ring.md) | Current native ground-fill delta, retained unchanged circuit evidence, fresh refill/CAM and primary input specification | Complete; no unresolved actionable board defect |
| [Claude console](claude-console.md) | Current identity continuity with the previous completed full review | Fresh closeout did not finish; session limit, resets 13:40 Buenos Aires on 28 September |
| [DeepSeek screen](deepseek-screen.md), [ring](deepseek-ring.md) and [console](deepseek-console.md) | Independent circuit/native evidence and manufacturer-data reviews, followed by targeted correction of disputed claims | All complete; no confirmed actionable PCB defect, with model-specific coverage limits |
| [Independent production audit](production-coverage.md) | Actual BOM/native/archive identities, footprints, fuse access, enclosure bounds and release instructions | Complete; two documentation findings fixed |
| [Documentation correction review](documentation-review.md) | Current manufacturing guide, wiring arithmetic and ring programming sequence | Complete; clean |
| [Existing independent bug gate](../../code-review/pcb-stock-cost-1072/review.md) | Revision N implementation, circuit controls, actual copper, retained prior scope and independent CAM | Complete for unchanged production identities |

Coverage is distributed across reviewers. A model reading extracted native
data is not presented as having visually inspected every manufacturer drawing.
Individual reports distinguish independent checks, retained evidence,
adjudicated false positives and material limits.

The console's prior completed Claude review remains relevant because its
native board is unchanged. That does not constitute a new successful Claude
verdict. This record therefore does not claim that the requested fresh
all-three-board, multi-model pass is complete. No new PCB defect was confirmed
by the reviews that completed. The remaining console closeout must be recorded
before lifting the final review hold.

## Verified findings and corrections

1. The active manufacturing guide still selected the superseded Revision M
   screen archive. It now selects Revision N, its current BOM and the onboard
   removable 8 A fuse.
2. The system wiring guide retained an external inline fuse, the deleted
   negative gate supply and an older power budget. It now matches the relay
   circuit, short protected-from-abrasion incoming pair, soldered branch
   fuses and 7.818 A AUX planning total. F1 cannot protect wiring upstream
   of itself; that limit remains explicit.
3. The ring programming instructions now turn AUX off before unplugging J1
   and attaching XIAO USB. The separately powered strip remains off until
   USB is removed and J1 restored, avoiding a powered strip with disconnected
   control wiring. This does not require a PCB change.

Claude's optional relay-contact material suggestion was assessed against
manufacturer wording and current purchasing constraints. It does not prove
capacitive endurance and has no verified exact available Mouser US option.
The stocked relay is retained. See the screen report for the adjudication
and corrected conservative calculations.

DeepSeek's initial findings included wrong thermal-spoke arithmetic, a generic
input-clamp assumption that does not apply to the selected AHCT part, and
confusion between relay pickup and holding voltage. These were checked against
actual copper and manufacturer data and explicitly retracted in completed
follow-ups. Their rejection does not create a new guarantee of hot holding,
closed-enclosure temperature or physical USB performance. The
[provenance index](deepseek-provenance.json) records completed runs and exact
source/evidence identities without private session data.

## Production identities and validation

| Board | Native SHA-256 | Gerber ZIP SHA-256 |
|---|---|---|
| Screen Rev N | `e72850b26ae9076011bc368b69d3f1f1edce758be878bf5fb0decc4f415c5a2f` | `abf39dbf1b7569a1ad25640c081f3e4fb126c94cd8d36d63fb1e559c7c2f8808` |
| Ring | `c53eb16d7531f2c891dc5854faaf40fc1414ebcb2747d0101740e6a35bd1d9ca` | `d25b01306dec7ab2e62ad1db727eb4854e3bb1777295e05be4fbe468f92b0dfd` |
| Console | `c23df586f211bb439081ca951dd23dc54ba21f6d89eb3d373bd6f196749f326d` | `1f50cfc2816fdb3cab0fbaef07b91aad07ee06584f8dac8437a2431869465383` |

The [current manufacturing manifest](../pcb-finish-all-three-1072/manufacturing-zips.json)
binds these boards and every archive member. All three boards have zero native
DRC violations/unconnected items; screen ERC is zero. The unchanged screen
validation passes 103 fault controls and preserves 292 USB copper items and
18 anchors. Independent fabrication comparison passes 175 console/ring and
415 screen assertions. Final ground-loss sensitivity remains below its
20 mV allowance. This documentation pass rechecks identities rather than
claiming newly rerun unchanged tests.

## Release boundary

This is an adversarial design and bare-PCB fabrication review. It does not
establish assembled USB compliance, measured startup or enclosure temperature,
capacitive relay endurance, or the screens' unknown minimum terminal voltage.
The screen input bound applies at J1 before F1, not at the downstream screen.
The reviewed worst-case loss sensitivity is recorded in the screen report.

The ring's unrestricted 40-pixel full-white operation uses the documented
direct AUX star harness; unrestricted full white on all 120 pixels exceeds
the retained supply budget. Enclosure floor mounts and runtime installation
remain separate integration work. No pre-PCB prototype is required by this
review. Ordinary first-assembly checks still remain after fabrication.

Full current-head CI has not run on the stacked feature base. Keep
`ci:pending` and `autonomy:blocked-verify`; no `ready-to-merge` claim follows
from the PCB checks. No order, merge, flash or deployment occurred.
