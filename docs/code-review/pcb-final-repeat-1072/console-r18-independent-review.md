<!-- cspell:words deepseek -->
# Independent R18 correction and inter-board wiring review

Review completed 2026-09-26. Base HEAD: `368b9bd72589e12853ea7d47595351f67c843452`; review includes the uncommitted R18 repair identified by the SHA-256 manifest below. PR #1080 base: `5fd9f8bf6856673d07b27054d0b98dd7ba719561`. Required runtime was inspected at `dd46ab0d1a44bc55c7f42bc7db7992773c7a4113` in separate PR #1082.

**Result: complete and clean for this independent scope.** The confirmed console UART-input defect is repaired by R18 = 6.8 kΩ, 1%. No additional actionable defect was found in the reviewed inter-board wiring, component rating or hand-assembly constraints. This is design review, not assembled-device or manufacturing certification. The full screen circuit/layout pass is recorded in [screen-review.md](screen-review.md); the console and ring reviewers own their broader board checks and the encoder mechanical review.

## R18: reason for the repair and independent checks

The former 10 kΩ R18 exceeded the RP2350 A2 E9 low-driving-source limit of 8.2 kΩ. E9 concerns enabled input buffers; it is not limited to pins deliberately configured with a pull-down. The separate presence-input sampling workaround cannot service continuously enabled UART RX. [Raspberry Pi RP2350 datasheet, E9](https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf).

I read the actual pinned runtime: `LINK.setTX(16)`, `LINK.setRX(17)` and `LINK.begin(115200)` select hardware UART0. Arduino-Pico 6.0.0 `SerialUART::begin()` calls `gpio_set_function()` for RX; its bundled SDK implementation sets IE and does not enable a pull-up. The runtime's presence helper is used for GP19/GP22 only. No hidden software workaround makes the former R18 acceptable.

Independent arithmetic for the required 1% part:

| Quantity | Result |
| --- | ---: |
| R18 minimum / maximum | 6.732 / 6.868 kΩ |
| Remaining budget below 8.2 kΩ | 1.332 kΩ for the output and interconnect |
| Current with the entire 3.63 V across minimum R18 | 0.539216 mA |
| Resistor dissipation in that condition | 1.95735 mW |
| Maximum R18 × 50 pF time constant | 0.3434 µs |
| Bit period at 115200 baud | 8.68056 µs |

