<!-- cspell:words InputTracker put32 get32 IOVDD -->
# Final bounded DeepSeek review disposition

Completed 2026-09-26 against hardware base HEAD `368b9bd72589e12853ea7d47595351f67c843452` plus the reviewed corrections below, and runtime PR #1082 at `dd46ab0d1a44bc55c7f42bc7db7992773c7a4113`.

**Result: all eight candidates adjudicated; no unresolved actionable PCB defect.** The completed external review covered a bounded correction packet, not the complete native boards or every source cited by the packet. It verified the decoder table and arithmetic, raised four guard/documentation candidates and four evidence gaps, and explicitly withheld judgment on information absent from its packet. Its complete returned text has SHA-256 `4d0a42c90dbd45af7d58f6580ce04ed375dfc7874b3db4a9c4e3870186836ae3`. This disposition uses the actual final files and primary evidence; it does not recast the external response as a full-board clean review.

## Claims 1–4: resolved guard and wording issues

| Claim | Disposition |
| --- | --- |
| 1. “Old 11 mm mounting pitch” control moves only one tab | Verified label error: moving MP1 by 0.8 mm gives a 10.2 mm span. The label now states the actual one-tab movement. The rejection remains valid. |
| 2. “Old 2.54 mm contact pitch” moves only A | Verified label error: only A–C becomes 2.54 mm. The label now names that spacing. |
| 3. Annulus guard is weaker than the prose | The earlier 0.20 mm bound was weaker than the actual 0.235 mm geometry. This was a guard-contract precision issue, not evidence that the final pads were deficient. The final bound is explicitly 0.23 mm, rounded down from 0.235, with nominal and registration claims kept separate. |
| 4. Hole table implies exact finished dimensions | Clarified to **nominal finished-hole diameter**. The adjoining text retains the +0.13/−0.08 mm tolerance and calculated minima. |

I read the final guard/documentation changes and reran its baseline successfully. The author separately reran all eight fault controls. Native PCB and STEP contents did not change in this follow-up. The independent [ring correction review](ring-fix-independent-review.md) records the manufacturer drawing, asymmetric fabrication tolerance and actual final dimensions.

## Claims 5–8: evidence and consumer contract

**5. Model verification — automated limitation verified; current geometry concern disproved.** The guard checks the model reference, transform and existence, not its solid geometry. The separate independent review imported the actual ten STEP solids, checked body/shaft/bushing/terminal bounds, compared the placed native footprint and inspected the KiCad rendering. Terminal model Y signs correctly invert the footprint Y convention. The current drawing-derived envelope is verified within its stated scope; future STEP edits still need that independent geometry/render review. No claim of automated solid-level regression coverage is made.

**6. R18 tolerance — documented requirement, not machine-enforced metadata.** `R("6.8k")` and the console CSV value do not encode tolerance, and the guard assumes 1%. The current wiring instructions and soldering-guide override explicitly require **6.8 kΩ, 1%**; purchasing and assembly must follow those instructions. Sensitivity checking a hypothetical 5% resistor gives 7.14 kΩ maximum, leaving 1.06 kΩ below 8.2 kΩ, and 3.63/6460 = 0.562 mA at minimum resistance. Thus the missing tolerance field does not reveal a failure of these bounds even at 5%; it does not authorize substituting the specified 1% part or claim automated procurement validation.

**7. 3.63 V — sourced, with distinct uses.** RP1 §3.1.3 specifies low pin current below 3.63 V with IOVDD=0. RP2350's digital fault-tolerant pad description and absolute-maximum table likewise specify its unpowered 3.63 V limit. These support the power-off statement. The full 3.63 V across R18 is explicitly a hypothetical resistor-current calculation, not an asserted output level or clamp-injection rating. The source comments already make that distinction and cite both documents. No numeric RP1 low-output-voltage guarantee is inferred. [RP1 peripherals](https://datasheets.raspberrypi.com/rp1/rp1-peripherals.pdf), [RP2350 datasheet](https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf).

