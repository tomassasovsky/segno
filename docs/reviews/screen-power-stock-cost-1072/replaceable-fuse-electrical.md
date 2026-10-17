<!-- cspell:words Rwire Schurter derating undervoltage upsize -->
# Replaceable branch-fuse electrical assessment

> Historical all-five-replaceable option, superseded for cost. The selected design retains only the OGN main-input holder and uses soldered Bel 0697H output fuses. These Eaton/Keystone findings do not describe the current output parts.

27 September 2026. Electrical assessment of Eaton BK1/S506-4-R at F101/F201, Eaton BK/S506-800-R at F102/F202, and two Keystone 3521 clips per output fuse. Input protection remains Schurter SPT 0001.2513, 8 A, in OGN 0031.8201; its coil calculation is in holder-coil-budget.md. This assessment does not itself validate the routed PCB or release manufacturing files.

## Decision

The selected Eaton cartridges are a practical electrical replacement for the proposed soldered output fuses within the existing 5 V screen system. Their startup pulse sensitivities are favorable, and neither current rating needs to increase. Keep the 3 A main-lead and 500 mA touch-lead normal operating ceilings, the separate main-power connections, and the 4.25 A combined switched budget.

This is a bounded engineering acceptance, not a claim that every characteristic is guaranteed by the available data. Three limits must stay visible in implementation and release documentation:

1. The Eaton manufacturer's 32 VDC designation is self-certified; no numeric DC interrupt-current rating was found. Do not relabel its AC interrupt current as DC.
2. Fuse and clip working voltage allowances below are engineering budgets, not specified hot maximum resistances. The resulting full distribution stress calculation does not establish USB or screen minimum-voltage compliance.
3. These time-delay fuses protect against substantial overloads and shorts. They do not establish a guaranteed safe temperature for an unspecified 28 AWG USB cable during every prolonged partial fault. In particular, the 2.1× opening bound is 120 seconds, not the previous Bel 60 seconds at 2×.

No new prototype campaign is required by this assessment. Final routing, wiring and documents must reflect the actual selected parts and these bounds.

## Primary evidence

