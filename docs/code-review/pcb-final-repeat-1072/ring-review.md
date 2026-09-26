<!-- cspell:words Digi ultrareview autorouter -->
<!-- cspell:words Seeed Worldsemi -->
# Fresh ring-carrier review

Reviewed 2026-09-26 at hardware head `368b9bd72589e12853ea7d47595351f67c843452`, PR #1080, against base `5fd9f8bf6856673d07b27054d0b98dd7ba719561`. This is an independent complete ring-carrier and selected 40-strip-interface review, not a certification of the other boards or an assembled system. No production files were edited. Native checks and calculations ran on the working tree before any ring fixes; final CAM comparison belongs to the coordinating review.

**Result: changes required.** The selected encoder's mechanical specification does not match the fabrication footprint. Its contact-current and runtime detent contracts also need reconciliation. The remaining reviewed ring functions have no new actionable finding under the documented wiring bounds.

## Findings

### R1 — P1: specified ALPS encoder cannot fit the mounting slots

Locations: `hardware/kicad/fab/segno_combined_bom_lcsc.csv:10`, `hardware/kicad/RING_ASSEMBLY.md:45`, `hardware/kicad/segno.pretty/RotaryEncoder_EC11.kicad_mod:33`, and the placed `ENC1` in `segno_pedal_ring.kicad_pcb`.

