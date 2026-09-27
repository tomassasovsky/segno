<!-- cspell:words IOPORT normalling VREG Qwiic -->
# Console Claude findings: independent adjudication and scoped source repair

27 September 2026. Hardware baseline a1ff9d6d491c09f6e7f3c8b818440eb5c0493b7e; required v3 runtime baseline dd46ab0d1a44bc55c7f42bc7db7992773c7a4113. This report reviews the completed Claude console result and primary evidence; it is not a new full-console verdict. The source/harness repairs below were authorized by the coordinator after the initial read-only adjudication. Native routing, project edits, final exports and independent review of this author's repairs remain the coordinator's work.

## Disposition

| Claude item | Independent conclusion | Action |
| --- | --- | --- |
| F1 deterministic input-enable race | Not established; its single-cycle IOPORT premise describes RP2040, not RP2350. Manufacturer workaround and current compiled sequence do not support the claimed inevitable failure. | Keep functional presence code unchanged. |
| F1 tip-normal loading / ring-normal alternative | Empty-jack tip loading is real, but it does not itself cause a false pedal when the presence input works. The same purchased jack provides RN. Moving the harness lead improves independence and high margin without extra parts or a copper-topology change. | Source and assembly now specify RN; runtime comments match. |
| F2 ring UART idle rail | Real domain mismatch: two AUX-powered UART owners should not depend on the independently powered Pi rail for undriven idle bias. Active output drivers can overcome the old 10k load; a permanent runtime failure was not proved. | R11/R12 pin 1 source/net changed to +3V3_PICO. Native reroute pending. |
| F3 PD idle rail unknown | Closed by the primary SparkFun schematic and ST pin description. External VDD net and ST chip VDD pin are different nodes. | Clarified exact no-VDD-wire contract; no extra pull-ups, JP1 cutting or owner measurement gate. |
| F4 global .25 mm rule | The .25 constant is local zone/placement clearance. Existing routing deliberately uses .20 mm board rules; .30 mm router request is documented rounding headroom. | Clarified the constant's scope. Recommend project .20 mm minimum and actual .8/.4 mm via defaults/minima; temporary-copy DRC passes. |

## F1: current runtime and manufacturer recommendation

I read actual pinned console_presence.h and its pollCtrl caller. The presence input is authoritative: after the 50 ms debounce, a high input detaches the jack and bypasses ADC classification. The old ADC-only detection was deliberately removed to stop a real expression pedal at its high stop appearing unplugged. Thus neither the existing design nor RN creates an independent ADC unplug fallback.

[RP2350 datasheet](https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf), E9, instructs switching IE on around a software sample and off between samples. It specifies no added readback/barrier/delay. Section 2.1 explicitly distinguishes RP2350's dedicated AHB SIO ports from RP2040's Cortex-M0+ IOPORT. The local Arduino-Pico 6.0.0 SDK implements gpio_set_input_enabled as a write to the PADS atomic set/clear alias; gpio_get reads SIO GPIO_IN. Section 2.1.4 gives APB reads/writes a minimum three/four cycles; §12.15 describes the input synchronizer's two-cycle latency.

I built the exact console target with Arduino-Pico 6.0.0 and inspected actual ARM instructions. At 0x10007972 the SDK stores IE, returns at 0x10007974, then the caller executes CMP, MOV, conditional branch and MOV before SIO LDR at 0x10003a96. This is not the claimed immediate single-cycle IOPORT access. I did not execute this timing on physical RP2350 silicon, so instruction inspection is not a hardware timing certification. It does, however, invalidate the claimed deterministic failure proof. No speculative functional change, busy wait or barrier was added.

The real DC loading is separately reproducible. At 3.3 V with 36k internal pull-down, old T/TN wiring gives tip = 3.3 × 40.7/50.7 = 2.649 V and presence GPIO = 3.3 × 36/50.7 = 2.343 V. Tip can lie below CTRL_HIGH=3584/4095 of full scale, but the working high presence input prevents that ADC value from becoming a pedal. With R/RN wiring, the ring feed is 1k: ring = 3.3 × 40.7/41.7 = 3.221 V and presence GPIO = 3.3 × 36/41.7 = 2.849 V. Claude called the 3.22 V ring-node voltage the presence voltage; the corrected pin value still clears 2.0 V VIH. The parallel ring-sense pull-up only improves this simplified conservative high calculation. These are nominal-rail circuit calculations, not measurements or blanket contact-reliability guarantees.