The current [Eaton technical data 4332, effective March 2026](https://www.eaton.com/content/dam/eaton/products/electronic-components/resources/data-sheet/eaton-s506-time-delay-glass-tube-fuses-data-sheet.pdf), page 2, gives:

| Cartridge | Typical cold resistance | Typical melting I²t | Published voltage-drop entry |
|---|---:|---:|---:|
| S506-4-R | 0.0139 Ω | 71.8 A²s | 67 mV |
| S506-800-R | 0.129 Ω | 2.78 A²s | 75 mV |

The column calls voltage drop typical, while its footnote calls it maximum at rated current and 20 °C. The 800 mA row's cold value already implies 103.2 mV at 0.8 A, exceeding the 75 mV entry. Treat this inconsistency explicitly; neither 75 mV nor an invented derived hot resistance is accepted as a guarantee. The current table supersedes the older PCN's different I²t figures. BK and BK1 change packaging, not these electrical ratings; the selected parts are cartridges without the -V axial-lead suffix.

[Eaton's manufacturer catalog, section 3-5](https://www.eaton.com/content/dam/eaton/products/electrical-circuit-protection/fuses/bussmann-series-catalogs/bus-ele-cat-1007-flc-2018-sec-03-elx.pdf) names both selected S506 ratings and gives 32 VDC, self-certified. The current individual data sheet gives only AC interruption figures. This supports 5.25 V use without pretending there is a separately established DC fault-current number. The buck's 10 A nameplate is not an instantaneous current clamp, and neither F1 nor the upstream fuse proves a particular peak or DC interruption limit.

[Keystone's 3521 product page](https://www.keyelco.com/product.cfm/For-2AG-5mm-Cylindrical-Fuses/Snap-In-PC-Fuse-Clips/product_id/359) specifies 15 A, through-hole brass/tin clips with end stops for 5 mm fuses. No numeric maximum contact resistance or 60 °C derating guarantee was found. Clip loss is therefore modeled, not quoted as a manufacturer limit. The mechanical review owns exact pair spacing, hole geometry and removal access.

## Continuous current and temperature

The March 2026 S506 sheet supplies a temperature correction curve and specifies operation from −40 to +125 °C with that correction. [Eaton's fuse FAQ](https://www.eaton.com/ca/en-gb/products/electronic-components/faq/fuse-frequently-asked-questions.html) distinguishes IEC 60127 continuous operation at rated current from the separate 75% convention for UL 248 fuses. S506 is an IEC 60127 family, so the old extra 75% factor must not be silently inherited as a mandatory second derating.

The current PDF’s graph could not be retrieved visually. The manufacturer-authored [January 2024 S506 sheet, page 2, hosted by a distributor](https://www.fusibles-electricos.com/wp-content/uploads/2024/12/FUSIBLES-S506-BUSSMANN-TRANSMEXICANA.pdf) was downloaded and visually inspected. Its same-family curve reads approximately 92% at 60 °C. Use **90%**, rounded downward, as the working factor: 4 × 0.90 = **3.6 A** main and 0.8 × 0.90 = **0.72 A** touch, above the 3 A and 500 mA ceilings. This is explicitly older-family graphical evidence, not a claimed exact reading of the March 2026 graph. As a further sensitivity, even an 80% factor leaves 3.2 A / 0.64 A. The required factors are only 0.75 / 0.625 respectively. The curve source is linked above; the numerical assumptions are recorded in the accompanying calculations.

At the stated normal currents, typical cold fuse losses are 41.7 mV / 0.125 W on a 3 A main and 64.5 mV / 0.0323 W on a 500 mA touch line. The fuse body must have air space; do not place it against a hot buck or relay. A clip pair at the modeled 10 mΩ dissipates 90 mW on a main or 2.5 mW on touch. At a doubled 20 mΩ pair these become 180 mW and 5 mW. The 15 A clip rating provides substantial current headroom, but is not a missing thermal curve.

## Startup and pulse sensitivity

The following calculations deliberately use an ideal 5.25 V step. A source resistance of zero is used in the joined-path model; the relay's 30 mΩ **maximum** contact resistance is never used as a guaranteed minimum inrush limiter. Fuse resistance and I²t are typical values, not production minima. The unknown screen capacitance is examined from 1 to 10 mF; that is a sensitivity range, not measured capacitance.

For one capacitor charged through resistance R:

`integral(i² dt) = C × V² / (2 × R)`

At 10 mF, the main fuse's typical resistance alone gives:

`0.010 × 5.25² / (2 × 0.0139) = 9.915 A²s`

This is 13.8% of 71.8 A²s. Halving that resistance raises the model to 19.829 A²s, or 27.6%; at 1 mF every result is one tenth as large. By comparison, the removed Bel 4 A model was 8.61 A²s against its 81 A²s short-pulse nominal value. The Eaton main has slightly less relative reserve, but remains far better suited to hard contact make than the earlier fast 4 A fuse's 2.45 A²s nominal value. This ratio is not a guaranteed repetitive no-open criterion.

For a screen whose power and touch inputs join internally, let Rm and Rt be the complete branch resistances before their join:

`Rp = Rm × Rt / (Rm + Rt)`

`touch fraction = Rm / (Rm + Rt)`

`touch pulse = C × V² / (2 × Rp) × [Rm / (Rm + Rt)]²`

Using the prior broad example Rm = 0.050 Ω, the new Rt = 0.129 Ω, and 10 mF gives 0.2984 A²s through touch. The known 150 µF local capacitor at +20% tolerance gives 180 µF and 0.01923 A²s. A conservative overlap bound, without assuming the two current pulses are disjoint, is:

`[sqrt(0.2984) + sqrt(0.01923)]² = 0.4691 A²s`

That is **16.9%** of Eaton's typical 2.78 A²s, compared with the previous Bel example's approximately 20.2% of its 2.3 A²s short-pulse nominal value. It does not place the full 10 mF behind touch alone, because both normal main and touch cables are connected.

| Main-path Rm, with Rt = 0.129 Ω | Touch overlap bound, 10 mF + 180 µF | Fraction of typical 2.78 A²s |
|---|---:|---:|
| 0.020 Ω | 0.2677 A²s | 9.6% |
| 0.050 Ω | 0.4691 A²s | 16.9% |
| 0.100 Ω | 0.6752 A²s | 24.3% |
| 0.200 Ω | 0.8922 A²s | 32.1% |

The 0.050 Ω main example is not a universal measured harness resistance. Extra main-cable/clip resistance moves more pulse current into touch, as the table shows. Resistance tolerances, initial fuse temperature and arbitrary repeated contact bounce remain outside a guaranteed minimum-I²t proof. Four fully discharged identical touch pulses would sum to about 67.5% of nominal melting I²t in the 0.050 Ω example; actual contact bounce normally cannot repeatedly discharge the entire screen capacitor instantly. Do not call this an unlimited-bounce guarantee.

## Normal voltage distribution

Use 85 mV for a 3 A main fuse and 150 mV for a 500 mA touch fuse as explicit working allowances. The main figure slightly exceeds twice its nominal cold resistance at 3 A (83.4 mV); touch's figure is approximately 2.33 times its nominal cold drop. They are conservative modeling choices rather than manufacturer hot maxima. Do not turn the contradictory 75 mV touch entry into a guaranteed value. Assume 10 mΩ for a complete output clip pair; also report the doubled-contact sensitivity.

The following table retains the prior extreme planning point: 4.4 A input, 4.25 A through K1, 3 A in the assessed main path or 0.5 A in the assessed touch path, and 30 cm one-way wiring at 60 °C. The branch maxima are alternatives within the combined current budget, not simultaneous allocations of 3 A to both screens.

| Loss from J1 terminals onward | Main | Touch |
|---|---:|---:|
| SPT input-fuse working allowance | 100 mV | 100 mV |
| OGN complete holder, 4.4 A × 10 mΩ | 44 mV | 44 mV |
| Shared input/return copper target | 20 mV | 20 mV |
| K1 initial contact, 4.25 A × 30 mΩ | 127.5 mV | 127.5 mV |
| Shared switched-bus copper target | 20 mV | 20 mV |
| Branch-fuse working allowance | 85 mV | 150 mV |
| Output clip pair, 10 mΩ model | 30 mV | 5 mV |
| Branch PCB/return copper target | 20 mV | 20 mV |
| VH or XH positive/return contact allowance | 60 mV | 10 mV |
| 20 AWG or 28 AWG positive/return cable model | 69.4 mV | 74 mV |
| **Total** | **575.9 mV** | **570.5 mV** |

At 4.75 V J1 this leaves 4.1741 V / 4.1795 V before the final USB connector/termination. At nominal 5 V it leaves 4.4241 V / 4.4295 V. Doubling output clip resistance to 20 mΩ adds another 30 mV main or 5 mV touch loss. These intentionally stacked allowances do **not** prove the screens fail, but they also do **not** prove that their minimum-voltage requirement is met. Do not publish a new USB minimum-voltage guarantee from this analysis. Real normal loads and typical component losses are lower; the user's measurements establish consumption at a 5 V supply, not a minimum screen-terminal operating voltage.

For a practical nominal-input case, use **5.00 V at J1**, 2.0 A for the large screen main feed (the observed startup was below 10 W and full-brightness sweep below 9 W), 1.2 A for the small screen main feed (6 W observed), and retain the full 500 mA allocation for each touch lead. Those conservative branch allocations plus the 50 mA bleeder sum to the existing 4.25 A switched budget. They intentionally retain headroom and do not rely on the inconsistent current-versus-power readings being more precise than reported.

With **20 cm maximum one-way** power/touch wire runs, the same conservative shared-loss allowances, and branch-fuse allowances represented as the effective resistance implicit in the 3 A / 500 mA budget:

| Practical nominal-input scenario | Calculated voltage before final USB termination |
|---|---:|
| Large screen, 2.0 A main, 20 AWG pair | 4.521 V |
| Small screen, 1.2 A main, 20 AWG pair | 4.580 V |
| Touch, full 500 mA, 28 AWG pair | 4.454 V |

This uses `Rwire = 2 × length × resistance_per_metre_20C × 1.1572`, with 0.03331 Ω/m for 20 AWG or 0.2129 Ω/m for 28 AWG. The main fuse working resistance is 0.085/3 Ω; touch is 0.150/0.5 Ω. A doubled 20 mΩ clip pair would subtract a further 20 mV / 12 mV / 5 mV respectively. Input voltage at the buck is not automatically input voltage at J1; the short 16 AWG incoming pair must preserve the stated board-terminal value.

For context only, a less stacked component scenario using the input fuse’s rated-current typical effective resistance (70 mV/8 A), branch-fuse cold resistance multiplied by 1.5, and all other contact/copper allowances unchanged gives approximately 4.597 V / 4.650 V / 4.569 V in these three paths. This remains a model, not a guaranteed minimum. It explains why nominal operation is materially less severe than the 4.75 V / 3 A extreme corner without concealing that final USB termination and screen undervoltage thresholds are not characterized here.

The 20 cm length is a recommended wiring target, not a claim that the purchased cable was measured. If the enclosure route needs 30 cm, the extra loss is approximately 15 mV on the 2 A main, 9 mV on the 1.2 A main or 25 mV on 500 mA touch. Main leads can use 18 AWG within the selected VH contact’s supported range to reduce loss further; do not change the purchased touch interface merely to chase a modeled millivolt value.

Keep mains short, use at least 20 AWG for both power and return, retain proper VH terminations, and keep purchased 28 AWG touch leads short with their 500 mA allocation. A new soldered fuse is not needed to improve this budget; copper length, main-wire gauge and normal input voltage are the available practical levers. Any changed minimum J1 requirement must be explicit, never silently moved after F1. The branch clip and fuse losses are downstream of K1 and do not consume additional coil-feed margin directly.

## Fault and wire implications

For both selected ratings, the current S506 sheet specifies maximum opening times of 120 s at 2.1×, 10 s at 2.75×, 3 s at 4×, and 0.3 s at 10×. For the touch fuse these correspond to 1.68 A, 2.2 A, 3.2 A and 8 A. For a main fuse they correspond to 8.4 A, 11 A, 16 A and 40 A. These are data-sheet test-condition limits, not separately proven DC total-clearing guarantees.

At 60 °C, a 30 cm one-way 28 AWG copper pair has approximately 0.1489 Ω loop resistance. It dissipates 0.0372 W at the normal 0.5 A, 0.420 W at a 1.68 A fault, and 0.721 W at 2.2 A. A 30 cm 20 AWG pair has about 0.02311 Ω loop resistance: 0.208 W at normal 3 A and 1.631 W at an 8.4 A fault.

The short high-current end is tractable: the 8 A / 0.3 s touch limit corresponds to 19.2 A²s and approximately 17.2 °C adiabatic copper rise using initial 60 °C resistance; the 40 A / 0.3 s main case gives approximately 10.3 °C. These are simplified fixed-resistance estimates, not measured insulation temperatures. Temperature-dependent resistance would increase the result; real heat loss lowers it.

The prolonged partial-fault end cannot be certified from wire gauge alone. An adiabatic model at 1.68 A for 120 s gives a very large rise and is inappropriate as a prediction once heat transfer matters; the real answer depends on insulation, bundling, jacket and installation. Do not use the small nominal melting I²t to promise wire protection in that slow regime. The prior Bel implementation also left a prolonged-fault qualification, but its 2×/60 s timing must not be copied to Eaton. The new selection has an explicit moderate-fault limit much shorter than SPT touch's 30-minute 2.1× bound; it is not an active 800 mA current limiter.

If main and touch rails are joined inside a screen, either branch may contribute to a fault. A main-wire fault can clear the main fuse first and leave a residual path through touch until its own fuse opens. Correct separate fusing remains important; do not bypass the touch fuse, upsize it to 4 A, or use touch alone as the intentional supply for the large panel. Correctly sleeved, strain-relieved, undamaged wiring and exact fuse replacement remain part of the assembly design.

F1 does not guarantee selectivity against every branch fault, and neither the 8 A input fuse nor the upstream 20 V fuse guarantees clearing of every current-limited fault below its own operating multiple. Its upstream wire remains outside F1's protection. Do not extrapolate this design to a battery or a high-fault-current bench supply from the manufacturer's self-certified DC voltage alone.

## Reproducibility and remaining implementation work

The accompanying [calculation script](replaceable-fuse-calcs.py) reproduces the pulse, loss and simple wire-energy calculations; [its output](replaceable-fuse-calcs.json) records the results. No concrete fuse-rating, pulse or normal-load blocker was found within this documented envelope. Verify exact fuse identity and clip geometry in the final BOM/native board, update the checker and documentation from the selected data, substantiate the routed copper budgets, and retain the DC/temperature/voltage limitations above. This report is not a final KiCad, fabrication or production approval.
