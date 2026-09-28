<!-- cspell:words Kimi -->
<!-- cspell:words heatsink -->
# Review — Revision K screen-power completion

Six confirmed findings resolved: 0 critical, 4 important, 2 suggestions.
Zero unresolved findings in the original local implementation reviews. The
subsequent Claude cloud report produced two accepted documentation corrections
and reiterated the upstream-protection assembly requirement. The
[implemented follow-up](../screen-power-claude-fixes-1072/verification.md) now
specifies that external fuse/holder and replaces the R8 preview. OpenCode Go
coverage remains incomplete; this is not a complete multi-model sign-off.

Scope: intended working diff from `9a5798be6c4ea9b0aae2a88fe7168b6751cab441`,
including new models and documents, plus a fresh complete circuit, datasheet,
system-wiring and assembly audit. Originally reviewed native board:
`d35484d551cf8f526f62c4356accbff0492c28999beb0e8830801c39f00c83da`.

## Findings index

| ID | Severity | Rule | Location | Finding | Resolution |
| --- | --- | --- | --- | --- | --- |
| FINDING-01 | Important | system/power-lead-contract | hardware/kicad/screen_power/external_bom.csv | Specify adequate main-power conductors and terminations | Both conductors ≥20 AWG, ≤30 cm, 3 A terminations and matching VH contacts; retain working USB-C attachment electronics. |
| FINDING-02 | Important | assembly/incorrect-component-envelope | hardware/kicad/screen_power/pcb.py | Correct the capacitor models to the purchased parts | Three obsolete generic models removed; exact nominal bodies, polarity and documented trimmed leads supplied, with separate maximum-envelope checks. |
| FINDING-03 | Important | system/aggregate-power-budget | hardware/segno_wiring.md | Include every AUX load and input conversion losses | 9.358 A normal-pattern allowance and about 4.0–4.2 A at the 20 V inlet recorded; unsupported all-white pill load distinguished. |
| FINDING-04 | Important | system/switch-bypass-diagram | hardware/segno_wiring.md | Route main and touch power through the switch in the system diagram | Wiring diagram and connector table now match the native circuit; direct bypass connections removed. |
| FINDING-05 | Suggestion | assembly/mated-plug-clearance | hardware/kicad/screen_power/layout.py | Allow for the complete plugged-in VH housing | C1 moved 1.5 mm; conservative mated-envelope clearance 0.55 mm, zero solid intersection. |
| FINDING-06 | Suggestion | assembly/hidden-polarity-stripe | hardware/kicad/screen_power/model_geometry.py | Expose the capacitor polarity stripe at the sleeve surface | Stripe cut from the cylinder and re-added as a colored exterior solid without increasing its diameter. |

All six fixes were inspected after implementation. The user's trace-finish
request was also completed: eight gradual power tapers and a full-width source
bridge replace abrupt transitions and the extended narrow source bends.
No BOM substitution, connector remapping, board enlargement or extra layer
was introduced.

## Completed independent roles

| Role | Report | Final findings |
| --- | --- | --- |
| Complete circuit and architecture | [Circuit audit](raw/circuit-audit.md) | 0 |
| Project/VGV conventions | [Convention review](raw/vgv-review.md) | 0 |
| Test quality | [Test review](raw/test-quality.md) | 0 |
| Simplicity | [Simplicity review](raw/simplicity-review.md) | 0 |
| Assembly and publication readiness | [Readiness review](raw/pr-readiness.md), [assembly audit](raw/assembly-audit.md) | Confirmed assembly fixes rechecked; publication evidence separated from hardware qualification. |
| Complete system wiring and power | [System audit](raw/system-wiring-audit.md), [corrected matrix](wiring-and-power.md) | Three confirmed documentation/harness findings resolved. |

The circuit, convention, test, simplicity and assembly reviewers did not author
the parent implementation they reviewed. The system auditor corrected only
its explicitly assigned wiring documents; those changes received a separate
parent review. Its independent test/simplicity verdict excludes its own prose.

## External coverage and follow-up

[Actual external model attempts](external-model-reviews.md) document Claude
local session exhaustion and the retried DeepSeek/Kimi/Grok Go quota failures.
A later owner-authorized Claude cloud session completed on the exact K board
and ZIP. Its [assessment](claude-cloud-assessment.md) accepts the Gerber-job
wording and R8 model-coverage corrections, while rejecting unsupported fuse,
startup and body-clearance conclusions. No circuit or routing change was justified. The later
follow-up specifies exact external protection parts and corrects the preview;
source coordination and actual hardware qualification remain unproven. No incomplete external run was relabeled as clean.

## Validation and release boundary

[Verification](verification.md) records zero native ERC/DRC findings, 36/36
regression controls, independent native pin/BOM correspondence, additional
fault mutations, 12/12 GPIO host tests, and fresh source-to-fabrication checks.
The expected screen load supports the documented no-heatsink estimate, not a
guaranteed temperature or unrestricted 6 A assembly rating. Actual supply drop,
USB cables, startup, heat, fit and shutdown timing remain hardware boundaries.
This review does not mark the stacked PR clean or ready to merge.