Trigger: buy the explicitly specified ALPS EC11E18244AU and assemble it into this carrier. The [manufacturer drawing, No. 2](https://tech.alpsalpine.com/cms.media/product_catalog_ec_01_ec11e_en_611f078659.pdf) requires mounting-slot centres 12.5 ±0.05 mm apart. The native carrier and vendored generic C202365 footprint put them at local X = ±5.50 mm, only 11.0 mm apart. Their 1.5 mm cross-slot width does not accommodate the 0.75 mm displacement of each tab centre plus the tab's finite thickness. Native DRC cannot detect this component-to-footprint mismatch. The ALPS drawing also lacks the M7 threaded bush represented by the generic EC11 model and described in the generator's mechanical stack assumptions.

Fix: establish one exact encoder part across the BOM, footprint, model, mechanical assembly and runtime contract. If retaining this ALPS part, use its manufacturer geometry (an upstream KiCad EC11E switch footprint exists), preserve the shaft centre, and reroute/recheck affected copper and clearances. Alternatively specify a verified part that matches the existing mounting geometry and intended threaded-bush assembly. Changing the name alone is insufficient.

The M7 requirement is also explicit in `hardware/enclosure/segno_enclosure.py:540` (7.2 mm clearance hole), line 543 (nut alone clamps the disc) and line 4638 (bushing through disc with nut under the knob). It is not just a cosmetic 3D-model difference.

### R2 — P2: encoder pull-ups are below the selected part's minimum contact current

Locations: `hardware/kicad/ring_board.py:402`–404 and `hardware/kicad/fab/segno_combined_bom_lcsc.csv:5`.

Trigger: use the selected ALPS encoder with the three 10 kΩ pull-ups to 3.3 V. Each closed contact carries about 0.33 mA. The [ALPS product specification](https://tech.alpsalpine.com/e/products/detail/EC11E18244AU/) lists 1 mA minimum resistive rotary-contact current and a 500 µA, 5 V minimum push-switch rating. Runtime internal pull-ups do not raise the rotary contacts to 1 mA. This is operation outside the published minimum-current condition; it is not evidence of an already observed field failure. The manufacturer's generic filter illustration itself uses 10 kΩ at 5 V, so its example is not proof that this exact 3.3 V operating point meets the product table.

Fix after resolving R1's part selection: for a retained 1 mA-minimum contact, 2.2 kΩ pull-ups provide 1.357–1.658 mA with ±5% resistance and a ±5% 3.3 V rail. All three draw less than 5 mA; that current flows through the encoder, not the MCU GPIO driver. The unchanged 100 nF capacitors then give 0.22 ms nominal RC. Update source, netlist, native values, BOM and the documented RC. Confirm the final selected encoder's low-voltage rating as part of its part contract rather than claiming that a resistor change alone changes its published voltage characterization.

### R3 — P2 runtime dependency: selected encoder does not have one full quadrature cycle per click

Location: runtime PR #1082, pinned commit `92af127d9a2d58c4ea9b810b38d06ca3ddc3c73d`, `firmware/ring_board/ring_board.ino:24`–41. This is a hardware/runtime contract finding; no runtime changes or deployment were attempted here.

The selected EC11E18244AU has 36 detents and 18 pulses. Its [manufacturer output waveform](https://tech.alpsalpine.com/cms.media/product_detail_fig_ec11_c_23_en_1cab3884c9.gif) places detents on alternating A states and explicitly makes B indeterminate at the detent. The complete pinned `encoderSample()` emits only on return to `cur == 3`, and calls state `00` the midpoint. Therefore one full A/B cycle produces one event while traversing two physical clicks. It cannot implement its own claim that the emitted quantity is whole detents for this selected component.

Fix: match the decoder to the final encoder, using the manufacturer's detent contract and meaningful waveform tests. If retaining this ALPS part, account for each half-cycle/A transition and B's instability at detents. Keep the runtime dependency distinct from permission to fabricate bare boards.

## Coverage and independent evidence

| Area | Review and result |
| --- | --- |
| Complete electrical source | Read `ring_board.py`, its assertions and negative controls, committed netlist, native PCB, `ring_power.py`, assembly guide, combined BOM and selected wiring. Regenerated the netlist into a temporary directory: exact component/value/footprint parity and exact normalized net membership against the committed netlist. ERC: no errors or warnings. Six generator fault controls rejected. Random SKiDL tag and environment-path warnings were distinct from ERC. |
| Native connectivity | Compared every populated native `(reference,pad)` net assignment with the netlist: exact match, no missing, extra or renamed connections. Native KiCad 10 DRC with all severities and all track errors: **0 violations, 0 unconnected**. Silkscreen/mask guard: no problems. |
| XIAO pin and power contract | Independently checked the [Seeed schematic](https://files.seeedstudio.com/wiki/XIAO-RP2350/res/Seeed-Studio-XIAO-RP2350-v1.0.pdf) and [published pin map](https://wiki.seeedstudio.com/xiao_rp2350_arduino/). D0/GP26 drives the buffer, D1/GP27 and D2/GP28 sense encoder A/B, D3/GP5 senses the switch, D9/GP4 receives the console UART, D10/GP3 transmits. Side pads 12/13/14 are 3V3/GND/VBUS. Only those 14 side pads are fabricated; spare side pads are unconnected. Back-side mirroring gives the expected pad positions. USB faces the clear east rim. The model is openly a XIAO-family envelope substitute, not an exact RP2350 component model. |
| Power and programming | D1 anode is on +5V_LED and cathode on XIAO VBUS; it carries only controller current. C1 polarity and 16 V/low-ESR requirement agree with the board. The assembly's instruction to unplug J1 before USB is necessary: D1 blocks USB-to-AUX current but does not isolate an attached USB host from AUX. UART and power are disconnected together by unplugging J1. No extra battery or underside programming connections are fabricated. |
| AHCT buffer | Compared all 14 pins with [TI SN74AHCT125](https://www.ti.com/lit/ds/symlink/sn74ahct125.pdf): active gate A has /OE grounded, input from D0, output through 330 Ω; the three unused gates have /OE high, input grounded and output unconnected. Supply pin 14 has 100 nF C5 nearby (3.70 mm pad-centre distance), with local ground-plane return. GPIO's 3.3 V high exceeds AHCT's 2.0 V input threshold. C5, bulk cap, diode and buffer package/pad roles are correct. |
| LED options | J2 pin 3 is DIN; pins 1/2/4 are explicitly unused in the selected star harness. J3/J4 remain mutually exclusive 24/16-module alternatives. Fetched and parsed the original Adafruit Ring 24 B and Ring 16 board files from the [manufacturer repository](https://github.com/adafruit/Adafruit-NeoPixel-Ring): their JP1/JP3/JP4/JP2 positions and signals match J3/J4 to rounding (under 0.006 mm), including the KiCad Y inversion. Existing 1.25 mm module holes and model support-pin offsets match the carrier. DOUT is spare; no second strip is authorized. |
| Current path | The selected strip's 2.44 A bypasses J1 and all carrier copper. Controller allowance is 0.20 A. The retained J1-to-J2 1.5 mm front feed and three ≥0.4 mm ground barrels pass the actual-copper guard and **all seven deliberate fault controls**. Alternative-module branches remain 0.65 mm. XH's [3 A rating requires AWG22](https://www.jst-mfg.com/product/pdf/eng/eXH.pdf); the assembly correctly keeps the 16 AWG trunk outside its contacts. |
| Voltage and ground references | Recomputed the selected 600 mm AWG16 trunk and two 50 mm AWG22 branches independently using the published resistivity, 60 °C wire, 10 mΩ joint-pair allowances, aged 20 mΩ XH contacts, 0.20 A controller and 2.44 A strip. At the explicit 4.75 V loaded AUX floor, results are **4.63507 V at the strip input and 4.62338 V at the AHCT**, including the 40 mV carrier allocation. Those exceed the guide's rounded bounds. With the stated 80 mV local ground-offset allocation, TI's light-load output bounds and the [Worldsemi reference thresholds](https://cdn-shop.adafruit.com/datasheets/WS2812B.pdf), worst-case static high margin is 0.64467 V and low margin is 1.21019 V. This does not independently establish the buck's unspecified regulation floor, every strip variant's internal copper drop, or transient/noise immunity. |
| UART | Native J1.3→D9 and J1.4←D10 match console J6.3/4 and pinned `SerialPIO(D10,D9)`. Pull-ups are only at console 3V3; no 5 V rail reaches GPIO. The documented shared AUX returns and 0.20 V offset allocation leave RP2350 static high/low margins; selected wiring deliberately has no parallel high-current console/strip return. The old source comments describing a fully straight-through power cable are historical, not the current assembly contract. |
| Reset and errata | Read the current [RP2350 E9 erratum](https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf), pp.1366–1368. It is not limited to internal pull-downs, but requires an enabled input buffer with output disabled. POR/RUN reset starts with input enable clear; normal driven LED output and pulled-up encoder inputs do not establish an E9 failure here. Thus R5=100 kΩ is not reported as a demonstrated current-use bug merely because it exceeds the erratum's 8.2 kΩ alternate-input workaround. |
| Fabrication and assembly | Native board is an 80 mm circle, two copper layers, 1.6 mm, 35 µm each, white mask/black silk and tented vias. Front/rear ground fills each have three polygons and are stitched by 20 ground vias plus through-hole grounds; DRC reports no isolated/unconnected conductive items. No screw holes; snap mounting is the declared design. Reviewed fresh native bottom render, footprint orientation, hole roles, USB approach and component clearances; encoder part mismatch R1 prevents blanket mechanical approval. No CAM archive was regenerated by this reviewer. |

Selected commands: KiCad `pcb drc --format json --severity-all --all-track-errors`; KiCad Python `ring_power.py … --self-test`; temporary-directory SKiDL `ring_board.py` and `ring_board.py --selftest`; native pad-net/geometry inspection and `silkscreen.mask_clearance_problems`. Fresh DRC and render are temporary review artifacts, not manufacturing deliverables. No added prototype or owner measurement is requested.

## Replacement investigation, not yet an applied fix

The [Same Sky ACZ11 manufacturer datasheet](https://www.sameskydevices.com/product/resource/acz11.pdf), fetched directly as revision 1.08 dated 05/07/2026, supports `ACZ11BR1E-20FD1-20C`: momentary switch, M7×0.75 threaded bushing 5 mm long, 20 mm flat 6 mm shaft, vertical, 20 pulses and 20 detents. Hand soldering is explicitly allowed at up to 350 °C for at most 3 seconds. Its 20C detents have both contacts open, matching logic state `11` with pull-ups and the pinned runtime's full-cycle count. No minimum contact current is specified; supply is 5 V maximum and the suggested filter uses 10 kΩ pull-ups.

It is **not** a replacement in the existing footprint: its vertical switched drawing requires 9.4 mm mounting-slot centres with 1.8×2.1 mm slots, A/C/B at X=−2.5/0/+2.5 and Y=+7.5 mm, and switch contacts at X=±2.5, Y=−7 mm relative to shaft centre. Signal holes are 1.2 mm. The body-to-shaft datum is 6.5 mm above seating, followed by the 5 mm bushing; the exact model and mounting stack must be updated. This review did not buy, select or fit that part. Downloaded datasheet SHA-256: `a1d5e9764abdf31c5da469bc044ad1ea916185cd0b6459b692f1e1aa52396996`.

## Reviewed SHA-256 identities

| Path | SHA-256 |
| --- | --- |
| `hardware/kicad/ring_board.py` | `ccffc72aec110fffb18a20e2158b11a27a45e1d3ddceacc6b2e3c5cc30c30260` |
| `hardware/kicad/ring_board.net` | `7760982472f448cf3b811a0f9a71d5d7a9122665311d130c561f767dcf3e379a` |
| `hardware/kicad/segno_pedal_ring.kicad_pcb` | `5ade14170d0280c922b7966e1f1d85d53a0e7ff9510e8342788400b7fe05d50b` |
| `hardware/kicad/ring_power.py` | `d2dcb84bc34a77f9ab27c0f2bbbeb939dfa4594ab0f3682557730d3f025c8548` |
| `hardware/kicad/RING_ASSEMBLY.md` | `9005a029436d94fabdd91b6a479b1da038898a734737e6c482c2269594a9ec87` |
| `hardware/kicad/fab/segno_combined_bom_lcsc.csv` | `580dbb365cbe8b6d84131ff3abf5b2d5eb9661987ba9df1885169d242bb6497b` |
| `hardware/segno_wiring.md` | `b6911763ddbe3bad47c9c23b8f666a51454038b54752c2dc4a7081fef698c048` |
| `hardware/kicad/segno.pretty/RotaryEncoder_EC11.kicad_mod` | `a6f5ad796222b36d51098aa60740e2fc1d04932197673efa87c17b283ee1d72e` |
| `hardware/kicad/segno.pretty/XIAO_RP2350_SMD.kicad_mod` | `76688f46c647042ac04967c5e6bad3e361673f2273afaefaa38ffda0805c8f16` |

## Applied follow-up: exact Same Sky replacement

The owner confirmed that the encoder had not been purchased and authorized selecting
a suitable part. The hardware now specifies **Same Sky ACZ11BR1E-20FD1-20C**.
The original R1/R2/R3 findings above describe the reviewed initial revision and
remain as the evidence trail; this follow-up is implementation evidence, not the
required independent approval of the author's own fix.

- Added the exact manufacturer-derived footprint, source-linked fit contract,
  nominal 3D envelope and reproducible model generator. Removed the inaccurate
  generic EC11 footprint/model after searching every tracked native PCB, module,
  schematic, Python source and VRML file for other consumers. Only historical
  review hash records retain the obsolete names.
- Preserved shaft centre (35.9825,35.7675), the board outline, all other footprint
  pad geometry, all vias, power geometry, net names, layers and track widths.
  Exactly five A/B/SW track endpoints moved 0.04 mm inward. Ground zones were
  refilled. Signal holes are 1.3 mm with 1.9 mm pads; support holes are 3.0 mm
  with 3.6 mm pads on the manufacturer's 9.4 mm pitch. Finished hole tolerance
  is the fabricator's asymmetric +0.13/−0.08 mm. The review caught the first
  guard's incorrectly symmetric tolerance; the corrected design and eight
  controls supersede it. Annulus documentation distinguishes concentric
  diameter tolerance from registration.
- Retained 10 kΩ / 100 nF filters. The exact new part removes the old ALPS minimum
  contact-current mismatch and has one full cycle per detent at logic 11.
  Tracing the entire runtime consumer found that clockwise A-first transitions
  formerly decreased gain. The coordinator separately fixed the direction and
  bounce handling in runtime PR #1082 at
  `dd46ab0d1a44bc55c7f42bc7db7992773c7a4113`; this revision is pinned in the
  hardware assembly/encoder guides. No runtime installation occurred.
- Added the separately sourced SJ5-43502PM-nut (Same Sky primary drawing:
  M7×0.75, thickness 2.0±0.1 mm, AF 10.0±0.1 mm). The documented nut-alone clamp
  on the 2 mm disc fits the minimum 4.7 mm bushing; no undocumented washer stack
  is claimed. This nut is separately available as DigiKey CP5-43502PM-NUT-ND.
- At the coordinator's request, hid all 10 unpopulated RING1 alternative-module
  models for the selected external 40-strip assembly, retaining them for optional
  display. Updated its native description. This is display metadata only.
- Added the native encoder guard before the ring route script's fabrication
  export. Updated source comments to describe the selected split AUX supply,
  push-pull SerialPIO UART and parallel runtime internal pull-ups accurately.

The user's requested Claude authoring route was unavailable: the coordinator's
local attempt reached its session limit, and cloud ultrareview rejected the
full PR size. The bounded native correction was therefore implemented directly
and handed to a different reviewer. No global rip-up/autorouter was run.

Validation: SKiDL assertions/ ERC passed (zero ERC errors or warnings; generic
SKiDL random-tag/environment warnings are separate), all six generator negative
controls passed; exact native parity with the regenerated 18-component,
63 connected-pad netlist; the complete net graph is unchanged. Native KiCad DRC
with all severities/track errors returned zero violations and zero unconnected.
The native encoder guard rejected all eight physical/net/part faults, the power
guard rejected all seven faults, and the silkscreen guard found no problems.
STEP inspection confirmed ten model solids with the documented body, bushing,
shaft and terminal coordinates. Python compilation, shell syntax and scoped
whitespace checks passed. The coordinator owns final fresh CAM and STEP export.

### Post-fix identities handed to independent review

| Path | SHA-256 |
| --- | --- |
| `hardware/kicad/ring_board.py` | `80760bad9e564e5f254c0695840427f83519be74800911b5636a3055cd4d2f6b` |
| `hardware/kicad/ring_board.net` | `0230258a5c541f01c334d1c6012647dc55914e21926a55e96929acf10c063f88` |
| `hardware/kicad/segno_pedal_ring.kicad_pcb` | `e6e1d1bcda4258391ed43a441f9bf8231839abab3b1551660f1b817472f8f62b` |
| `hardware/kicad/segno.pretty/RotaryEncoder_SameSky_ACZ11BR1E-20FD1-20C.kicad_mod` | `d7a8f08e9ccbff5734c54407f2b0748c386ee8144b3dec9925b74416a70634f5` |
| `hardware/kicad/segno.pretty/RotaryEncoder_SameSky_ACZ11BR1E-20FD1-20C.step` | `5667ba66540f7c1ec4d935719788580d6cb87c73a0f58382bacba0e4330eb3e1` |
| `hardware/kicad/ring_encoder.py` | `e412d2eb36882b17f40a29e14c7c07e50bec5b0c0477913f707e90f10f21afdd` |
| `hardware/kicad/ring_encoder_model.py` | `6f2524696720762946491f8cd5434f5dae026dfa96cb7ea03cc936e24684061e` |
| `hardware/kicad/RING_ENCODER.md` | `6c2ecdd91f4347ca09d71a4084b215967f85d842053450c7136fccc701e1dc9a` |
| `hardware/kicad/RING_ASSEMBLY.md` | `956108399134a0c19f3340f38c69f9194c76dc1fc8fca37e6a3fdd6750e2de2f` |
| `hardware/kicad/fab/segno_combined_bom_lcsc.csv` | `a9d470f62531d340970e17baa51b735831d7cf414dc6a7b2130ca9a93e9a54f9` |
| `hardware/kicad/route_ring_board.sh` | `50cd9ec95bfad605ff082c06b27ca90fb83e76abe5defaee77d9c92e8650cdf6` |
| `hardware/kicad/fp-lib-table` | `222a3e8634b40e312fe6cf8d741f12244c61980d08db9f92b4e5751c6e63015a` |
