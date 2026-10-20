<!-- cspell:words backpower VREG Onsemi -->
<!-- cspell:words AHCT VBUS VSYS SWD GPIO Schmitt normalling pcbnew -->
# Console v3 independent repeat review

Reviewed September 26, 2026. PR #1080 head:
`368b9bd72589e12853ea7d47595351f67c843452`; comparison base:
`5fd9f8bf6856673d07b27054d0b98dd7ba719561`.

This fresh review of the complete current console circuit and native PCB found
one electrical defect and two assembly-document defects. The electrical defect
was found after the initial clean native checks; those checks alone did not
cover the RP2350 A2 UART input-leakage erratum. All three corrections are now in
the working diff. The assigned independent second review is now complete and
clean; see [console-r18-independent-review.md](console-r18-independent-review.md).
The coordinating reviewer owns final all-board manufacturing exports.
Earlier clean reports are historical evidence only.

## Findings and disposition

1. **[P2] Remove the obsolete full-white power-harness instruction.** At the
   reviewed head, `hardware/kicad/README.md:66–80` said the ring used the console
   power path and instructed fitting J6 power/ground leads. The current-v3 row
   in `hardware/segno_console_board_v2_soldering_guide.md:96` also described a
   straight-through cable. An assembler following either instruction could
   restore the long, higher-resistance power path rejected by the current
   voltage-margin assessment, or add a parallel return alongside the selected
   AUX star harness. The required correction is explicit UART-only J6 pins 3/4,
   empty J6 cavities 1/2, separate local AUX branches to strip and ring J1.1/.2,
   and DIN-only ring J2.3. **Resolved in the working diff:** both instructions
   were compared with `RING_ASSEMBLY.md` and `segno_wiring.md` after correction.
   No copper change is needed.