[Neutrik NJ6FD-V primary drawing](https://www.neutrik.com/media/8599/download/nj6fd-v-2.pdf?v=1) was downloaded and rendered. Its component-side terminal drawing explicitly labels RN separately from R, T/TN and S/SN. The [product page](https://www.neutrik.com/en/product/nj6fd-v) identifies three normalling contacts. No jack substitution is necessary. Once inserted, RN is mechanically disconnected from R, so pressing a dual footswitch on the ring cannot change presence; the existing ring-switch sensing path remains separate. Current harness is console J20/J21 pins 1/2/3/4 to T/R/S/RN; TN and SN unused. Source names J20_RN/J21_RN replace J20_TN/J21_TN. R21/R22 values, PCB pad 4 destinations and sense GPIOs remain unchanged; native files need the matching net-name update only for these paths.

## F2: AUX-domain idle bias

R11/R12 now connect their pin 1 to Pico pin 36 (+3V3_PICO), with pin 2 still on LINK_TO_RING / LINK_TO_CONSOLE. Both controllers are powered from the AUX branch while the Pi can be off or disconnected. This avoids grounding their weak idle bias through the Pi's dead supply. It does not require a second pull-up on the XIAO or coupling two regulator outputs.

The complete local-supply node-set assertion now includes R11/R12. A new negative control moves R11 back to Pi 3V3 and must fail CTRL_SUPPLY. The separate ring 5 V-level guard remains intact. The source report, generator comments and assembly documents distinguish Pi MIDI/expansion 3V3 from Pico CTRL/UART 3V3. Two short supply branches in the actual routed and placed boards must be updated by the coordinator/Claude before any final native validation.

## F3: PD primary evidence

The [SparkFun v10 schematic](https://cdn.sparkfun.com/assets/9/2/6/8/6/SparkFun_PowerDeliveryBoardSchematic.pdf) was visually re-read. D4 is BAT60A from STUSB4500 VREG_2V7 to the external VDD-labelled net. That external net powers both 2.2k bus pull-ups through JP1 and connects to the optional VDD/Qwiic VCC headers. The ST chip's own VDD pin instead connects to VIN. The label reuse is the source of Claude's uncertainty.

The [STUSB4500 primary datasheet](https://www.st.com/resource/en/datasheet/stusb4500.pdf) identifies VREG_2V7 as the internal 2.7 V regulator output and chip VDD as the USB-line supply input. Leaving external VDD/Qwiic VCC disconnected prevents an external 5 V source from setting this low-voltage bus rail. Current assembly already used three wires GND/SDA/SCL only. Source and wiring now explicitly explain the D4/regulator path. No new hardware modification or measurement gate follows from the rejected claim. This establishes topology, not independently measured I2C waveform margins.

## F4: enforced native rules versus local spacing

route_console_board.sh lines 42–45 explicitly document .20 mm board DRC and .30 mm DSN routing clearance. console_board_pcb.py CLEARANCE=.25 is used for zone local clearance and placement/via keepouts, not routed-track clearance. Actual via geometry is already checked by MIN_VIA_D=.8 / MIN_VIA_DRILL=.4 in the native fabrication guard. Merely changing a class's default via size does not retroactively resize existing vias.

Two native KiCad DRC runs were performed on separate temporary board/project copies only:

- Global/class .25 mm, minimum/default via .8/.4: 10 clearance violations, zero unconnected. The smallest reported clearance is .2105 mm. This is a tighter-rule experiment, not a newly introduced failure under the actual .20 mm design.
- Global/class .20 mm, minimum/default via .8/.4: zero violations and zero unconnected. All severities enabled; zones refilled on the copy.

Recommended project fields: net_settings.classes[].clearance=.20, via_diameter=.8, via_drill=.4; board.design_settings.rules.min_clearance=.20, min_via_diameter=.8, min_through_hole_diameter=.4. Leave track width and other unrelated settings unchanged. The coordinator owns these native-project edits; none were made here. No unnecessary .25 mm reroute is justified by the available evidence.

## Work completed and checks

Hardware source/doc edits: console_board.py, console_board.net, console_board_pcb.py, hardware/kicad/README.md, hardware/segno_wiring.md, hardware/segno_console_board_v2_soldering_guide.md, hardware/MANUFACTURING.md. Concurrent ring agent changes were preserved through narrow patches. No native PCB, project, manufacturing ZIP or delivery folder was written by this agent.

An additional assembly-document mismatch was closed: MANUFACTURING.md offered unspecified removable Pico headers although the selected soldering guide requires castellations and no exact removable header is documented. Its console row now instructs castellation soldering. The existing nominal 1.0 mm holes do not by themselves qualify an arbitrary header pin envelope/tolerance or raised module installation. No footprint change is needed.

Runtime edits in the separate checkout are comments/README only: console_presence.h, console_board.ino, README.md. They say ring-normal instead of tip-normal. No behavior changed. The unrelated packages/looper_repository/analysis_options.yaml edit remains untouched.

- Fresh console generator: circuit assertions pass; ERC zero errors/warnings; netlist zero errors. Its 138 netlist metadata/environment warnings remain the known SKiDL warnings.
- Console source fault controls: 24/24 intended gates triggered, including the new Pi-rail UART-bias mutation.
- Fresh generated component inventory and every net-node set equal saved console_board.net. Saved netlist retains existing IDs/metadata with only two renamed nets and the two rail nodes moved.
- write_bom regenerated the console BOM; it is byte-identical because parts/values/quantities did not change.
- Full firmware host test runner: eight suites pass, including 58 pedal codec fixtures, actual console CTRL flow and E9 sequencing. Tests were run after the comment changes.
- Real Pico 2 build before comment-only updates: 71,272 bytes flash, 11,172 bytes RAM. Disassembled binary is retained for the F1 trace. No flashing/deployment.
- Scoped git diff --check passes.
