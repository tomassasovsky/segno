<!-- cspell:words datasheets -->
# DeepSeek review: independent candidate disposition

Completed external review: three boards at HEAD `368b9bd72589e12853ea7d47595351f67c843452`, followed by the final continuation. The completed review text SHA-256 is `2ffc51303811ea298161d6f888f106d572fb15b0efa3379c607255efb7e1f1c2`. It reported two candidates, three disputed assumptions, and no other actionable defect within its supplied evidence. It checked circuit/pad maps, interface wiring, power switches, relay contact logic, buffer gates and selected copper widths; it explicitly lacked firmware, several vendored footprints, manufacturer datasheets and full clearance polygons. Its circuit-level review is useful independent evidence, not a complete physical-board sign-off.

This adjudication independently inspected current source/native files and primary manufacturer documents. **Neither candidate remains an actionable PCB defect.** A source-comment clarification was applied by the console reviewer to make the existing required firmware dependency explicit. The separately discovered R18 issue is repaired and independently reviewed in [console-r18-independent-review.md](console-r18-independent-review.md).

| External claim | Disposition and evidence |
| --- | --- |
| P1: CTRL presence inputs can latch high on A2 after a plug is inserted. | Valid for continuous input-buffer operation, but that is not the required runtime. PR #1082 at `dd46ab0d1a44bc55c7f42bc7db7992773c7a4113` supplies `console_presence.h`: IE is disabled between reads; initialization gives 1 ms discharge; the read enables IE, samples, and disables IE with interrupts protected. The sketch calls that helper for both presence pins. The hardware branch's older firmware is expressly excluded by the assembly/wiring instructions. Raspberry Pi E9 documents this sampling workaround. No copper change is needed. |
| Proposed P1 repair: add 100 kΩ external pull-downs. | Reject. E9 specifies a low-driving source or external pull-down of **8.2 kΩ or less**; 100 kΩ does not implement that alternative. The existing runtime method is the applicable solution. [RP2350 datasheet, E9](https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf). |
| P2: PR01 R8 may have a 10 mm body and not fit DIN0207. | Disproved by the exact family datasheet. PR01 has maximum body diameter 2.5 mm and length 6.5 mm, with coated lead length dimension L2 = 8.0 mm and lead diameter 0.58 ± 0.05 mm. The 10.0 mm body belongs to PR02. R8's actual native holes are 0.8 mm, pads 1.6 mm, pitch 10.16 mm. The selected `PR01000101000FA100` uses straight leads, formed for this pitch; its A1 packaging does not mandate a 12.7 mm installed lead pitch. [Vishay PR01/02/03, dimensions and ordering tables](https://www.vishay.com/docs/28729/pr010203.pdf). The 100 Ω bleeder dissipates at most 0.279 W at 5.25 V and −1% resistance, well below its 1 W rating at the stated operating envelope. |
| Ring-link pull-ups inject about 270 µA into unpowered Pico GP13/GP14. | The assumed forward supply clamp is inapplicable: these are fault-tolerant digital pins, with an unpowered limit of 3.63 V. The normal 3.3 V link is covered. This must not be generalized to analogue GP26/GP27, whose bias source is separately corrected in the board. [RP2350 pin-type and electrical tables](https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf). |
| An enabled Pi pull-up can turn the screen-enable stage on. | Correct disclosed condition, not a new finding. The screen README explicitly requires releasing or driving GPIO17 low during shutdown and prohibits leaving its pull-up enabled. The stage follows GPIO state; it is not a Linux-halt detector. The required runtime owns that signal. This review does not convert software halt into guaranteed electrical power loss. |
| Other connector flanges may create extra chassis bonds. | Not established as a new board fault. The grounding document distinguishes the deliberate H1 bond, isolated H2–H4 pads and possible external paths. Native H1/other-hole connectivity does not prove the eventual connector/enclosure assembly has only one physical bond. No exact new unintended path was demonstrated in the external review, and no unsupported claim of complete assembly isolation is made here. |

The two main candidates were conditional hypotheses rather than reproduced failures: P1 lacked the selected firmware, and P2 lacked the exact part dimensions. They were resolved against those missing primary facts, not dismissed because the prior review was clean.

Current reviewed content hashes (SHA-256):

| Path | SHA-256 |
| --- | --- |
| `hardware/kicad/console_board.py` | `2df2d949ce77289ae929810b2a61fd4355af4e9165261b0ae6e1ba7f24f63eb4` |
| `hardware/kicad/ring_board.py` | `80760bad9e564e5f254c0695840427f83519be74800911b5636a3055cd4d2f6b` |
| `hardware/kicad/screen_power/switch_circuit.py` | `652502f1006b5019752c874b08ff431b5e8bc24cea1dcbf52d50cc513fd23a7e` |
| `hardware/kicad/screen_power/hand/bom.csv` | `11453e0458584697b86bee36f62dde5e376ca67fcdaea2f85060cfc8e52f0cb3` |
| `hardware/kicad/screen_power/hand/screen_power_hand.kicad_pcb` | `8a467b1c6a881cbf7dd117d38366cfda466f1a51c64553296cc374b4ca52cb27` |
| `hardware/kicad/screen_power/README.md` | `94f0279d565ac2b1c15b18b045a978ad97b7467c346a9796150e93f2dee1a23a` |
| `hardware/segno_wiring.md` | `40377cc388d9ee909f28458f334bb8eb63bea2ca8e25f54e06f6fd43e1429cbb` |
| `docs/design/console-grounding-and-bonding.md` | `b798fbc9e1f108b307fcd8df0415fcd627dd975983f180c547812219f9d79aaf` |

Pinned runtime presence-helper SHA-256: `0848f05eff3bf516da201d49a6fc4346e5388850e96aac01ee9765c6548c80fd`.
