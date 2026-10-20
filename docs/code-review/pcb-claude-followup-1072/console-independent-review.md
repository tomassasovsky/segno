<!-- cspell:words IOPORT VREG Qwiic -->
# Independent console delta review — 27 September 2026

Hardware baseline: `a1ff9d6d491c09f6e7f3c8b818440eb5c0493b7e`, working changes in the publication-review checkout. Runtime baseline: `dd46ab0d1a44bc55c7f42bc7db7992773c7a4113`; reviewed current commit `53828fc4eae1c18af45abfc3ea7c31f19f9799d7` in its separate checkout. This is independent review of the scoped repair delta, not a physical USB/thermal qualification or approval of unrelated historical files.

## Source, circuit and runtime verdict

No unresolved actionable finding in the completed source, netlist, harness, runtime-comment and final native-routing delta. Two documentation findings and one native fabrication-guard regression found in this independent pass were repaired and re-reviewed. This verdict applies to the files/hashes below, not release ZIPs generated afterward or physical qualification.

I reviewed every changed console source hunk and its enclosing guards/self-test restore paths, traced both UART pull-ups and both jack-presence paths through the netlist and current runtime caller, and visually inspected the exact jack and SparkFun primary schematics. No functional runtime code was changed or deleted; a text comparison removing comments proves identical sketch/header source against the pinned baseline. The unrelated runtime analysis_options.yaml edit remains present and outside this review.

### UART supply correction

R11/R12 pin 1 now belongs to +3V3_PICO (Pico J1 pin 36); their signal endpoints remain LINK_TO_RING and LINK_TO_CONSOLE. Both UART owners use AUX, so their weak idle bias now follows their power domain when the independent Pi rail is off. The ring does not acquire another pull-up or a connection between two regulator outputs. The complete local-rail assertion catches incorrect rail nodes; the added R11 fault-control restores the resistor to the correct rail before continuing. Existing 5 V cross-board guards and pin-reference assertions remain in force.

My fresh generator execution returned all assertions passing and ERC/netlist errors zero. Independently parsed inventories contain the same 66 components as the baseline. All 54 saved net node-sets equal the freshly generated netlist. Base-to-current electrical delta is exactly two R11/R12 supply nodes moving from Pi +3V3 to +3V3_PICO and two TN-to-RN net renames. I reran all 24 fault controls successfully, including the added Pi-rail UART-bias mutation. Generated comparison netlist and test logs were retained for the release audit.

### Jack harness and presence input

