<!-- cspell:words microamps onsemi Ibase Icollector ECEA Littelfuse rerating derating Ciss -->
# Independent adjudication: resumed Claude screen review

2026-09-27. Read-only audit against hardware `a1ff9d6d491c09f6e7f3c8b818440eb5c0493b7e`. This is a targeted adjudication of the resumed report, not a new claim that every PCB track or all fabrication exports were re-reviewed. No repository file, Git state or device was changed.

## Result and concrete delta

Adopt **R2 = 4.7 kΩ, 1%** as inexpensive same-footprint control-input hardening. Preserve R1 = 1 kΩ and the existing GPIO owner/shutdown behavior. Add a numerical weak-source/off-bias guard and regression mutation; preserve the existing forced-beta-10 strong-drive check. This closes a useful robustness gap, but Claude's claim that the current circuit is proven to leave a Pi 5 screen on at halt is too strong and cites the wrong processor's pull specification.

Update source, generated values/BOM/native value and schema/assembly records; compare copper/drill/net topology before and after. This value change does not require rerouting. Refresh whatever manufacturing inputs/manifests include the changed native files even if copper CAM is byte-identical. No capacitor, fuse, optocoupler or relay substitution is justified by the claimed missing evidence.

## R2: confirmed weakness, corrected rationale

The actual circuit is GPIO17 → R1 → Q1 base with R2 to GND. AUX feeds Q1 collector through the optocoupler/R9/R10 and Q2 buffer networks. An undriven wire is not an internally pulled-up GPIO; an actively high output is a third condition. The existing README already distinguishes shutdown from electrical power loss and prohibits leaving a pull-up enabled. The ideal 24-state USB model does not derive Q1's analog input transfer and must not be called an analog proof of weak-pull rejection.

Pi 5's header GPIOs belong to **RP1**, not BCM2711/BCM2835. [RP1 §3.1.3](https://datasheets.raspberrypi.com/rp1/rp1-peripherals.pdf) documents optional pull-up/down and 2/4/8/12 mA drive selections, but supplies no numerical pull-resistance min/max in this document. The [Raspberry Pi GPIO electrical table](https://www.raspberrypi.com/documentation/computers/raspberry-pi.html) explicitly scopes the familiar 50–65 kΩ table to older BCM2835/2836/2837/RP3A0 products. Do not turn that into a guaranteed RP1 bound.

Claude's 2.19 V number for the old 100 kΩ is an **unloaded divider** result; an actual Q1 base forward junction clamps the node. The result still correctly warns that tens of microamps of base drive can enable Q1/opto, but does not establish Q1 saturation or a particular boot/halt state. No resistor can reject an actively driven 3.3 V HIGH while also treating that same HIGH as the intended enable.

For an explicitly labeled engineering weak-source envelope of **up to 3.63 V through at least 50 kΩ**, using R1 minimum 990 Ω and R2 maximum 4747 Ω:

- Unloaded base upper bound: `3.63 × 4747 / (50000 + 990 + 4747) = 0.309159 V`.
- Including an additional 1 µA injected base-node current through the complete Thevenin resistance: **0.313502 V**.
- Fully disconnected input with 1 µA injected current: **4.747 mV**.
- A **0.35 V off-bias budget** is an engineering allowance, not a transistor manufacturer's guaranteed cutoff threshold or an EMC qualification.

