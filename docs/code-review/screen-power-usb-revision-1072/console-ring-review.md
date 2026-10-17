<!-- cspell:words busbar datasheets -->
# Console/ring accumulated-change bug review

- PR: #1080, stacked on `feat/console-board-5v-1062`.
- Exact merge base: `5fd9f8bf6856673d07b27054d0b98dd7ba719561`.
- Reviewed committed head: `d4fde1951cdfd384eced740d9f599c255ebe2b95`, plus the current working wiring clarification for Revision M.
- Scope: accumulated console/ring circuit and placement-source changes, high-current route installers/guards, relevant footprint/export changes, selected 40-pixel assembly, harness/current/voltage calculations and runtime pin-map dependency. The screen circuit/lifecycle service and general-purpose routing/finishing algorithms are other review angles, not duplicated here.

## Findings

No actionable correctness finding in this bounded console/ring angle. This is not a declaration that the entire accumulated PR is reviewed or ready to merge/order. Screen Revision M is deliberately awaiting native routing and release validation; the existing screen order hold remains.

## Cross-file circuit and wiring review

Read the complete accumulated diffs of `console_board.py`, `console_board_pcb.py`, `ring_board.py`, `board_stackup.py` and both routing entrypoints, and inspected the new `console_ring_power.py` and `ring_power.py` route/guard implementations. Traced the removed/changed invariants:

- Reducing the generic console +5 V track floor from 0.70 to 0.60 mm no longer weakens the dedicated high-current ring route: its separate 1.7 mm route, four parallel power vias and ground thermal requirements are checked independently. The selected strip's LED current now bypasses that long console route entirely.
- Pill current still crosses the filled two-layer J3/J24 busbar; its pad ordering remains J3.1 +5 V and J24.3 +5 V, with J24.1 ground and J24.2 data. Added zone blends do not replace the mandatory routed power path.
- CTRL bias changes from Pi 3V3 to Pico pin 36, matching the ADC domain. Native connected pads show the isolated `+3V3_PICO` net only on pin 36 and R7/R8/R9/R10. Pi 3V3 remains distinct. GPIO17 reaches only Pi header physical pin 11 and J25.1; J25.2 is ground. The moved J8/J9 button pair remains two isolated, corresponding nets.
- The selected ring harness maps J6.3 to ring J1.3 and J6.4 to J1.4; console J6.1/.2 stay empty. Ring J1.1/.2 receive the separate short controller-power branch. Strip power/ground receive their own branch from the same local AUX split, and strip DIN uses ring J2.3 only. Leaving J2.1/.2/.4 empty prevents an unintended parallel high-current return.
- The carrier's XIAO power diode is correctly oriented from `+5V_LED` to `+5V_MCU`. Programming instructions correctly require disconnecting J1; the diode is not misrepresented as protection against AUX feeding the USB host.
- Alternative 24/16 module pad orders are consistent with their native nets, and selected-strip instructions require leaving both footprints unpopulated. No brightness-limit assumption is needed for the PCB current design.

The native pad maps agree with the authored console and ring netlists: 206 and 63 connected pad identities respectively, with no conflicting duplicate identities.

## Direct-AUX voltage and logic bounds

Independently recomputed the published star-feed arithmetic from its stored inputs: 600 mm maximum 16 AWG trunk, separate 50 mm maximum 22 AWG branches, 2.44 A strip, 0.20 A controller, 60°C wire, the stated termination allocations and 40 mV carrier allowance. The result is **4.623384 V at the AHCT supply** and **4.635069 V at the strip supply input**, matching the recorded evidence. The actual ring/enclosure hashes in that voltage assessment still match the current files.

