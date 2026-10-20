<!-- cspell:words IRLZ Omron Omron's Schurter Vcoil Vpickup fuseholder -->
# Replaceable input fuse and relay-coil budget

Scope: Schurter SPT 0001.2513 (8 A, 5 × 20 mm) in an OGN 0031.8201 holder, feeding the proposed G6C-1117P-US DC5 power relay and the existing two USB relays. Calculation updated on 28 September 2026 for the explicit 4.46 A input bound. Native validation and fabrication release are separate checks. Branch-fuse selection is outside this report.

## Decision

The holder does **not** make normal cold or hot pickup inadequate under the existing 60 °C local-air / 100 °C maximum winding engineering envelope. The power relay picks up while its normally open contact disconnects the screen load, so the holder then carries only the coils and control current. It would be misleading to describe the normal screen load as present before that contact closes.

The fully loaded conservative budget is much tighter than before: 2.4 mV above the same 100 °C pickup model. That is a useful stress calculation, not a comfortable tolerance reserve or a guaranteed thermal limit. Keep the distinction between initial pickup and loaded operation explicit; do not claim the new holder preserves the old 67 mV fully loaded margin. No automatic part rejection is justified by that 2.4 mV figure alone, and the 10% must-release figure must not be misused as a guaranteed holding-voltage specification.

## Actual new component data