The [onsemi 2N3904/D datasheet](https://www.onsemi.com/pdf/datasheet/2n3904-d.pdf), visually read at Figure 4, places even its **125 °C typical** 0.1 mA collector-current point near 0.39 V base bias; at the project's 60 °C local-air condition the typical required bias is appreciably higher. This supports useful margin at the calculated 0.314 V. It is not a guaranteed maximum hot collector current at positive VBE. No physical failure is demonstrated that requires changing to 2.2 kΩ; that alternative would reduce the same weak-source result to 0.154 V while preserving ~0.999 mA base drive, but would add another resistor value without closing the missing guaranteed RP1 pull specification.

Use the existing source guard's conservative strong-drive model, not Claude's reliance on forward-active hFE to promise saturation:

`Ibase_min = (2.4 − 0.95)/(1000 × 1.01) − 0.95/(4700 × 0.99) = 1.231474 mA`.

`Icollector_bound = 5.25/(2400 × 0.99) + 5.25/(5600 × 0.99) = 3.156566 mA`.

Forced beta is **2.563**, well inside the existing beta ≤10 criterion. The datasheet's saturation tests use forced beta 10; 0.95 V is already a conservative base-drop allowance relative to its 10 mA test. Keep the assumed 2.4 V minimum GPIO HIGH labeled as an input design condition rather than an RP1 guarantee invented from drive-strength settings.

Suggested guard behavior: calculate the weak-source + 1 µA value and require ≤0.35 V, calculate the floating value, retain topology checks and the existing HIGH-drive check. Mutation tests should prove the former 100 kΩ fails weak-source rejection and an excessively small R2 fails base-drive margin. Keep 1% tolerance parsing exact. This is more meaningful than a lone `R2 <= 10k`: 10 kΩ would approach 0.592 V under the stated 3.63 V source envelope and is not equivalent to the proposed fix.

## Hot relay pickup: existing supported envelope, no new pre-order test

Claude's calculation is a conservative approximation, but the current repository already contains a more relevant combined self-heating/temperature calculation in `docs/reviews/screen-power-usb-revision-1072/circuit-assessment.md` and the prior screen review. It starts with 60 °C local air, a 130.5 Ω minimum room-temperature winding, 5.25 V preheating, 150 K/W and copper's temperature coefficient. It obtains 85.44 °C winding, 162.52 Ω hot resistance, **4.4747 V available** at 4.75 V J1 through 10 Ω of drivers versus **4.2094 V estimated pickup**, giving **0.265 V margin**. This is explicitly an engineering model, not a tested hot specification. [TE primary family data](https://www.te.com/commerce/DocumentDelivery/DDEController?Action=srchrtrv&DocFormat=pdf&DocLang=English&DocNm=108-98001&DocType=Data+Sheet&PartCntxt=1-1462037-3).

The documented 4.5 V corner is only a MOSFET gate-drive assessment. The wiring table already requires at least 4.75 V **at J1** for normal operation and says not to assume the buck is adjustable. Thus Claude's proposed voltage measurement/trim is an assembled acceptance consideration, not a newly discovered PCB defect or reason to demand another pre-PCB campaign. Do not promise an 85 °C ambient hot-restart capability; the existing calculation expressly excludes it.

## Missing primary evidence closed

- **Panasonic:** [exact ECEA1EN100U page](https://industrial.panasonic.com/ww/products/pt/aluminum-cap-lead/models/ECEA1EN100U) explicitly identifies bipolar polarity, 10 µF, 25 V, 5.0 × 11.0 mm body and 2.0 mm lead pitch, 10.5 µA leakage and −40…85 °C category. [Its linked primary SU catalog](https://industrial.panasonic.com/cdbs/www-data/pdf/RDF0000/ABA0000C1053.pdf) is accessible. The unpolarized symbol/model and footprint agree; there is no orientation defect.
- **Littelfuse:** [current 251 PDF, revision GK 08/18/26](https://www.littelfuse.com/assetdocs/fuse-251-datasheet?assetguid=f47a0bb7-8ede-4679-9646-7114c3787688) was accessible through web retrieval despite direct-download 403. Its item table gives nominal melting I²t **2.45 A²s for 4 A** and **0.153 A²s for 750 mA**, and calls for temperature rerating **in addition to 25% continuous derating**. The standard ≤4 A axial drawing gives 7.11 mm body length, 2.80 mm maximum diameter and 0.64 mm wire; the 5–15 A drawing's 3.18 mm body does not apply to these fitted values. Those dimensions match the custom 12.7 mm formed-lead footprint with 1.0 mm holes. Soldering is 350 ±5 °C for ≤5 s. Neither a 3 A cable ceiling nor the fuse's nameplate is a universal continuous hot-load guarantee. This adjudication does not re-extract a numerical point from the temperature-rerating graph.
- **Toshiba:** [manufacturer orderable table](https://toshiba.semicon-storage.com/us/semiconductor/product/isolators-solid-state-relays/detail.TLP627M.html) explicitly lists **`TLP627M(E`**. Its unmatched parenthesis is valid manufacturer notation. Do not “repair” the BOM into an invented part code.
- **TE:** [exact 1-1462037-3 product page](https://www.te.com/en/product-1-1462037-3.html) identifies IM02TS and says the product is not currently available, pointing customers to distributor inventory/contact. That proves a present direct-procurement limitation, not discontinuance or a pinout/electrical defect. No unsourced replacement or board change is appropriate. Stock must be confirmed at purchasing; no broad shopping search was performed.

## Startup arguments that must not enter the clean-review evidence

Claude's claim that `R3 || R4 × Ciss` establishes ~100 µs switching is unsound: there are **two** MOSFET gates, nonlinear capacitance/Miller charge, an optocoupler and a negative-rail startup sequence. Typical 7000 pF at −50 V is not a complete timing model. The existing `startup.md` correctly uses both devices' gate charge and labels ~1–2 ms as an estimate, with slower startup sensitivities and no active current limiter.

The [Vishay SUP70101EL primary data](https://www.vishay.com/docs/77632/sup70101el.pdf) distinguishes **281 mJ avalanche energy** from forward-bias linear SOA and places the **375 W** rating at case 25 °C. Comparing capacitor energy to those headline ratings does not prove safe startup without a heatsink. `½CV²` describes the ideal capacitor-charging loss under specific charging assumptions, not all semiconductor energy with a concurrent operating load. Existing startup documentation separately includes the operating load and SOA/transient-thermal bounds and is the appropriate evidence.

Finally, `20² × 200 µs = 0.08 A²s` is only an invented pulse example, not measured inrush. Its being below a nominal fuse melting I²t cannot prove that every startup pulse leaves the fuse intact, especially for the 750 mA touch branches or repeat/hot pulses. The repository already says the buck is not an instantaneous 10 A clamp and the fuses are not current limiters. Retain those precise limitations.

## Independent review of the implemented R2 delta

Reviewed the resulting ten-file working diff after the above recommendation. **No actionable finding in this delta; scoped review complete.** This does not replace the full native/CAM verification or whole-PR gate.

Executed the actual updated `numerical_checks` with KiCad Python against the regenerated netlist: baseline errors = 0, weak-source result **0.313501974 V**, base drive **1.231474211 mA**, collector bound **3.156565657 mA**. Independently mutated R2 back to 100 kΩ and obtained specifically `gpio_weak_pull`; mutated it to 22 Ω and obtained specifically `driver_margin`. Both new mutations are included in the required fault-control list. The source model, README and returned JSON clearly distinguish the assumed weak source from an RP1 guaranteed specification.

Compared both native boards line-by-line with HEAD: each differs on exactly one hidden F.Fab Value line. Loaded both in pcbnew and independently read R2 = `4.7k 1%`, pad 1 `CONTROL_BASE`, pad 2 `GND`. Thus this delta changes no copper, hole, placement, label, zone, mask or courtyard. Parsed old/new netlists: physical topology identical; R2 is the only changed parsed component. The schematic diff changes only R2 Value/MPN; source, component JSON and BOM agree on `MFR-25FBF52-4K7`. The cost table sums to 26 unique lines, 50 components and **$44.96** with its prices correctly retained as dated estimates.

Reviewed current input hashes:

- `check.py`: `e837b504b1038005a3fdfbc518f49d221d7efdbade3b719295c55bda23f7d1ac`
- `switch_circuit.py`: `9c663dd3df16003b28b63cdc7007b119f513a2786bb2c729c1601ed870aeec13`
- Routed native: `28959e56ab6ce29fb26532883fc9604daacedd37c85e59271ccd54fc5a53a36e`
- Placed native: `da3002fbf033e4b5ea0b1dbf4d1d78d76fb5cf67b16b0cc0c1ffe43f040ff834`

Only temporary adjudication files were written. The independent numeric/parity execution completed with exit 0; KiCad emitted its usual wx/image-handler initialization diagnostics, not a validation failure. Parent separately reports the fresh full native run passing all 77 controls with zero errors; that full run was not duplicated here.