**8. Presence E9 — already covered by required runtime.** E9 gives both a low-driving source/pull of at most 8.2 kΩ and an alternative software input-enable workaround. The actual pinned `console_presence.h` disables IE, enables the internal pull-down and waits 1 ms at initialization. Each read enables IE only around `gpio_get`, with interrupts excluded, then disables it; the console samples every 10 ms. The opened jack contact therefore leaves an internally biased pad, not an entirely unbiased floating node. An added ≤8.2 kΩ external pull-down is unnecessary for this selected workaround; R21/R22 are series parts. Continuously enabled UART RX requires the separate R18 correction. This contract excludes running the old hardware-branch firmware unchanged. [RP2350 E9, pp. 1366–1368](https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf).

## Information missing only from the bounded packet

The actual manufacturer PDFs and native before/after comparisons are covered in [the independent ring correction review](ring-fix-independent-review.md): exact part dimensions, support-hole containment, model orientation and exactly five 0.04 mm signal-segment endpoint changes. E9 explicitly applies its source-impedance limit to driving or pulling low, so applying it to the Pi driver plus R18 is consistent with the primary text.

The runtime consumer was inspected directly at the required commit: `ring_link::InputTracker::accept` subtracts unsigned cumulative counters modulo 2³², then converts that difference to signed without an out-of-range cast. `console_board.ino` forwards the signed result in bounded chunks without reversing its sign. A temporary C++ executable using the **actual pinned headers**, built with UndefinedBehaviorSanitizer, passed six cases: +1/−1 normally, across unsigned wrap, and across the signed midpoint. This closes the packet's unsigned-producer/signed-consumer evidence gap. It is a focused consumer check, not a substitute for the separately reviewed firmware suite or device validation.

## Exact contents checked

SHA-256:

| Path | SHA-256 |
| --- | --- |
| `hardware/kicad/ring_encoder.py` | `a4d3aa686fd15bf2cf492d1f843e860156913eb674018f01b730e76ed3c71cb2` |
| `hardware/kicad/RING_ENCODER.md` | `51fcaa60b386fb84fb1f306e9fb48227368c58710bf5861e74bbbf9a37ab441d` |
| `hardware/kicad/ring_encoder_model.py` | `6f2524696720762946491f8cd5434f5dae026dfa96cb7ea03cc936e24684061e` |
| `hardware/kicad/segno.pretty/RotaryEncoder_SameSky_ACZ11BR1E-20FD1-20C.step` | `5667ba66540f7c1ec4d935719788580d6cb87c73a0f58382bacba0e4330eb3e1` |
| `hardware/kicad/segno_pedal_ring.kicad_pcb` | `e6e1d1bcda4258391ed43a441f9bf8231839abab3b1551660f1b817472f8f62b` |
| `hardware/kicad/console_board.py` | `2df2d949ce77289ae929810b2a61fd4355af4e9165261b0ae6e1ba7f24f63eb4` |
| `hardware/kicad/console_board.net` | `48fdba08807233f8b9ffb78ed82da1c45f5faed4ba9af14758f2802856086089` |
| `hardware/kicad/fab/segno_console_board_bom.csv` | `3f54958c1be1c57a23734595771bd2e9bc7d0361e4597295847d9fb6a73f7030` |
| `hardware/segno_console_board_v2_soldering_guide.md` | `6c0dace273c92c79db429141363357786a9e676d2016531ddf9f136430103774` |
| `hardware/segno_wiring.md` | `40377cc388d9ee909f28458f334bb8eb63bea2ca8e25f54e06f6fd43e1429cbb` |

Runtime files below are read from the pinned commit, not the hardware checkout:

| Runtime path | SHA-256 |
| --- | --- |
| `firmware/console_board/console_presence.h` | `0848f05eff3bf516da201d49a6fc4346e5388850e96aac01ee9765c6548c80fd` |
| `firmware/console_board/console_board.ino` | `1dfd5e6d1ba50add8c054d447d91726b9e7b58949762e7472978b7ca56695a27` |
| `firmware/libraries/SegnoPanel/src/ring_link.h` | `4426e039fcd4aa3a06f7c1560044bd0b2596391842c6862af0dc3c29fb91f14d` |
| `firmware/libraries/SegnoPanel/src/pedal_link.h` | `416d9aee77ed95c67ab1d6d4b9e81d60a948de7e821e25271aadb3b35e24358c` |
