<!-- cspell:words Ciss IRLZ Infineon Littelfuse Littelfuse's NPBF Omron Schurter backfeed derating flybacks onsemi overcurrent unswitched -->
# Independent review: G6C screen-power relay proposal

**Proposal history:** the relay and four Bel branch fuses below remain selected. The later soldered Bel input-fuse proposal and its voltage margins are superseded by Schurter SPT 0001.2513 in OGN 0031.8201; use [the current holder/coil assessment](holder-coil-budget.md) for all input-loss and pickup numbers.

27 September 2026. Read-only review of baseline hardware 9f01b495 and the two private relay proposals. No schematic, PCB, cart or repository files changed. This is an implementation-ready proposal verdict, not approval of a manufacturing package that has not yet been generated.

## Decision

Proceed with **G6C-1117P-US DC5 + IRLZ44NPBF + P6KE6.8CA**, retain Q1/Q2 and all four existing USB TN0702 switches, change **R7 to 10 kΩ**, and replace the four output fuses with the **Bel 0697H family: 4 A main and 800 mA touch**. Procurement must confirm the exact stocked suffix; the proposed touch line is 0697H0800-02. Keep the 3 A main-lead and 500 mA touch-lead operating allocations, purchased XH interfaces, existing separate main-power leads, common ground and 100 Ω/1 W output bleeder.

The original 4 A/750 mA very-fast fuses should not simply be carried over with a claim that the entire 10 mF sensitivity is proved. Their nominal pulse limits are too low for some plausible hard-contact startup cases. The proposed time-lag family resolves that design concern with much greater pulse margin and lower normal resistance. Its longer clearing time is a deliberate tradeoff, discussed below. This does not make contact welding impossible or create active inrush control.

There is no remaining reason identified here to add another active power stage before implementing this proposal. Remaining work is the finite implementation verification below, plus keeping the capacitance, coil-temperature and cable assumptions explicit. Do not claim every possible external load or fault is guaranteed safe by these calculations.

## Circuit and control review

Wire the relay contact upstream of all four screen fuses. Coil positive goes to unswitched AUX, coil negative to IRLZ44N drain; source goes directly to ground, gate to the actual existing **DATA_ENABLE** net. The older proposal's USB_ENABLE name is descriptive, not the current net name. P6KE6.8CA connects directly across the coil. Never put the suppressor or a convenience resistor across the open power contact.

Q1's GPIO network remains R1=1 kΩ and R2=4.7 kΩ. This preserves the established weak-pull rejection. Q2 sources the gates, not coil current. The new R7=10 kΩ draws at most about 0.525 mA at 5.25 V; available Q2 base drive through 5.6 kΩ is about 0.6 mA at the low-supply corner. Removing the old optocoupler LED load helps Q1. Check resistor tolerances in the regenerated numerical guard, but no larger GPIO current or new buffer is justified.