Primary datasheets support the stated thresholds and connector assumptions: [TI AHCT125](https://www.ti.com/lit/ds/symlink/sn74ahct125.pdf) gives the 4.5 V operating floor and 4.4/0.1 V output bounds at light load; [JST XH](https://www.jst-mfg.com/product/pdf/eng/eXH.pdf) gives 3 A with 22 AWG and 20 mΩ contact resistance after environmental testing; [RP2350](https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf) gives the cited 3.3 V output bounds and digital-pad unpowered tolerance. The resulting logic-offset arithmetic is consistent with the published local-ground allocations.

The calculation properly retains its limits: assumed buck floor, bounded splice resistance, unmeasured enclosed conditions, supply-pad rather than every-pixel voltage, and no dynamic signal-integrity guarantee. These are not presented as manufacturer warranties. The required 7.708 A system budget includes the new 0.100 A AUX relay/control allocation and normal pills; unrestricted white on all 120 pixels is explicitly excluded from the nominal 10 A supply budget.

## Firmware dependency tracing

Inspected the actual pinned runtime commit `92af127d9a2d58c4ea9b810b38d06ca3ddc3c73d` with `git show`, rather than assuming this hardware branch contains the completed firmware:

- Console uses GP13 TX / GP14 RX through `SerialPIO` at 115200 baud, matching J6.
- Ring uses D10/GP3 TX and D9/GP4 RX, matching native U1 pads 11 and 10; D0 drives the buffer and D1/D2/D3 read the encoder.
- Ring count is 40; pill count is 10 × 8 with the recorded button order/reversal. Runtime retains brightness 128; assembly docs correctly separate that present behavior from unrestricted hardware capacity.
- Ring assembly instructions explicitly require the matching separate v3 runtime/UF2 and distinguish the old-board firmware. Firmware was neither rebuilt nor deployed during this review; its behavior is not re-certified here.

## Fresh native and fabrication checks

Ran the existing read-only independent console/ring CAM verifier against the actual current worktree. It exported into a temporary directory and reported **175 passed / 0 failed** assertions. Both boards have two copper layers, 1.6 mm thickness, and correct mask/legend choices. Both fresh DRC reports contain zero violations and zero unconnected items. Native pad maps, tracked loose CAM and current ZIP members agree under the verifier's strict normalization; its source/archive preservation checks pass.

Also executed the high-current native guards directly using KiCad Python:

- Console: clean board passes; all **11** deliberate power-route faults rejected.
- Ring: clean board passes; all **7** deliberate feed/return faults rejected.

The scripts emitted KiCad/wx initialization diagnostics but both exited zero and printed their expected success summaries. No production source, native board, archive or device was modified by these runs.

| Current artifact | SHA-256 |
| --- | --- |
| Console native board | `1c64edd2e49c9e40830d37f0e9b553fd5c57d28cba674f5d815e043c0f226199` |
| Console manufacturing ZIP | `919667b6141639590da8dd36319b236e5c434c4d8f2f3799644374e81da97fc3` |
| Ring native board | `5ade14170d0280c922b7966e1f1d85d53a0e7ff9510e8342788400b7fe05d50b` |
| Ring manufacturing ZIP | `7b0dd11efc0ab1f2c2f3a28a0a1bb6367d692171ad4136ea9fae49bcabc5a413` |
| `console_board.py` | `6d5a60e679292bb18959cee76e5d6e6a0da4b1c722737e3351b92c08700a2176` |
| `ring_board.py` | `ccffc72aec110fffb18a20e2158b11a27a45e1d3ddceacc6b2e3c5cc30c30260` |
| `console_ring_power.py` | `3c598c7a3985f66eb0a1d852745dea4babebf165d6f79945e5eec52dc73dad1e` |
| `ring_power.py` | `d2dcb84bc34a77f9ab27c0f2bbbeb939dfa4594ab0f3682557730d3f025c8548` |
| `RING_ASSEMBLY.md` | `9005a029436d94fabdd91b6a479b1da038898a734737e6c482c2269594a9ec87` |
| Working `hardware/segno_wiring.md` | `b6911763ddbe3bad47c9c23b8f666a51454038b54752c2dc4a7081fef698c048` |

## Review completeness

This angle completed changed-hunk reading, removed-invariant tracing, source-to-native pin comparison, independent harness arithmetic, primary-limit verification, runtime pin-map dependency checking and fresh exact native/CAM checks. It did not independently derive every earlier mechanical model, rebuild the external runtime, test an assembled unit or certify its electromagnetic behavior. Shared rounding/export helper internals and the screen/lifecycle changes require their separately assigned angles. No labels were changed; complete current-head review and observed CI remain required by the repository contract.
