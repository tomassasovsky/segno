# Architecture Review — Screen power revision C

**Current result: no unresolved findings.** The initial TQ2 finding and follow-up export blocker are resolved; evidence is recorded at the end. Physical hardware qualification remains pending.

Initial review and subsequent correction review of the uncommitted `hardware/kicad/screen_power` changes against `a2a6a1f4` on 2026-09-22. This is the required build architecture role adapted to Python-generated KiCad hardware. The work remains prototype CAD; this review does not qualify a physical assembly or USB link.

## Layer separation

No software layer violations found. Circuit definition (`switch_circuit.py`, with library construction in `circuit.py`), placement (`layout.py` / `pcb.py`), critical routing (`route_critical.py`), finishing, validation, and export keep distinct responsibilities. The new model assignment logic belongs with board construction. Model coverage checking is a small shared validator used by checking and export; it does not import the generation or presentation stages.

The two variants still share one circuit description and differ at component/package selection. Revision C removes the obsolete RF footprint instead of retaining a fallback path. No Flutter architecture rules apply to these files.

## Circuit and interface assessment — initial TQ2 review history

### Resolved Important: Correct the TQ2 coil operating-envelope mismatch

Location: `hardware/kicad/screen_power/check.py:321`; associated interface documentation at `hardware/kicad/screen_power/README.md:87`.

Panasonic's TQ catalog ASCTB14E 202507, printed page 4, says to use the relay within ±5% of rated coil voltage because operating characteristics vary with temperature and mounting. The 5 V version therefore has a recommended 4.75–5.25 V coil envelope. Printed page 2 separately recommends the 4.5 V version for a 5 V transistor drive. The latter is not an automatic drop-in recommendation here: its upper coil-voltage envelope would also need analysis.

The current numeric check evaluates the selected 178 Ω ±10% coil with the 5.3 Ω driver maximum at a 4.75 V host input:

`4.75 × 160.2 / (160.2 + 5.3) = 4.597885 V`.

Both variants produce this value with no error. It is above the initial 20 °C pickup limit of 3.75 V, but below the manufacturer's recommended operating envelope. The initial pickup rating is not a substitute for the temperature/mounting condition. The README currently calls out USB suspend and generic brownout testing but does not identify this known coil-voltage shortfall or a minimum voltage at J101/J201. Cable drop and hot driver resistance are not included in this cold estimate.

Do not treat this known mismatch as resolved merely by adding a general qualification footnote. Select a relay with a supported operating range for the available drive, or revise the drive/supply requirements to meet the selected relay's range; then enforce the documented initial margin in validation and retain separate hot-restart verification. The parent is evaluating IM03TS as a concrete replacement; that correction and regenerated artifacts still need verification.

### Relay pinout and contact behavior

Verified against printed page 12's bottom-view schematic and recommended board pattern, including conversion to the footprint's top view:

- Coil: pin 1 positive, pin 10 negative.
- Common contacts: 3 and 8; normally open: 4 and 7.
- Normally closed: 2 and 9; unused physical terminals: 5 and 6.
- Ten physical holes, 2.54 mm pitch, 7.62 mm row spacing, 1.0 mm drilled holes.

The custom symbol, generator connection map, independent contract, and both native boards agree. K101/K201 each switch D− through 3→4 and D+ through 8→7. Pins 2/5/6/9 are unconnected. Host VBUS powers only its own coil and bypass path, and each flyback diode is reverse biased while the coil is energized. The change preserves release on loss of the relevant host supply. No pinout defect found.

### USB boundary

The README correctly distinguishes the two 12 Mbps touch controllers from the UPERFECT assembly's 480 Mbps upstream hub connection. The selected TQ2 is not justified merely from the HID devices' full-speed enumeration. Printed page 9 supplies typical PC-board-terminal insertion loss through 1 GHz; the README accurately describes this as prototype-selection evidence, not a USB differential guarantee. Actual cable/device operation, reconnect behavior and high-speed signal integrity remain explicit acceptance gates. No additional speculative redesign is requested by this review.

