<!-- cspell:words Lumberg Omron IRLZ NPBF PGOOD DPDT -->

# Architecture Review

## Scope and independence

Reviewed the current through-hole hand carrier, integrated factory board, and
bounded console J25 change for issue #1072. This report supersedes reviews of
the abandoned 40-pin pass-through and surface-mount hand versions. The relevant
stack is Python, SKiDL 2.3.0, native KiCad 10 schematics/PCBs, and Freerouting;
Flutter architectural rules do not apply to these files.

The reviewer previously authored portions of the assembly documentation, the
Lumberg 2411 06 footprint correction, and `hand_checks.py`. Those author-owned
items are explicitly excluded from this report's claim of independent review.
The circuit, relay footprint, placement/routing, shared control interface, and
native board objects were inspected independently. Other assigned reviewers
cover the author-owned implementation. The earlier incorrect USB-B part
selection is resolved in the current design; it is not an open finding here.

## Layer Separation

Violations found: 0.

- `circuit.py` selects the actual circuit variant and emits electrical data;
  `hand_circuit.py` contains the distinct relay carrier. Both use manufacturer
  pin numbers, native symbol types, and explicit unused contacts.
- `schematic.py` preserves those electrical definitions in functional native
  sheets. It does not replace them with generic passive symbols to suppress ERC.
- `pcb.py`, `hand_layout.py`, and `route_critical.py` own placement and critical
  copper. The remaining routing exchange, finishing, and cleanup are separate
  steps. The hand variant contains no vestigial ADuM/crystal/TPS25221 assembly.
- `check.py` observes source/netlist/native schematic/board parity and validates
  the console interface. `export.py` consumes validated native artifacts and
  publishes a complete package with source/output hashes. The output package
  does not claim physical acceptance.

No dependency on application UI/state packages was introduced. SKiDL remains
pinned in the hardware requirements; the existing netlist parser is reused.

## Electrical State Assessment

### Shared control and source separation

The console native PCB has exactly two `PI_GPIO17` pads: J2 physical pin 11
and J25 pin 1. J25 pin 2 is ground. Both screen variants use matching J2 pin
1/2, a 1 kΩ series resistor and a 10 kΩ default-low enable pull-down. Neither
screen board contains a 40-pin ribbon connector. The Pi-to-console ribbon is
unchanged, and Pi supply pins are not repurposed as AUX.

The common NPN inverter enables rail discharge when display enable is low.
The Type-C source controllers use the same enable signal. The hand guide
requires a separate 100 kΩ pull-down physically retained on each external
EVM, so removing the control harness cannot leave an EVM enable floating.
This software-independent default-off wiring does not implement early shutdown
software; the README correctly leaves that integration explicit.

### Through-hole carrier

An independent native-board scan found 56 footprints, 167 plated through-hole
pads, four non-plated mounting pads, and zero surface-mount pads. The two TI
source EVMs are external assembled modules, with no fabricated carrier socket
or invented mounting footprint.

For each channel, the RF relay positive coil contact is supplied only by its
own host VBUS. The host native net contains the USB-B contact, local 100 nF
capacitor, flyback cathode, and RF coil positive terminal. No AUX or panel rail
shares that net. The separate 2N7000 and IRLZ44NPBF low-side drains keep the
host and AUX coil supplies apart. Both flyback cathodes face the appropriate
supply. The 2N3906 driver uses its correct emitter/base/collector numbering;
its released attachment input and gate pull-downs define the off state.

The current 100 kΩ attachment pull-up and 5.6 kΩ base resistor avoid the
previous excessive `/UFP` sink demand. The recorded conservative calculation
is below 1 mA. The MOSFET selections are assessed at relevant gate voltages,
not only their threshold voltages. No alternative power-source connection
through a shared coil return was found.