The [Infineon primary datasheet](https://www.infineon.com/assets/row/public/documents/24/49/infineon-irlz44n-datasheet-en.pdf), pages 1–2, was visually inspected: 55 V drain rating, ±16 V gate limit, and maximum 35 mΩ at VGS=4 V. The existing conservative Q2 rail estimate is 4.75−0.4=4.35 V, above that specified test voltage. A doubled-hot 70 mΩ engineering estimate gives under 3.5 mV at 50 mA and less than 0.2 mW. No heatsink is needed for this coil-driver role.

The 48 nC maximum total gate charge is specified at 25 A, 44 V drain and 5 V gate, not this 50 mA coil operating point. It nonetheless supports using a firmer pull-down: 10 kΩ makes gate discharge and leakage sensitivity ten times lower than 100 kΩ. A conservative charge/removal-current comparison gives a sub-millisecond scale down toward 1 V, not a manufacturer-guaranteed exact release time. Typical Ciss is 1.7 nF; typical capacitance or threshold curves must not be represented as hard worst-case startup proofs. Retain short gate/source routing and a local R7 return. This is a conventional, adequately driven low-side coil switch.

At AUX startup and at coil turnoff, Miller charge can momentarily disturb DATA_ENABLE. R7=10 kΩ reduces its duration; the TVS keeps the drain excursion modest. A nanosecond gate excursion is not proof of relay pickup, and the maximum catalogue operate time is not a guaranteed minimum pulse rejection time. The implemented guard should cover static leakage and strong drive; any transient model should state its capacitance assumptions. No evidence found requires another transistor or gate capacitor here.

## Coil suppression and sequencing

The [Littelfuse P6KE datasheet](https://www.littelfuse.com/~/media/electronics/datasheets/tvs_diodes/littelfuse_tvs_diode_p6ke_datasheet.pdf.pdf) specifies the selected **CA bidirectional** part at 5.8 V stand-off, 6.45–7.14 V breakdown at 10 mA and 10.5 V maximum clamp at its stated large pulse. The low-voltage bidirectional leakage allowance doubles to 2 mA at stand-off. At the normal 5.25 V maximum rail it is below stand-off; include leakage in the coil-driver current allowance. At turnoff the nominal maximum drain estimate is 5.25+10.5=15.75 V, far below 55 V. Even a large temperature/overshoot sensitivity leaves substantial margin; do not turn the typical temperature coefficient into a guaranteed clamp curve. Place the TVS beside the coil and driver with a short loop. An unspecified coil inductance prevents claiming an exact pulse energy or exact release time, but current is only approximately 47 mA.

The USB coils keep their ordinary flybacks. The proposed **onsemi 1N4007G** is suitable for this occasional DC relay use; band/cathode must remain at AUX. Its [primary datasheet](https://www.onsemi.com/pdf/datasheet/1n4001-d.pdf) identifies the axial package and 1 A rectifier family. No high-frequency rectifier function exists here. The three proposed 100 nF X7R/50 V/5 mm-pitch bypasses are electrically suitable at 5 V; final exact MPN body envelope and lead fit still need checking.

The power relay and data relays receive the same logical enable but have different mechanical operate/release times and suppression. Therefore do not promise strict power-before-data or data-before-power contact ordering. Brief millisecond transitions are expected. Both data pairs eventually open with GPIO off, so no sustained data-line back-power path remains. Existing software/USB enumeration behavior should be retained; there is no new firmware feature implied by the circuit change.

## Default off and reverse-source states

With GPIO low or floating, Q1/Q2 are off and R7 discharges all lower-driver gates. Main and USB coils de-energize. With a host absent, its upper USB TN stays off independently. Existing USB body-diode/bypass fault checks must remain. Host VBUS continues to sense presence only; neither host VBUS nor a USB data contact becomes a screen-power source by design.

With AUX absent from a cold start and a panel output externally powered, the NO power contact is open; there is no drain body diode across the contact, and no output-to-AUX path through the coil suppressor. With GPIO off, opening the relay also blocks reverse current after its finite release interval. However, while the relay is deliberately enabled its contact is bidirectional. If an external source powers SWITCHED_5V while the contact is already closed and GPIO remains high, that source can backfeed AUX and keep the coil energized after the normal AUX feed is removed. Do not claim isolation while enabled or unconditional source-loss detection. This is outside the specified assembly, where both screen USB power inputs come from this board and the confirmed HDMI connection does not sustain a lit screen. The required Pi-off/GPIO-off state remains correct.

A welded power contact is a possible default-on component fault, analogous to a shorted pass transistor. Neither the fuse nor the bleeder guarantees clearing it. Preserve the earlier acceptance report's bounded capacitive-load assumption; no AC tungsten approval should be relabelled a guaranteed DC-capacitor pulse rating.

## Relay mechanical and thermal envelope

The [Omron G6C primary drawing](https://omronfs.omron.com/en_US/ecb/products/pdf/en-g6c.pdf), dimension page 7, was visually inspected. Exact straight-pin flux-protected 1a model: **pin 8 coil positive; pin 1 coil negative; contact pins 3 and 4 normally open**. In its bottom-view diagram, coil pin 8 is 10.16 mm below pin 1; contact pin 3 is 10.16 mm right of pin 1 and pin 4 another 7.62 mm right. Four recommended holes are 1.1 mm; body maximum is 20×15×10 mm. Convert bottom view correctly into KiCad top-view coordinates. G6C-2117P is 1NO+1NC, not two NO contacts; do not substitute it to implement the unverified two-pole proposal.

At 4.25 A, initial 30 mΩ maximum gives 127.5 mV and 0.542 W; add approximately 0.2 W coil heat. The following original 50 mV coil-feed calculation predates the added input fuse and is superseded by the 105 mV budget in input-fuse-assessment.md. The original calculation kept a 50 mV maximum driver-plus-local-coil-wiring loss allowance. At 4.75 V input that leaves 4.70 V coil voltage. The documented 100°C winding sensitivity, using 0.4%/°C copper correction from 23°C, gives 4.578 V pickup and 122 mV margin. This is a 40°C rise allowance over 60°C local air, not an exact-part coil-rise guarantee. Keep the relay away from buck/Pi heat and allow air space; preserve this explicit thermal assumption in the new review.

## Fuse adjudication and calculations

[Littelfuse 251 primary data](https://www.littelfuse.com/assetdocs/littelfuse-fuse-251-253-datasheet?assetguid=f47a0bb7-8ede-4679-9646-7114c3787688): existing 4 A has nominal 0.0204 Ω and 2.45 A²s; existing 750 mA has nominal 0.175 Ω and 0.153 A²s. These are not guaranteed minimum resistances or minimum melting integrals. A 180 µF local touch capacitor (+20% on 150 µF), 5.25 V and nominal touch fuse resistance gives 0.0142 A²s, only 9.3% of its nominal melt value. The known local capacitor alone is not a persuasive nuisance-blow finding. The unknown screen capacitance is the material difference.

For an ideal step into a capacitor, I²t=CV²/(2R). At 10 mF and 5.25 V with only nominal old main-fuse resistance, the sensitivity is 6.76 A²s, above 2.45. Adding contact/cable/source resistance lowers this, but a maximum contact resistance cannot be used as a minimum peak-current limiter.

If main and touch screen inputs join internally, let Rm and Rt be their branch resistances and Rs the common source/return resistance. Let Rp=RmRt/(Rm+Rt). Total charging I²t=CV²/[2(Rs+Rp)]; touch fraction squared is [Rm/(Rm+Rt)]². Example Rs=0, Rm=0.05 Ω, Rt=0.175 Ω, C=10 mF gives 0.175 A²s in the old touch fuse, above its nominal melt value. Thus “both cables are connected” reduces the risk but is not itself a proof. Touch-only operation of the large screen is not a required supported condition.

The [Bel Nov2025 0697H primary datasheet](https://www.belfuse.com/media/datasheets/products/circuit-protection/ds-cp-0697h-series.pdf) gives:

| Proposed rating | Typical cold R | Nominal I²t <10 ms | Nominal I²t at 10×In |
|---|---:|---:|---:|
| 4 A | 0.016 Ω | 81 A²s | 92 A²s |
| 800 mA | 0.130 Ω | 2.3 A²s | 3.1 A²s |

Using only the typical 4 A fuse resistance gives 8.61 A²s at 10 mF/5.25 V, 10.6% of its nominal 81 A²s. Halving that resistance as a sensitivity gives 21.3%; it does not invent a guaranteed minimum. For the joined-rail example Rs=0, Rm=0.05 Ω, Rt=0.13 Ω, the touch contribution is 0.2945 A²s. The local 180 µF contribution is 0.0191 A²s. Do not simply sum overlapping pulse integrals: the conservative Cauchy bound is (sqrt(0.2945)+sqrt(0.0191))²=0.4635 A²s, about 20.2% of 2.3. The real 25/30 cm 28 AWG positive lead adds resistance, reducing the shared-screen contribution. These sensitivities support the practical selection without claiming arbitrary zero-impedance or unbounded-capacitance performance.

[Littelfuse's pulse guidance](https://m.littelfuse.com/~/media/electronics/product_catalogs/littelfuse_fuseology_selection_guide.pdf%20.pdf) uses about 22% nominal melting I²t for 100,000 pulses with cooling between events. It is useful engineering context, not a Bel lifetime guarantee or a statement that contact bounce creates fully independent, cooled pulses. Nor may nominal melting I²t be called guaranteed total clearing I²t.

The selected Bel series specifies up to 60 s at twice rated current. For an 800 mA touch fuse, a sustained 1.6 A partial fault therefore has a longer allowed clearing interval than the old fast fuse. Typical 28 AWG resistance of 0.213 Ω/m makes a 30 cm positive/return pair dissipate about 0.327 W at 1.6 A. That is distributed cable heating, not a proof of conductor temperature. Local 60°C air, jacket insulation rating, bundling and contact quality matter. Maintain short leads, intact ground returns, no tightly insulated bundles beside heat sources, and the 500 mA normal allocation. No arbitrary maximum insulation temperature is assumed or certified here. For a high-current short, the nominal 3.1 A²s at 10×In corresponds to roughly 2.4°C adiabatic heating in 28 AWG copper; total clearing can exceed nominal melting energy. The subsequent PCB-input-fuse decision below supersedes the earlier upstream 7.5 A input-harness fuse; see input-fuse-assessment.md for the final selected input protection. These fuses protect gross faults; neither old nor new parts actively impose the normal operating-current allocations.

Mechanical evidence supplied independently by the ring reviewer from Bel page 4: body 8.35±0.30 ×4±0.30 ×7.8±0.3 mm; pitch 5.08±0.1 mm; leads Ø0.6±0.1 mm. -01 short leads are 4.3±0.3 mm; -02 is the same body/pin geometry with longer ammo-pack leads to trim. Use a verified/custom rectangular radial footprint; this is not a drop-in axial-footprint substitution. Root must confirm the stocked suffix and quote before freezing the BOM.

## Exact implementation validation

1. Regenerate the circuit, netlist and BOM; remove the complete obsolete pump/opto/pass-FET circuit and its tests. Verify pin-by-pin NO contact, coil polarity, IRLZ44N G-D-S/tab, bidirectional TVS, Bel radial footprint and the exact three bypass capacitors.
2. Update numerical guards for R7=10 kΩ, aggregate off-state leakage, Q1 weak-pull and strong-high behavior, Q2 base/current margin, gate voltage, coil cold current/hot pickup and clamp voltage. Remove obsolete gate/SOA claims rather than leave misleading compatibility paths.
3. Preserve USB host-presence AND truth tables, source isolation, connector pin maps, fuse downstream ownership and body-diode fault mutations. Include low/floating GPIO, either host absent, AUX absent cold start, charged outputs and normal shutdown. Describe the deliberate-enable reverse-source limitation accurately.
4. Record main/touch capacitive pulse sensitivities, normal voltage drops, fuse clearing tradeoff and the 60°C air/100°C winding assumption. No new pre-PCB prototype campaign is required by this review.
5. Claude performs placement/routing. Check two-layer geometry, short coil/TVS return loop, gate away from contact/current loops, preserved USB pair/ground geometry, safe hand-solder clearances and relay/fuse/enclosure fit. Run relevant KiCad ERC/DRC, circuit/self/fault checks, USB geometry/reference checks and fabrication checks; independently review the resulting exact revision.
6. Only after that review, refresh source-derived manufacturing ZIPs, manifests, models/previews, BOM/shopping quantities and a new delivery snapshot. This proposal does not invalidate the old delivery's identity; it supersedes its design only after a new reviewed release exists.

## Subsequent input-fuse placement question

The inline holder is an implementation choice, not an electrical requirement. The current 7.5 A fuse near the buck covers both the incoming screen lead and the board before its four branch fuses. Moving protection to the board can remove that holder and its cost, but changes the protected boundary: a board input fuse cannot clear a short in its own incoming cable.

The exact retained supply in the repository is eleUniverse B0GGHN97TK, 8–36 V to 5 V/10 A IP67. Its listing advertises overcurrent, short-circuit and thermal protection without published thresholds or response curves. The 20 V T5A input fuse also does not establish a specific clearing bound for 5 V output faults. Do not delete all input protection by treating either marking as an active 10 A output limiter.

A practical alternative during this redesign is a PCB-mounted **8 A Bel 0697H8000** immediately after J1 and before the input capacitors, relay contact feed, coil/control and USB-relay feeds. Keep the pre-fuse copper extremely short and use a short 16 AWG incoming pair, insulated, secured and separated from chassis edges; retain the existing upstream 20 V fuse. A 6.3 A part is unnecessarily close to the approximately 4.4 A total screen/control allowance after normal 75% loading and hot derating. Exact 8 A stock and the manufacturer's temperature curve need confirming; this is a candidate, not a silent BOM change.

The Bel 8 A row gives typical 7 mΩ and nominal 273 A²s below 10 ms. At 4.4 A its typical added drop is about 31 mV. Include it in the total coil-feed budget: the earlier 50 mV budget must cover this fuse, driver and PCB, or the documented 4.75 V minimum must move to the fused AUX node. Do not retain the prior 122 mV hot-pickup margin while spending additional voltage ahead of the coil. Maximum fuse voltage drop at rated 8 A is 80 mV; the 4.4 A drop cannot be guaranteed from typical cold resistance. The low-loss IRLZ driver still requires the revised numerical sensitivity. This candidate is superseded by the selected Schurter assembly above.

The design can therefore avoid an inline holder without removing the board's supplementary protection. It must acknowledge that protection of the short incoming lead then relies on its construction and the supply system, not on the downstream fuse.