### Power and control boundaries

The change keeps GPIO17 plus ground on the console's two-pin connector. It does not restore the rejected 40-pin interposer or power the screens from GPIO. The shared back-to-back P-channel switch, source-referenced pull-up and isolating D1 preserve the documented off-state reverse-blocking topology. The output fuses do not replace upstream protection; documentation correctly preserves that boundary and calls out the case where a screen internally joins its touch and main supply inputs. Both directions conduct when enabled, which is correctly documented rather than presented as ideal-diode behavior.

The Q3/Q4 loss calculation is explicitly a 25 °C resistance calculation, not a temperature or 6 A assembly rating. Live TO-220 drain tabs, inrush, enclosed thermal behavior, residual HDMI power and shutdown timing are all retained as physical/integration acceptance items. No claim that CAD alone eliminates the blue shutdown screen was found.

## Dependency direction and package structure

No reverse or circular dependency introduced. `models.py` depends only on `pathlib`; board construction consumes bundled assets; validation consumes built artifacts; export consumes validation and package helpers. CadQuery is needed only to regenerate custom assembly geometry, not to open the native PCB or run the board generation pipeline.

The portable export copies the variant native files beside `models/` and `screen_power.pretty/`, preserving `${KIPRJMOD}/../models` and the custom footprint-table path. The embedded schematic symbol library remains inside the variant directory. Model provenance distinguishes original simplified geometry from copied KiCad library assets, and coverage checking explicitly does not claim to parse or validate STEP solids.

## Checks performed

- Inspected all changed Python modules relevant to circuit, model, routing and export boundaries and the new relay symbol/footprint.
- Read the manufacturer catalog locally and visually inspected printed pages 4, 9 and 12. The direct web fetch of the same manufacturer PDF returned an unsupported content type; the supplied PDF was used for the substantive check.
- Loaded both native boards with KiCad Python and ran `check_contract`, `check_pad_map`, `numerical_checks`, and `check_models` independently. Both returned no current programmed errors, 37 populated model assignments, and the 4.597885 V relay result above.
- Checked actual K101/K201 native pad nets in both variants against the manufacturer pinout.
- Did not repeat the parent's ongoing native DRC/export run and did not claim physical USB, thermal, cable-fit, or shutdown qualification.

## Initial verdict (superseded by the correction review below)

Software/CAD generation architecture and circuit pinout are coherent. One important operating-envelope mismatch should be corrected before publishing the revision C prototype's validation claims. Physical release remains blocked by the documented acceptance work.


## Follow-up: IM03TS replacement assessment (implementation pending)