G6K-2P-RF coil pins 1/8 and NO data paths 3–4 and 6–5 match the manufacturer's
terminal diagram. The local footprint correctly mirrors its bottom view into
KiCad top-view coordinates, with 2.54 mm contact pitch, 5.08 mm row spacing,
four grounded shield leads, and 0.85 mm drills. NC pins 2/7 are unused.
[Omron RF relay data sheet](https://omronfs.omron.com/en_US/ecb/products/pdf/en-g6k_2f_rf.pdf).

G5LE-1 uses common pin 1 for touch power, fused AUX on NO pin 3, and the 100 Ω
discharge path on NC pin 4; coil pins are 2/5. This is the SPDT part, not the
NO-only variant. Placing the cartridge before NO preserves discharge when
the cartridge is absent. The native PCB has both leads of each fuse clip
connected to the intended side. The two-clip quantity and separate removable
cartridges are explicit in the BOMs.
[Omron power relay data sheet](https://omronfs.omron.com/en_US/ecb/products/pdf/en-g5le.pdf).

The fuse is documented as overload protection, including its slow response
at twice rating, not as a 500 mA current limiter. The hand design does not
inherit the factory's electronic current-limit envelope. This distinction is
necessary because internal panel power connections can bypass branch
protection through the separate main feed; the documentation states that
remaining physical acceptance condition.

### Factory board

Both ADuM3165B upstream VBUS domains are supplied only by their own Pi USB
ports. Downstream VBUS2 and touch connector VBUS share the corresponding
TPS25221 output. Ground is intentionally common, so this is not a claim of
instrument-wide galvanic isolation. The isolator pin map includes all ground
contacts, the two local LDO bypass domains, the upstream crystal, and an
unused PGOOD output; there is no circular PGOOD-controlled supply dependency.

The factory `/UFP` pull-up, Schmitt inverter and limiter create a defined
attachment-controlled downstream domain. Disabling TPS25810 releases its
open-drain outputs, which disables the touch limiter. Native Type-C CC1/CC2,
REF/REF_RTN, AUX inputs, output contacts, and thermal ground pad agree with
the selected TPS25810 package. The 80.6 kΩ limiter setting accommodates the
specified touch allowance plus downstream isolator consumption. Per-port
ESD supply contacts return to their respective local VBUS domains.
[TI TPS25810 data sheet](https://www.ti.com/lit/ds/symlink/tps25810.pdf),
[TI TPS25221 data sheet](https://www.ti.com/lit/ds/symlink/tps25221.pdf),
[ADI ADuM3165/3166 data sheet](https://www.analog.com/media/en/technical-documentation/data-sheets/adum3165-adum3166.pdf).

## Dependency Direction and Artifact Boundaries

Direction violations found: 0.

Circuit data flows to the schematic/netlist/BOM and then to the board pipeline.
Checks compare the native schematic export with the generated electrical data
and physical pads; they do not use rendering as connectivity proof. Variant
checks run in separate processes to avoid KiCad wrapper state leaking between
boards. Manufacturing export checks fresh inputs, builds in a temporary
directory, and verifies the input hashes again before replacing a package.
Cleanup removes only qualified redundant/dangling router tails and requires
clean final DRC before continuing. No source mutation was made during review.

## Validation and Limits

The reviewed routed boards have zero reported native DRC/ERC violations and
zero unconnected items. Their native footprints and critical pin memberships
were read independently rather than inferred from the CAD-ready flag. The
validation record identifies hardware qualification as not performed.

The README and current plan distinguish native CAD validation from relay USB
signal integrity, oscillator startup, enclosure fit, panel inrush, fuse/fault
behavior, contact life, runtime suspend/resume, HDMI residual power, and
shutdown timing. In particular, the approximately 21 mA host-powered relay
coil is not presented as a generic USB suspend-compliant design. No claim that
both touch controllers operate only at full speed, or that 1 GHz relay RF
data proves 480 Mbit/s USB compliance, was found. The physical acceptance
matrix and `autonomy:blocked-verify` remain appropriate; they are not new
findings introduced by this review.

### Final validation binding

The final combined `check.py all --self-test` completed successfully at
`2026-09-22T02:32:45.191449+00:00`. Both variants report CAD-ready, zero
errors, zero DRC/ERC findings or unconnected items, and all required injected
faults detected. Every source fingerprint in both validation records was
recomputed and matched the current file, including the final source cleanup.
The validation file's own SHA-256 is included below. This is observed CAD
validation evidence; it does not expand the independent-review scope or the
physical qualification claim. Fabrication export follows this check and is
not treated as completed by this report.

## Package Structure

The screen-power directory has a bounded hardware responsibility, both native
variant projects, project-local symbol/footprint libraries, exact-part BOMs,
assembly and cable instructions, a pinned circuit-generation dependency,
reproducible build stages, checks, and prototype exports. There is no additional
application package, deployment service, or compatibility path.

## Verdict

No verified actionable architectural finding remains in the reviewed design.
Critical: 0. Important: 0. Suggestion: 0. This verdict concerns the recorded
source/native-board revision and does not approve manufacturing or physical
behavior before the documented bench gates.

## Reviewed Revision Fingerprints

SHA-256 values below identify the actual files read, not a historical branch
head. Paths are repository-relative.

| File | SHA-256 |
| --- | --- |
| `hardware/kicad/screen_power/hand_circuit.py` | `7bd76765d3f9dbbf1710068330dcc0946a7fae0c8c3f1381e82d7d2a319b71e6` |
| `hardware/kicad/screen_power/circuit.py` | `bb71e31c515d9a5321870b7772169f9069f94d811099d2f4470eccf48916a627` |
| `hardware/kicad/screen_power/hand_layout.py` | `d1b241a5ade4c3f3d367b091d642b671e7b3e01e3841c02a2231c005ad8052e1` |
| `hardware/kicad/screen_power/pcb.py` | `369f6083485dff8439ceb4f454cbf6c1d44be3bb069c8f63e50d98db1fa8dbeb` |
| `hardware/kicad/screen_power/schematic.py` | `6087ef98670b9e1973780487f2b2db58e119f3eb5b1f3a78324c748371f8dbb2` |
| `hardware/kicad/screen_power/screen_power.pretty/Relay_DPDT_Omron_G6K-2P-RF.kicad_mod` | `a2b1ca3c65b615a56df4f3685cb875aa624fc489b4a8d5ea80985bbde95e4b04` |
| `hardware/kicad/screen_power/hand/screen_power_hand.kicad_pcb` | `0362adac5630fb1871472aeded0f62d113e94ccb73a770ef520a6ec007d757b3` |
| `hardware/kicad/screen_power/factory/screen_power_factory.kicad_pcb` | `d047ab2bc52f89caec3ef808c306aa1cff9b533ac3ffef7bfe16c130e9def464` |
| `hardware/kicad/console_board.py` | `634cbd1f208048877865ebeb4334b45b3f20ef4b5f78e8731a02364f5ae1cb32` |
| `hardware/kicad/console_board_pcb.py` | `f84369b302d678dd2c312b1ad541cb88bf1acdc4f609dd6f16afcaf3f4512cad` |
| `hardware/kicad/out_console/segno_console_board.kicad_pcb` | `d4a735337159ee083228dbfa23bc4f16c329b2a44fe26847d5a04fc99004b360` |
| `hardware/kicad/screen_power/README.md` | `30cc8ec91021bc2db2852be8fe0338936ee9fec472d5e01110c095a19b55ecd7` |
| `hardware/kicad/screen_power/external_bom.csv` | `c38bc9b1ae8bba54bd35bf862ce650102c573e509254215f6a74a80c58019f55` |
| `docs/plan/2026-09-21-feat-screen-power-board-plan.md` | `bc872393b92cde22dffddbb0f3c050a289a1b19c5e071dcea6579f98555e47d8` |
| `hardware/kicad/screen_power/validation.json` | `e9b0379a4e0c95dbdfe4844859b1275b59ec646916835a9436c0175806f9d9d0` |