2. **[P2] Correct the current-v3 CTRL jack aperture in the soldering guide.**
   `hardware/segno_console_board_v2_soldering_guide.md:99` calls the NJ6FD-V a
   switched jack using the “same D punch.” This row explicitly describes v3,
   so the guide's historical-v2 warning does not resolve it. Building the
   panel from this instruction produces the wrong mounting aperture. The
   purchase list, wiring document and [Neutrik's primary specification](https://www.neutrik.com/en/product/nj6fd-v)
   agree on rear mounting, 12 mm chassis shape and a 1.2–1.5 mm panel. Replace
   the D-punch phrase with the specified Ø12 mm rear-mounted interface.
   **Resolved in the working diff:** the current-v3 row now specifies
   “rear-mounted through Ø12 mm holes.” No board or enclosure change is needed.

3. **[P1] Reduce Pi-to-Pico UART RX source impedance for RP2350 A2.** At the
   reviewed head, `hardware/kicad/console_board.py:712` sets R18 to 10 kΩ; the
   netlist and BOM agree. Pi GPIO8 / ribbon J2.24 drives R18.1, and R18.2 drives
   Pico J1.22 / GP17, the hardware UART0 receiver.
   [RP2350 erratum E9](https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf)
   requires a low-driving source impedance of 8.2 kΩ or less to overcome the A2
   input-buffer sourcing leakage. The 10 kΩ series resistor exceeds that bound
   before adding driver or wiring impedance, so a supported A2 Pico 2 can fail to
   recognize UART low bits and lose Pi-to-console commands. No silicon-revision
   restriction in the selected module BOM excludes A2.

   The corresponding runtime PR #1082, inspected at
   `92af127d9a2d58c4ea9b810b38d06ca3ddc3c73d`, calls `LINK.setTX`, `LINK.setRX`
   and `LINK.begin` with GP16/17. The Arduino-Pico 6.0.0 `SerialUART::begin`
   configuration enables the GP17 hardware UART input continuously and does
   not enable a pull-up. Its SDK GPIO function selector does not implement
   the E9 input-buffer sampling workaround. The separately implemented CTRL
   presence sampling workaround does not cover this UART. The reset pull-down
   is weak and is not a substitute for the specified low-source impedance.

   **Required fix:** R18 = 6.8 kΩ, 1%; preserve R17 = 10 kΩ. A 6.8 kΩ part at
   +1% is 6.868 kΩ, leaving 1.332 kΩ for Pi output and interconnect below the
   manufacturer's 8.2 kΩ limit. The full 3.63 V rail difference divided by the
   −1% resistance, 6.732 kΩ, is 0.539 mA, below the retained 1 mA series-fault
   budget. This arithmetic is a resistor-current bound, not a claimed
   semiconductor injection-current rating. At the existing 115200 baud, the
   20–50 pF timing assumption gives 0.14–0.34 μs RX RC against an 8.68 μs bit.

   [RP1's primary specification](https://datasheets.raspberrypi.com/rp1/rp1-peripherals.pdf)
   confirms GPIO8 UART3 TX and GPIO9 UART3 RX, the 2/4/8/12 mA output-drive
   settings and unpowered pad fail-safe operation below 3.63 V. It does not
   publish a numeric guaranteed VOL table: this review does not invent one or
   turn the E9 guideline into a separately guaranteed board-level DC margin.
   Pico GP16/17 are also digital fail-safe pads. The prior source rationale
   incorrectly asserted inevitable unpowered-pad clamping/backpower and a
   clamp-induced Pi-off UART break; those assertions were removed.

   **Fix implemented, separate evidence below:** current source/net/BOM and both
   saved native R18 values are 6.8 kΩ. Current assembly instructions explicitly
   require 1% metal-film resistors. Copper, holes and placement are unchanged.

## Functional review coverage

| Path | Independently traced result |
| --- | --- |
| AUX and Pi supplies | Console J3.1 supplies Pico J1.39 VSYS, AHCT U1 and the pill bar. J3.2 is ground. Pi ribbon J2.2/.4 and Pico J1.40 VBUS remain unconnected on the carrier. Pi `+3V3` and Pico `+3V3_PICO` are distinct nets. |
| Pi ribbon and link | J2.24 → R18 → Pico GP17 RX; Pico GP16 TX → R17 → J2.21. At the reviewed head both were 10 kΩ; the correction changes R18 only to 6.8 kΩ, 1%. GPIO14/15 remain MIDI; GPIO24/25 remain SWD. The reserved GPIO4/N07 line and other unused ribbon pins have no console connection. |
| Screen control | J2 physical pin 11 reaches J25.1 as GPIO17; J25.2 is ground. No screen power crosses this connector. The pull-down is on the screen board. |
| Power button | J8.1 → J9.1 and J8.2 → J9.2 are a floating pair. Neither return is joined to console ground. |
| SWD and programming | Native duplicated Pico pads agree on D1 SWCLK, D2 ground and D3 SWDIO. The USB-service instruction disconnects J3/J6/J24 because the Pico's USB diode can energize its external VSYS rail. In-place operation uses the Pi SWD connection. |
| Ten footswitches | GP2–GP11 map in order to J10–J19, each with its own 100 nF shunt and ground return. Firmware pull-ups are required. There is no accidental swapped input or reused pin. |
| CTRL 1/2 tips | J20/J21.1 reach GP26/27 ADC inputs, with separate 10 kΩ pull-ups and 10 nF shunts. Bias now follows Pico pin 36, eliminating the Pi-powered analog-pad path when AUX is absent. |
| CTRL rings and presence | Separate 1 kΩ ring feeds tolerate a passive TS contact to ground. R19/R20 are 4.7 kΩ ring-sense resistors to GP20/21. R21/R22 are 4.7 kΩ TN-presence resistors to GP19/22. These paths remain separate from each other and from the button pair. |
| MIDI OUT | Pi TX drives enabled AHCT gate C; its output and +5 V each use 220 Ω into the DIN loop. DIN output shield is ground. The accepted undriven state is a standing break, not an unbounded current or floating buffer input. |
| MIDI IN | J5 reaches H11L1 pins 1/2 through 220 Ω and the correctly anti-parallel 1N4148. Pins 6/5 are Pi 3V3/ground; output 4 has its 10 kΩ pull-up to Pi 3V3. DIN input shield is not connected. No logic-side DC connection was found in the isolated input nets. |
| Pills | Pico GP18 drives AHCT gate A; U1.3 → R2 330 Ω → J24.2. J24.1 is ground and J24.3 is +5 V. The retired J7 and console ring-data gate are absent; unused AHCT gates have input low and output-enable high. |
| Ring UART | GP13/14 reach J6.3/.4 with 10 kΩ pulls only to the console's Pi 3V3 rail. These agree with the ring contract. For the selected 40-pixel assembly J6.1/.2 stay empty; the retained 1.7 mm power route is not the selected strip supply. |
| PD diagnostics | J23 is ground/SDA/SCL on GP0/1; no power wire returns to the trigger. SparkFun's schematic confirms 2.2 kΩ bus pull-ups to its low-voltage VDD node, fed from VREG_2V7 through BAT60A, rather than USB PD's 20 V rail. |
| Expansion and grounding | J22 contains Pi 3V3, AUX 5 V, GP12, GP15, GP28 and ground. It is optional and unpopulated in the selected build. Only H1 is on ground; H2/H3/H4 retain isolated chassis-pad nets. The assembly guide already limits conductive fastener contact to 6 mm or insulating washers. |

The [Pico 2 specification](https://datasheets.raspberrypi.com/pico/pico-2-datasheet.pdf)
confirms the USB-to-VSYS diode and the distinction between fail-safe digital
pads and analog pads with supply-clamp diodes. The
[RP2350 specification](https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf)
confirms 2.0 V high/0.8 V low limits at 3.3 V and the A2 E9 presence-input
workaround. The explicitly separate runtime PR #1082 remains required; this
hardware review does not approve the older firmware snapshot on this branch.

[TI's AHCT125 specification](https://www.ti.com/lit/ds/symlink/sn74ahct125.pdf)
supports the 3.3 V inputs at a 4.5–5.5 V supply, 8 mA rated outputs, and input
leakage specified with its supply at zero. The MIDI loop's approximately
5–6 mA remains within that output capability.
[Onsemi's H11L1 specification](https://www.onsemi.com/download/data-sheet/pdf/h11l3m-d.pdf)
confirms the pin assignment, 3 V minimum operating supply and 1.6 mA maximum
turn-on threshold for H11L1; the higher-threshold H11L2/H11L3 are not substitutes.
The [SparkFun schematic](https://cdn.sparkfun.com/assets/9/2/6/8/6/SparkFun_PowerDeliveryBoardSchematic.pdf)
was inspected visually against the PD connection, together with the
[STUSB4500 specification](https://www.st.com/resource/en/datasheet/stusb4500.pdf).

## Power, geometry and assembly

The selected console input budget is 0.498 A normal pill channel current,
0.080 A pill idle and 0.140 A console allowance: **0.718 A**. The unrestricted
40-pixel ring is on the separate AUX branch. Recomputed system planning current
is **7.708 A**, including the current screen control/coil allowance. Adding the
separate 25 W Pi allowance gives 74.75 W upstream at an assumed 85% converter
efficiency. This arithmetic is within the specified 100 W PD contract; it does
not promise operation with every LED and both screens at simultaneous maximum.

The native two-layer board retains a two-sided 5 mm +5 V pill bar, 1.2 mm
input/pill ground spokes, a dedicated 1.7 mm ring feed and four parallel 0.5 mm
power-via drills. The remaining +5 V logic tracks are at least 0.7 mm. The
filled front and back copper plots were inspected around input/pill returns,
the ring-feed transition, Pico grounds, the MIDI receiver and connector rows.
No disconnected return or new high-current signal-width bottleneck was found.
The 10 A standard [JST VH rating](https://www.jst.com/wp-content/uploads/2025/06/eVH.pdf)
requires 16 AWG, matching the J3 feed and pill-bus instruction.

Native C11-to-U1.14 and C20-to-U2.6 pad distances are respectively 5.48 mm and
4.83 mm, with local ground return connections. C30/C31 positive pads and the
specified low-ESR C30 value agree with the circuit/BOM. Actual connector drills
are XH 1.10 mm, VH 1.80 mm, IDC/expansion 1.25 mm; Pico through-holes are 1.00 mm.
The 99.5 mm square board retains 1.6 mm FR4, two 0.035 mm copper layers, purple
mask and white legend. Top/angled assembly renders, pin-one/polarity markers,
PILLS/5V legends and the current connector row were inspected. The displaced
Pico USB corridor is an intentional assembly choice covered by the service
instructions, not a newly discovered keepout violation.

## Checks executed on the original reviewed head

All destructive fault injections and zone refills ran in memory or temporary
outputs. The following baseline checks predate the separately documented R18
correction; the review identified the electrical failure despite these passes.

| Check | Observed result |
| --- | --- |
| Fresh `console_board.py` generation | Board assertions pass; ERC 0 errors / 0 warnings. Netlist generation has 0 errors; environment and random-tag metadata warnings were inspected separately. |
| `console_board.py --selftest` | All 21 negative controls trigger their intended gate. |
| Regenerated versus saved netlist | Component inventory, footprints/values and every named-net node set match, disregarding generated metadata. |
| Complete native pad comparison | 206 connected pad identities match. All 236 numbered identities, including 30 intentionally unconnected pins, match; all 279 physical numbered pad instances agree, including duplicate Pico SMD/THT pads. All 66 footprints are accounted for. |
| BOM inventory | 62 unique component references with exact quantities, plus four mounting pads = 66 native footprints. |
| `check_routed_board` plus native placement/silk guards | Pass, including connector drills, power routes, netlist parity, text/mask clearance and power pin legends. |
| `console_board_pcb.py --selftest` | All 15 placement/assembly fault controls pass. |
| `console_ring_power.py … --self-test` | Clean native board and all 11 injected copper faults pass. |
| KiCad 10.0.4 `pcb drc --refill-zones --save-board --severity-all --format json` | Temporary board/project copy: 0 violations, 0 unconnected items. No DRC exclusions are configured. |
| Native render and F.Cu/B.Cu PDF inspection | Completed; no additional verified assembly or copper defect. |

## Reviewed file SHA-256

These hashes identify the native/circuit inputs at the reviewed head. The
documentation and R18 corrections are a subsequent working-tree delta; their
validation and hashes follow separately.

| File | SHA-256 |
| --- | --- |
| `hardware/kicad/console_board.py` | `6d5a60e679292bb18959cee76e5d6e6a0da4b1c722737e3351b92c08700a2176` |
| `hardware/kicad/console_board.net` | `bc07049c367f126779b20d11e765ed4a3d3c2436d94a56eb9b40c926958f1d6b` |
| `hardware/kicad/console_board_pcb.py` | `ef4fa0ac661d9a22b2a06eeeea0ad09f1e89effa6fba9c332aa8aba8958e6084` |
| `hardware/kicad/console_ring_power.py` | `3c598c7a3985f66eb0a1d852745dea4babebf165d6f79945e5eec52dc73dad1e` |
| `hardware/kicad/out_console/segno_console_board.kicad_pcb` | `1c64edd2e49c9e40830d37f0e9b553fd5c57d28cba674f5d815e043c0f226199` |
| `hardware/kicad/out_console/segno_console_board.kicad_pro` | `ef186ba534d8f84fc6d13dc2b43e756c10d027453cd4be2fd2d1c31cb21aab71` |
| `hardware/kicad/fab/segno_console_board_bom.csv` | `ee4ffeb2402a63851d498608a54043aff83e0d367be4a91c08bc2b0e0746cfd3` |
| `hardware/segno_wiring.md` | `b6911763ddbe3bad47c9c23b8f666a51454038b54752c2dc4a7081fef698c048` |
| `hardware/kicad/RING_ASSEMBLY.md` | `9005a029436d94fabdd91b6a479b1da038898a734737e6c482c2269594a9ec87` |
| `hardware/kicad/segno.pretty/RaspberryPi_Pico_SMD_or_THT_Debug.kicad_mod` | `fd558a6e25e51bcc920736cc33b606ec64d3e984b76b6cde9028651a9bac844f` |
| `hardware/kicad/README.md` at reviewed head | `be03ccb20c99fa5dd67c95bf24ba38549bd8966f2519a5805b263dfc42dcefcb` |
| `hardware/segno_console_board_v2_soldering_guide.md` at reviewed head | `c0f4e0ad72c805d9feb81f8dedd9040c90c520720d41c515b22ea33186aa6a50` |



## R18 correction verification — working diff

The scoped correction changes the circuit value, the saved netlist value, the
generated console BOM and the R18 Value property in the placed and routed
native files. The generator now carries that value through on future placement
and the fabrication guard refuses an old native R18 value. Wiring and the
current-v3 soldering-guide override state the new value and tolerance. Source
comments now explicitly tie the A2 CTRL-presence low state to runtime #1082
input-enable sampling/discharge and correct the NJ6FD-V aperture description. The
combined procurement CSV contains ring components only and was not touched.

| Check | Observed result |
| --- | --- |
| Fresh generator and ERC | Circuit assertions pass; ERC 0 errors / 0 warnings; netlist 0 errors. All 138 netlist environment/random-tag warnings were inspected. |
| Circuit negative controls | All 23 pass, including the new 10 kΩ E9 failure and 1 kΩ excessive fault-current mutations. |
| Fresh generated netlist versus saved netlist | Every component, footprint/value and named-net node set matches. Only R18's value differs from the original head; random generated metadata was not republished. |
| Native geometry preservation | Exact byte comparison against the original head confirms that R18's Value string is the sole change in each native board. All tracks, zones, pads, footprint positions, reference legends and project rules are unchanged. |
| Net and pad parity | All 206 connected identities, all 236 numbered identities including 30 NCs, and every one of 279 physical numbered pad instances agree. 66 footprints accounted for. |
| Generated BOM | Exactly 62 unique references with exact quantities; R18 has its own 6.8 kΩ row, R17 remains 10 kΩ. The guide specifies 1% metal film and repeats it in the R18 v3 override. |
| Native R18 negative control | A temporary routed copy with R18 Value restored to 10 kΩ is refused by `FAB: R18 must be 6.8k for RP2350 A2 UART RX`. |
| Routed/layout guards | Pass on the corrected native board; all 15 placement/assembly fault controls pass. |
| Copper fault controls | Clean native board and all 11 injected faults pass. |
| Refilled temporary-copy DRC | KiCad 10.0.4: 0 violations, 0 unconnected items, no exclusions. |
| Whitespace validation | `git diff --check` passes. |

The working-diff evidence is identified by these SHA-256 values. It has not yet
been committed; the original reviewed Git head remains the one at the top.

| File | SHA-256 |
| --- | --- |
| `hardware/kicad/console_board.py` | `2df2d949ce77289ae929810b2a61fd4355af4e9165261b0ae6e1ba7f24f63eb4` |
| `hardware/kicad/console_board.net` | `48fdba08807233f8b9ffb78ed82da1c45f5faed4ba9af14758f2802856086089` |
| `hardware/kicad/console_board_pcb.py` | `4d4a9ed2095e954807c252ae4bb135765c5b3a969a14998de3f673fd98a16108` |
| `hardware/kicad/fab/segno_console_board_bom.csv` | `3f54958c1be1c57a23734595771bd2e9bc7d0361e4597295847d9fb6a73f7030` |
| `hardware/kicad/out_console/segno_console_board.kicad_pcb` | `8bf99b025248c1e5fc704610dbdd14410f5089645d7e03e61a2e03418c295082` |
| `hardware/kicad/out_console/console.placed.kicad_pcb` | `10233e802df0c3c929ed6ca57e40cb6f4f0c5471b2973419acfac1a24bd3563e` |
| `hardware/segno_wiring.md` | `40377cc388d9ee909f28458f334bb8eb63bea2ca8e25f54e06f6fd43e1429cbb` |
| `hardware/segno_console_board_v2_soldering_guide.md` | `6c0dace273c92c79db429141363357786a9e676d2016531ddf9f136430103774` |

The assigned [independent R18 review](console-r18-independent-review.md) is
complete and clean. Its runtime dependency was rechecked at the subsequently
published `dd46ab0d1a44bc55c7f42bc7db7992773c7a4113`; the UART/presence paths
remain the reviewed ones. This report does not substitute for the coordinating
reviewer's final CAM comparison, whole-PR software review, CI or
assembled hardware qualification. No new pre-PCB prototype or owner-measurement
campaign is introduced.