The parent requested an independent check of TE/Axicom IM03TS, part 1-1462037-8. The [exact product page](https://www.te.com/en/product-1-1462037-8.html) identifies its standard 5 V monostable coil and supplies RF characteristics, including 0.33 dB insertion loss at 900 MHz. These are useful component evidence; they do not qualify a differential USB assembly.

The current [108-98001 data sheet](https://www.te.com/commerce/DocumentDelivery/DDEController?Action=srchrtrv&DocFormat=pdf&DocLang=English&DocNm=108-98001&DocType=Data+Sheet&PartCntxt=1-1462037-8) was downloaded directly from TE rather than relying on the older superseded local composite. Page 3 gives 178 Ω ±10%, 3.75 V initial pickup at 23 °C without pre-energization, and an explicit temperature operating-range curve. The curve approaches about 4.65 V pickup at 85 °C, so 4.598 V cannot establish operation over the full part-temperature range. Initial margin and hot re-pickup must be assessed separately. Page 4 confirms top-view coil 1+/8−, commons 2/7, NC 3/6, and NO 4/5. Page 5 specifies at least 0.75 mm PCB holes.

The installed KiCad IM03 symbol and standard 5.08 mm-pitch footprint numbering match. However, its stock 0.70 mm drills are below TE's recommended minimum; enlarge them in a local footprint/controlled override before generation. The [TE customer drawing](https://www.te.com/commerce/DocumentDelivery/DDEController?Action=srchrtrv&DocFormat=pdf&DocLang=English&DocNm=1462037-4&DocType=Customer+Drawing&PartCntxt=1-1462037-8) independently confirms 5.08 mm row pitch and 3.2/2.2/2.2 mm successive terminal spacing. This is a more directly supported replacement candidate, with fewer custom symbol/model assets, subject to review of the actual implemented change.


## Correction review — IM03TS implementation

The original Important finding is resolved in the circuit implementation. `switch_circuit.py` now selects native `Relay:IM03`, value IM03TS and exact orderable MPN `1-1462037-8`; the custom TQ2 symbol generation is removed. The independent circuit contract matches the TE contact pinout, including leaving normally closed pins 3/6 unconnected. The selected local footprint preserves native geometry with all eight drills enlarged to 0.80 mm.

`numerical_checks` now enforces the IM03TS initial pickup threshold and reports a 0.847885 V calculated initial margin. The README limits that result to initial 23 °C operation and separately requires actual coil-voltage measurement and hot re-enabling at the minimum USB voltage and maximum intended enclosure temperature. This is a replacement with a supported component operating curve, rather than an attempt to waive the rejected TQ2 recommendation. The remaining physical acceptance requirements are not represented as passing CAD checks.

Independent follow-up verification loaded both newly generated netlists and both `.placed.kicad_pcb` boards. Circuit contracts, numeric checks, physical pad-map checks and model coverage checks returned no errors. Each board has 37 populated model assignments. Both K101/K201 footprints on both boards have eight 0.80 mm drills. At the time of this check, the routed `.kicad_pcb` deliverables were still the previous TQ2 generation; the parent is regenerating them and must finish fresh DRC/export checks before delivery. This architectural correction check does not claim those still-pending export checks have passed.

A separate package blocker was noticed during follow-up: adding the repository-root `LICENSE` to `export.inputs()` and then calling `relative_to(HERE)` on that path raises `ValueError`. The parent has been notified. It must be corrected before export can run; it is independent of the now-resolved relay-selection finding.


## Final artifact recheck and verdict

After the parent regenerated the routed IM03TS boards, I independently loaded both final `.kicad_pcb` files and repeated the circuit-contract, physical pad-map, numeric, USB-copper and model-coverage checks. Both variants returned no errors and 37 populated models. K101/K201 on each routed board have the correct IM03TS eight-pin net assignments and 0.80 mm holes. All four USB segments per board have physical continuity and pass the existing matched-pair checks; the two channels use the same routing lengths.

The export blocker is also resolved: the extra root license uses `os.path.relpath`, and independently executing the current export input-hash construction succeeds for both variants, including the `../../../LICENSE` key. The full fresh native DRC, negative self-tests and actual render/package export are separate parent verification work; this review does not substitute its targeted checks for those results.

No material architecture issue remains in the reviewed revision C implementation. One shared circuit, existing native relay symbols, a narrowly modified footprint, explicit control/supply boundaries, and portable model paths meet the project architecture. The prototype still requires the documented high-speed USB, thermal, inrush, hot-restart and shutdown acceptance work before production release.

### Reviewed artifact hashes

- `switch_circuit.py`: `566d0e2d9f44398c8d558bffa4647d5ca0c4cc399b2482963c7a4fb52145061b`
- `check.py`: `782f7be9063e32b7aa21482398c6d5a3b67b7d7c9a96632d939bb45bea8f5191`
- `export.py`: `bb9c58f14b24b4a3b73aedb6287b4dfe3f8f2dcc27126ef36e0ede416f43dc88`
- `hand/screen_power_hand.kicad_pcb`: `4e327ef929a607474a3a0d676648179c00adcd2a555a235be30936537104ec52`
- `factory/screen_power_factory.kicad_pcb`: `3c968094216f64f4f70c067b353a71592b4785437c8ff512487546c1b4ee8c22`