The 20–50 pF timing assumption in the circuit comment is a design estimate for the short ribbon, not a measured cable specification. RP1 documents 2/4/8/12 mA output-drive selections. That supports the intended actively driven GPIO path; the peripheral document does not supply a numerical VOL guarantee from which to manufacture an exact worst-case output resistance. No such guarantee is claimed here. [RP1 peripheral datasheet, §3.1.3](https://datasheets.raspberrypi.com/rp1/rp1-peripherals.pdf).

GP16/GP17 are fault-tolerant digital pads, unlike the console's analogue GP26/GP27 inputs. RP2350's unpowered digital-pin limit and RP1's fault-tolerant input description cover the normal 3.3 V signal while the other supply is off. The 0.539 mA number above is a resistor-current bound, not a published injection-current allowance. Neither the old nor new resistor proves that Pi-off creates a UART break. [RP2350 electrical tables](https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf), [RP1 pads](https://datasheets.raspberrypi.com/rp1/rp1-peripherals.pdf).

I independently loaded the native KiCad boards and parsed the saved netlists. All **279 console pad instances** and **73 ring pad instances**, including duplicated module pads and intentionally unconnected pads, agree. R18's saved net and native connectivity is `J2.24 → R18.1 (LINK_RX_PI)` and `R18.2 → J1.22 (LINK_RX, GP17)`. Source, netlist, routed-board value, placed-board value and the single R18 BOM row all say 6.8 kΩ. R17 remains 10 kΩ. The assembly guide supplies the 1% requirement and correct blue/grey/black/brown/brown bands.

An independent S-expression comparison against HEAD, normalizing only R18's Value property, made **both console native PCB files identical to HEAD**. There is no placement, copper, drill, net, clearance or layer change. Both console and ring remain two copper layers. The screen native hash remains the one reviewed in screen-review.md. The console reviewer separately reports successful regeneration/ERC, 23 circuit negative controls, 15 layout controls, 11 copper controls and temporary-refill DRC 0/0; those are author-run evidence, not duplicate executions by this reviewer.

## External wiring and assembly cross-check

I read the current wiring and assembly instructions and compared the actual native pads, rather than relying on identical connector names:

- Console J2 pins 2/4 are unconnected; the ribbon therefore does not parallel the Pi and AUX 5 V rails. Pins 21/24 carry Pico TX/Pi TX respectively. J25.1 and screen J2.1 are `PI_GPIO17`; both pin 2s are GND. The power button J8/J9 is a floating pin-for-pin pair, with neither terminal tied to board GND.
- Console J3 is +5 V/GND. J24 is GND/pill-DIN/+5 V, matching the specified external pill power bus. The selected ring harness uses console J6.3/.4 to ring J1.3/.4; console J6.1/.2 stay empty. Ring J1.1/.2 use their own short AUX split branch. Ring J2.3 alone carries strip DIN; its power/ground/DOUT pads remain unused. Native ring J3/J4 have a different physical order from J2, but they remain unpopulated in this assembly.
- The 40-pixel strip's 2.44 A allocation bypasses XH and both carrier power paths. Only the 0.2 A ring-controller allocation traverses J1. The documented 16 AWG common pair, short 22 AWG XH pigtails, 100 mm DIN limit and common AUX return match that topology. Genuine XH is rated 3 A with AWG22, with its 85 °C limit including self-heating. [JST XH specification](https://www.jst-mfg.com/product/pdf/eng/eXH.pdf).
- Screen XH pin order is host/device VBUS, D−, D+, GND. J103/J203 separately supply main screen +5 V/GND through VH. Adjacent TP101/102/201/202 are all GND for shield terminations. The cable contract preserves the USB-C source termination and keeps the short shield fan-outs separate from the XH housing. Existing HDMI-only darkness evidence is distinct from GPIO timing and USB signal validation.
- Console CTRL J20/J21 are tip/ring/sleeve/tip-normal on pins 1/2/3/4. Tip bias comes from Pico 3V3, avoiding an analogue-pad supply-off clamp path. PD J23 is GND/SDA/SCL, with no extra supply wire. MIDI IN's isolated input pair has no board-GND connection; MIDI OUT supplies the grounded output shield path.
- AHCT125 DIP14 pin maps, parked spare gates and the 3.3 V input crossing agree with TI's 2 V VIH and 4.5–5.5 V supply requirements. The ring's stated 4.620 V worst-case buffer supply clears that floor under the explicitly stated AUX/harness assumptions. The selected fixed buck has no established manufacturer regulation-floor guarantee, so this conditional calculation remains conditional. [TI SN74AHCT125 datasheet](https://www.ti.com/lit/ds/symlink/sn74ahct125.pdf).
- All reviewed standalone components remain leaded or through-hole, with the accepted Pico/XIAO module exceptions. The guide's socket/header or castellated assembly and USB-disconnection rules address the actual module VBUS/VSYS paths. R18 retains its existing 0.8 mm holes and 10.16 mm lead spacing. Screen R8 was separately checked against the real PR01 dimensions in [deepseek-review.md](deepseek-review.md).

The hand-assembly, thermal, cable and supply limits are not replaced by a clean netlist check. No extra owner measurement or pre-PCB prototype is requested by this review.

## Exact reviewed sources

SHA-256, refreshed after the final encoder correction; the independent mechanical delta is covered by [ring-fix-independent-review.md](ring-fix-independent-review.md). The UART/presence runtime paths were rechecked at the updated runtime pin:

| Path | SHA-256 |
| --- | --- |
| `hardware/kicad/console_board.py` | `2df2d949ce77289ae929810b2a61fd4355af4e9165261b0ae6e1ba7f24f63eb4` |
| `hardware/kicad/console_board.net` | `48fdba08807233f8b9ffb78ed82da1c45f5faed4ba9af14758f2802856086089` |
| `hardware/kicad/console_board_pcb.py` | `4d4a9ed2095e954807c252ae4bb135765c5b3a969a14998de3f673fd98a16108` |
| `hardware/kicad/fab/segno_console_board_bom.csv` | `3f54958c1be1c57a23734595771bd2e9bc7d0361e4597295847d9fb6a73f7030` |
| `hardware/kicad/out_console/segno_console_board.kicad_pcb` | `8bf99b025248c1e5fc704610dbdd14410f5089645d7e03e61a2e03418c295082` |
| `hardware/kicad/out_console/console.placed.kicad_pcb` | `10233e802df0c3c929ed6ca57e40cb6f4f0c5471b2973419acfac1a24bd3563e` |
| `hardware/segno_console_board_v2_soldering_guide.md` | `6c0dace273c92c79db429141363357786a9e676d2016531ddf9f136430103774` |
| `hardware/segno_wiring.md` | `40377cc388d9ee909f28458f334bb8eb63bea2ca8e25f54e06f6fd43e1429cbb` |
| `hardware/kicad/ring_board.py` | `80760bad9e564e5f254c0695840427f83519be74800911b5636a3055cd4d2f6b` |
| `hardware/kicad/ring_board.net` | `0230258a5c541f01c334d1c6012647dc55914e21926a55e96929acf10c063f88` |
| `hardware/kicad/segno_pedal_ring.kicad_pcb` | `e6e1d1bcda4258391ed43a441f9bf8231839abab3b1551660f1b817472f8f62b` |
| `hardware/kicad/RING_ASSEMBLY.md` | `956108399134a0c19f3340f38c69f9194c76dc1fc8fca37e6a3fdd6750e2de2f` |
| `hardware/kicad/screen_power/hand/screen_power_hand.kicad_pcb` | `8a467b1c6a881cbf7dd117d38366cfda466f1a51c64553296cc374b4ca52cb27` |
| `hardware/kicad/screen_power/hand/bom.csv` | `11453e0458584697b86bee36f62dde5e376ca67fcdaea2f85060cfc8e52f0cb3` |
| `hardware/kicad/screen_power/switch_circuit.py` | `652502f1006b5019752c874b08ff431b5e8bc24cea1dcbf52d50cc513fd23a7e` |
| `hardware/kicad/screen_power/README.md` | `94f0279d565ac2b1c15b18b045a978ad97b7467c346a9796150e93f2dee1a23a` |
| `docs/design/console-grounding-and-bonding.md` | `b798fbc9e1f108b307fcd8df0415fcd627dd975983f180c547812219f9d79aaf` |

Runtime contents at the pinned separate commit:

| Path | SHA-256 |
| --- | --- |
| `firmware/console_board/console_board.ino` | `1dfd5e6d1ba50add8c054d447d91726b9e7b58949762e7472978b7ca56695a27` |
| `firmware/console_board/console_presence.h` | `0848f05eff3bf516da201d49a6fc4346e5388850e96aac01ee9765c6548c80fd` |
