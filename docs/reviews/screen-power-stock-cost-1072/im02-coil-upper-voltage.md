<!-- cspell:words Hannfit Umax energization monostable overvoltage preenergized -->
# IM02TS maximum continuous coil voltage

28 September 2026. Bounded independent read-only review of the selected TE IM02TS / 1-1462037-3 USB relays. No circuit, guard, native board, BOM or shopping changes.

## Verdict

**No coil-overvoltage defect found at the specified 5.25 V maximum AUX and 60 °C local surrounding air.** The maximum-coil-voltage criterion already includes steady coil self-heating. It is distinct from the cold/hot pickup criterion in `holder-coil-budget.md`. No added resistor, regulator or relay substitution is justified by this check.

The applicable zero-contact-load, 140 mW monostable curve is about **2.1 times nominal at 60 °C**. Round downward to **2.0 × 4.5 = 9.0 V** for a deliberately coarse graphical comparison. Ignoring every beneficial fuse, copper and MOSFET voltage drop, our **5.25 V** is **1.1667 times nominal**, leaving at least **3.75 V** below that conservative graphical ceiling (58.3% utilization; 41.7% below the ceiling). This is a graph reading, not a new exact tabulated TE limit.

## Primary evidence and provenance

- [TE exact product page](https://www.te.com/en/product-1-1462037-3.html) identifies IM02TS as the standard 4.5 V / 145 Ω / 140 mW monostable version, with an ambient range to 85 °C.
- [TE IM datasheet, 108-98001](https://www.te.com/commerce/DocumentDelivery/DDEController?Action=srchrtrv&DocFormat=pdf&DocLang=English&DocNm=108-98001&DocType=Data+Sheet&PartCntxt=1-1462037-3), current **07/26** edition, read directly using web PDF extraction: page 3 gives ±10% resistance, the standard-monostable operating-range plot and the 23 °C non-preenergized table; page 4 gives thermal resistance below 150 K/W.
- To inspect the graph visually, downloaded the manufacturer's **08/24** edition from its [Hannfit mirror](https://hannfit.com.au/wp-content/uploads/AXICOM-signal-relays.pdf) and rendered page 3. Its plot labels, axes and coil table correspond to the current document's extracted page 3. The numeric graph reading above comes from this explicitly dated visual copy; the web screenshot interface returned no image and direct current-TE download returned HTTP 403. Do not describe this as visual inspection of the July 2026 PDF.
- [TE relay definitions](https://www.te.com/commerce/DocumentDelivery/DDEController?Action=srchrtrv&DocFormat=pdf&DocLang=English&DocNm=Definitions_Relays&DocType=Specification+Or+Standard&PartCntxt=1-1462037-3), pages 3–4, 13 and 18: ambient is temperature near the relay; Umax is the continuous-energization ceiling at which self-heating reaches the permitted coil temperature; operating-range diagrams assume single mounting without thermal interference; thermal resistance relates steady coil power to winding rise. The default duty factor is 100% unless otherwise specified.

Thus **60 °C is local air, not a 60 °C winding ceiling**. It would double-count heating to add calculated winding rise to ambient before reading TE's continuous Umax graph. Conversely, nominal 4.5 V is not an absolute maximum.

## Independent self-heating cross-check

Conservatively omit the two series TN0702 drops and all input losses. Take minimum winding resistance at 23 °C, R23 = 145 × 0.90 = 130.5 Ω; thermal resistance 150 K/W; copper coefficient 0.00393/K, retained from the existing engineering model.

Solve the steady-state model:

`T = 60 + 150 × 5.25² / [130.5 × (1 + 0.00393 × (T − 23))]`

Result: **85.439 °C winding**, **162.523 Ω**, **32.303 mA**, **169.592 mW**, or **25.439 °C rise** per relay. Initial power at a 60 °C winding is 184.394 mW; heating raises resistance and reduces it. At 23 °C with minimum resistance it would initially be 211.207 mW. These are calculations under the stated thermal model, not measured assembly temperatures or a replacement for the manufacturer's operating-range condition.

## Actual circuit and limits

The selected source and guard connect K101/K201 coil pin 1 to AUX_5V and pin 8 through two TN0702 devices to ground. D101/D201 1N4007G flyback paths exist with cathode toward AUX. They are reverse-biased during energization. No claim of missing suppression applies. Series driver resistance only lowers energized coil voltage/power, so ignoring it is conservative for this upper-limit question.

The relay contacts carry USB D+/D−, not screen supply current; negligible contact heating is the appropriate curve. The two coils dissipate approximately 0.34 W together at the adverse model point. Neighbour and PCB heating must remain inside the established local-air/thermal envelope; the TE single-mount curve alone does not certify the actual enclosure's temperatures. Preserve that scope, but this check found no specific layout or circuit defect requiring a change. The 85 °C part ambient rating must not be presented as proof of hot pickup at 85 °C.

## Visual-source identity

The inspected manufacturer 08/24 PDF has SHA-256 `506d1a62b5de57296a0d34d6018b4aa1f7b8f6e035efee13193d36291cfd6dbb`. It is the explicitly dated mirror linked above, not a claim of visual access to the current July 2026 document.