The [Neutrik NJ6FD-V drawing](https://www.neutrik.com/media/8599/download/nj6fd-v-2.pdf?v=1) explicitly identifies separate R/RN and T/TN terminals in a component-side view. The current four-wire harness is T, R, S, RN; TN/SN remain unconnected. J20/J21 pin 4 still reaches R21/R22 and GP19/GP22 respectively. Only the chosen jack contact changes; insertion mechanically opens RN independently of the ring switch after seating. The shopping list, wiring plan, board generator, soldering guide and runtime description now agree.

The existing [RP2350 E9 manufacturer workaround](https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf) explicitly says to disable input enable between samples, enable immediately before reading, then disable again. Current console_presence_read follows this sequence under saved/restored IRQ state; initialization leaves IE off for 1 ms and the caller samples at 10 ms. The caller uses debounced physical presence before ADC classification, preserving the requirement that an expression pedal at its high stop is not treated as unplugged. There is no new ADC fallback or injected output-low pulse. No timing failure was demonstrated by Claude's RP2040 IOPORT premise; RP2350 uses AHB SIO. This is source/instruction evidence, not a claim of measured silicon timing.

RN also improves DC high margin because its 1k feed replaces the 10k tip feed in the empty-jack presence path. At 3.3 V, 36k internal pull-down and both external resistors at +1%, the conservative presence-pin voltage is 2.845 V, above the published 2.0 V VIH; the parallel ring-sense pull-up only helps. The external ring-sense 4.7k path yields 0.469 V with 3.63 V, 32k pull-up and +1% resistor, below 0.8 V VIL. These calculations use the documented 3.3 V pull-resistance range; they are not new low-voltage qualification claims.

I found two documentation inaccuracies during this pass and the coordinator repaired them: the shopping list still named TN, and a newly revised source comment confused pull-down 36–113k with pull-up 32–86k while claiming below 0.4 V. Re-read confirms RN in the shopping list and correct 32–86k / below 0.5 V in source. Both findings are closed.

### PD documentation and layout rule contract

The [SparkFun v10 primary schematic](https://cdn.sparkfun.com/assets/9/2/6/8/6/SparkFun_PowerDeliveryBoardSchematic.pdf) visually confirms D4 BAT60A from VREG_2V7 to the external VDD net. That low-voltage net feeds the two 2.2k I2C pull-ups; it differs from the ST chip's VDD pin, which is on VIN. Existing GND/SDA/SCL-only wiring leaves external VDD/Qwiic VCC unconnected. Current clarification is accurate and adds no electrical modification or new measurement requirement.

The .25 mm generator CLEARANCE constant is used for local pours/placement keepouts. The existing route script explicitly requests .30 mm DSN clearance as margin over the .20 mm native rule. Clarifying this distinction does not remove an electrical clearance guard. Native project enforcement and the repaired copper are reviewed below.

## Final native review

I independently compared baseline and current routed/placed board objects by UUID, pad geometry and net membership, then ran the actual routed-board fabrication guard and a separate all-severity KiCad DRC with all track errors enabled.

- The routed board changes from 3,475 to 3,470 track/via objects. Nine obsolete +3V3 branch objects are removed, 84 existing objects in the former R11/R12 tail are reassigned to +3V3_PICO, and the new supply hop adds two straights, one arc and one via. No retained track geometry changes. Another 175 objects only rename J20_TN/J21_TN to J20_RN/J21_RN. No signal endpoints, placement, orientation, footprint geometry or pad geometry changes.
- The six pad-net changes are exactly R11.1/R12.1 plus J20.4/R21.1 and J21.4/R22.1. All 206 source netlist nodes match the routed native board. The two 3.3 V rails remain separately named and DRC finds no copper short; all new intended connections are complete.
- The first Claude native revision passed DRC but failed the retained fabrication guard: its two new segments were 0.30 mm against the existing 0.60 mm +3V3_PICO floor. This independent finding was returned to the coordinator. Claude repaired the geometry without weakening the guard. Re-review confirms both new straights and the native arc are uniformly 0.60 mm. The arc has nominal 1.2 mm radius and tangent transitions; the via remains 0.8 mm diameter / 0.4 mm drill. The final guard printed PASS and exited 0.
- Both projects now enforce .20 mm minimum clearance, .80 mm minimum via diameter and .40 mm minimum through-hole diameter, with .80/.40 default vias. The physical routed board has 125 vias with .40 mm drills and four with .50 mm drills; its smallest component pad hole is .80 mm. Thus the .40 mm minimum does not silently demand an unsupported drill change.
- The native board remains two copper layers. DRC on the final current routing returns exit 0, zero violations, zero unconnected items and zero schematic-parity findings. A separate final native DRC report was retained for the release audit. Standard pre-existing ignored checks concern missing courtyards, via endpoint centering, tuning profiles and footprint metadata; electrical clearance and connectivity checks are active.
- The placed intermediate retains all 237 original track objects and receives only matching six pad-net changes and project rules. It is intentionally an unrouted placement artifact, not the board submitted for fabrication. Its baseline open-net DRC is not presented as release-clean.

Detailed object comparison and geometry were independently retained for the release audit. The final source/native scope is clean. Final regenerated fabrication ZIPs, manifests and delivery parity remain the coordinator's publication checks; this report does not qualify hardware timing or field operation.

## Reviewed file identities


- `hardware/kicad/console_board.py`: `cf841cc33a759d6838ced2bf1cdc0bd35556974307360c04c28ed8bbcb6c537d`

- `hardware/kicad/console_board.net`: `a96f28757b1916ce5017d44a278174e7bb74a27adbbe037104dcdc6c6c90ef03`

- `hardware/kicad/console_board_pcb.py`: `ffb7be0636dd73d971fcc9f5a0fb3125090fe9e2b17ca38f64ff4b8ff9cdc3c9`

- `hardware/kicad/out_console/segno_console_board.kicad_pcb`: `c23df586f211bb439081ca951dd23dc54ba21f6d89eb3d373bd6f196749f326d`

- `hardware/kicad/out_console/segno_console_board.kicad_pro`: `b6f0d2e12caaa1f31fa17efe77671ea44c61961b9eda1a956f4b7fa23a70a4b0`

- `hardware/kicad/out_console/console.placed.kicad_pcb`: `23623bc5e687ec86b984a5daa2e803ebde18bfc99a2e204a8884422d127ecdb1`

- `hardware/kicad/out_console/console.placed.kicad_pro`: `88eed2d7b4b271203bbb9bf40da5db8005da0c40e427a9c96c3c3a72b5a55b6f`

- `hardware/segno_console_shopping_list.md`: `09dc524343c74023bc69295c261440ef8fba3589f5ca9c613988c097ec7249f3`

- `hardware/segno_console_board_v2_soldering_guide.md`: `580ba8a0e5b3db6ecdf80c531fd61ebc738bdc58cc04544ae110f262e4896026`