The [Schurter SPT data sheet](https://www.schurter.com/pdf/english/typ_SPT_5x20.pdf), page 3, lists 0001.2513 as 8 A, 150 VDC, with 100 mV maximum and 70 mV typical voltage drop at rated current. Its typical melting integral is 268 A²s at 10 times rated current. None of these are the removed Bel fuse's values.

The [OGN data sheet](https://www.schurter.com/en/datasheet/typ_ogn.pdf), page 1, lists contact resistance ≤10 mΩ at 100 mA under IEC 60127-6, 16 A UL/CSA rating, and an ambient range through 85 °C. The manufacturer’s [fuseholder technical guidance](https://www.schurter.com/en/knowledge/fuseholder) defines this resistance between the holder terminals, so 10 mΩ covers the complete holder path, not each end separately. It does not establish an unlimited-life, arbitrary-temperature contact resistance. Maintain sound clean contacts and use the exact documented holder.

The [Omron G6C data sheet](https://components.omron.com/us-en/system/files/2026-03/datasheet_pdf/K018-E1.pdf), pages 3–5, gives the chosen 5 V single-side-stable relay a 125 Ω coil (±10%), approximately 200 mW consumption and 70% maximum pickup at 23 °C. The 60 °C local-air budget is within its ambient rating. Its engineering graphs do not give a guaranteed temperature-rise curve for this exact 5 V coil, board and contact load.

Omron's [relay technical guide](https://edata.omron.com.au/eData/Relays/GeneralRelay_TG.pdf) explains that winding resistance and pickup voltage rise by approximately 0.4% per °C, and that hot start must account for prior coil heating. The model below uses that published coefficient; the winding-temperature ceiling remains our engineering assumption, not a new manufacturer guarantee.

## Fixed reference and assumptions

- Minimum supply remains **4.75 V at the J1 board terminals, before the input fuse and holder**. It is not redefined at a downstream rail.
- Maximum steady input load is rounded to **4.46 A**: 4.25 A for screens, approximately 53 mA for the bleeder, and a 150 mA coil/control allowance. The numerical model rounds the bleeder upward to 60 mA. The switched contact therefore carries up to 4.31 A; it has approximately 0.557 W initial contact loss at the 30 mΩ maximum.
- Carry a full **100 mV** input-fuse allowance. This deliberately keeps its rated-current maximum even though the normal load is below 8 A. It is conservative relative to the published rated-current operating point, but is not a newly guaranteed 60 °C fuse voltage drop.
- Retain **20 mV** for shared and local positive/return copper, to be substantiated by the finished routing; and **5 mV** for the IRLZ44N driver.
- Retain the prior maximum **100 °C winding** allowance at 60 °C local air. A 40 °C rise is a design envelope, not an exact measured or manufacturer-guaranteed self-heating result. Contact heating and neighbouring components must not be ignored when reviewing placement.

## Cold and hot pickup

Before K1 closes, only control and coils draw from the fused input. With minimum 23 °C winding resistances, all three coils draw approximately 127 mA at 5.25 V; adding a deliberately generous 10 mA control allowance keeps the total below 150 mA. At 60 °C this estimate is lower, approximately 121 mA including that allowance. Thus the holder drop at pickup is at most 1.5 mV under the 10 mΩ working specification.

Retaining even the full 100 mV fuse and 20 mV copper allowances in this light-load state:

`Vcoil,pickup >= 4.750 - 0.100 - 0.0015 - 0.020 - 0.005 = 4.6235 V`

`Vpickup(T) = 3.5 × [1 + 0.004 × (T - 23)]`

| Winding temperature | Calculated pickup requirement | Pickup margin |
|---|---:|---:|
| 60 °C, not yet self-heated | 4.018 V | 605.5 mV |
| 90 °C, 30 °C rise | 4.438 V | 185.5 mV |
| 95 °C, 35 °C rise | 4.508 V | 115.5 mV |
| 100 °C, 40 °C rise | 4.578 V | 45.5 mV |

This hot-start calculation intentionally allows the fuse and winding to retain their previous heat. It does not rely on an instantaneous cool-down. The screens cannot add the normal 4.25 A demand until the power contact makes. Once it makes, capacitor charging can temporarily sag the supply; its magnitude and duration remain part of the previously identified relay/inrush assessment, not something this DC budget proves away.

## Fully loaded operation and sensitivity

At 4.46 A the holder allowance is 44.6 mV. The full static budget becomes:

`Vcoil,loaded >= 4.750 - 0.100 - 0.0446 - 0.020 - 0.005 = 4.5804 V`

This is 142.4 mV above the pickup model at 90 °C, 72.4 mV at 95 °C, and **2.4 mV at 100 °C**. It passes the model without relying on a guessed lower holding threshold, but the final number should not be presented as substantial margin. A modest adverse shift in working allowances can make that deliberately simultaneous stress case fail the pickup inequality; this does not establish actual release of a relay already closed.

For context, use of the fuse's typical 70 mV rated-current drop, still without scaling it down with load, would give 4.6104 V and 32.4 mV at 100 °C. That is a sensitivity example, not the acceptance value. A contact-resistance increase must not be concealed with that typical calculation.

The two USB relays have more reserve. Retaining the previously assessed adverse hot-coil resistance 162.523 Ω, 4.2094 V pickup requirement and 10 Ω combined hot driver resistance, the new fused supply of 4.5854 V gives approximately **4.3196 V across each USB coil**, or **110.2 mV margin**, even at full screen load. This reuses the explicitly stated USB thermal model, not a new guaranteed maximum temperature.

## Actionable implementation bounds

1. Keep the specified fuse and holder losses in the calculation and place the input fuse close to J1. Do not propagate the obsolete 80 mV Bel allowance into validation or documentation.
2. Verify the actual shared and coil-return copper against the 20 mV budget. If the finished layout reduces this to 10 mV, the loaded 100 °C stress margin increases to 12.4 mV; this improvement does not substitute for thermal reasoning.
3. Preserve the pickup sequence in the topology: the coils are supplied before the normally open power contact, and the screen branches after it. Do not power the K1 coil from SWITCHED_5V.
4. Preserve the 60 °C air and 100 °C winding engineering bounds openly. This report cannot certify an exact winding maximum from a manufacturer curve that was not published. It also does not certify indefinite dirty-contact resistance or the original screen-inrush unknowns.
5. If a larger guaranteed static voltage reserve is later required, the cleanest operational alternative is an **explicit** 4.80 V minimum at J1, which produces 52.4 mV in the same fully loaded 100 °C stress calculation. This is a changed input requirement, not an assumption to adopt silently. No change to the supply requirement is required by the ordinary light-load pickup calculation above.

These calculations do not claim final production approval. The source guard uses the same explicit current and voltage allowances; final routed copper evidence is recorded separately.
