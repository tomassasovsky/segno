<!-- cspell:words ampacity resistivity VOH VOL VIH VIL VDD Worldsemi NBS derating -->
# Ring full-white voltage-margin addendum

This supersedes the earlier 600 mm, four-wire, console-powered harness assessment. Copper ampacity was adequate, but nominal voltage-drop arithmetic did not establish the AHCT buffer's 4.5 V operating floor at warm-wire and aged-contact corners. The replacement below changes wiring only; no PCB copper or firmware brightness restriction is required.

## Selected wiring and calculated bound

Run a **600 mm maximum, 16 AWG copper supply/return pair** from the AUX buck posts to an insulated split near the ring. From that split use two separate **50 mm maximum, 22 AWG pairs**: one directly to the strip's +5 V/GND, and one to ring J1 pins 1/2. The genuine XH contacts accept the 22 AWG branch; do not force 16 AWG into them. Keep console J6 cavities 1/2 empty. J6.3 goes to J1.3 and J6.4 to J1.4. On ring J2 use **pin 3 to DIN only**; pins 1, 2 and 4 are unconnected. Leave alternative module footprints J3/J4 empty. This avoids a parallel high-current return through the carrier or console.

The operating contract is **4.75–5.25 V at the loaded AUX posts**, 2.44 A strip plus 0.20 A ring electronics, and wire at no more than 60 °C. Calculations use copper resistivity 1.75e−8 Ω·m at 20 °C and coefficient 0.00393/°C. Reserve 10 mΩ for the complete common supply/return termination pair and another 10 mΩ for each branch's complete joint pair. These are engineering termination budgets, not measured properties of an unspecified splice.

| Loss at the defined corner | Value |
| --- | ---: |
| 600 mm 16 AWG pair, 1.31 mm², 2.64 A | 48.973 mV |
| Common termination allowance | 26.400 mV |
| 50 mm 22 AWG controller pair, 0.326 mm², 0.20 A | 1.242 mV |
| Two aged XH contacts, each 20 mΩ at 0.20 A | 8.000 mV |
| Controller branch joints | 2.000 mV |
| Carrier supply/return allocation | 40.000 mV |
| **AHCT minimum local supply** | **4.623 V** |
| **Margin above AHCT's 4.5 V minimum** | **123 mV** |
| Strip pair plus its joint allowance, 2.44 A | 39.557 mV |
| **Minimum at strip power input** | **4.635 V** |

Conservatively publishing 4.620 V / 4.632 V remains valid. The native positive path from J1.1 to U2.14 is 19.056722 mm with 14.448071 squares. A 55.201125 mm, 0.298 mm-wide corridor was independently contained in the actual rear ground/pad copper from J1.2 to U2.7. Treating the entire 0.20 A as flowing through each path, at 100 °C copper, nominal 35 µm thickness and 20% negative width tolerance, gives 2.374 mV positive plus 30.435 mV return. The 40 mV allowance exceeds that deliberately narrow single-corridor estimate; the real broad plane and parallel routes are not credited. This is a resistance estimate, not a measured temperature or full-field extraction.

At 2.64 A the former four XH contacts alone could lose 211.2 mV at their after-environment limit. Combined with 500 mm of warm 22 AWG and the warm/reduced-width console and carrier positive tracks, the old route could lose about 510 mV before input-connector and return losses. Shortening it was not a robust solution: current enclosure coordinates put console J6 and ring J1 about 426 mm apart before slack. The earlier 600 mm text was an installation estimate, not an actual harness measurement.

## Logic references and physical route

The strip and controller returns meet at the same local split. Their common heavy-trunk drop therefore cancels from the local DIN reference. Charging the full 40 mV carrier allocation to ground, plus the short branches, contacts and joint allowances, bounds the local relative offset below **80 mV**. The AHCT datasheet's 4.4 V minimum high / 0.1 V maximum low at 50 µA remains sufficient for the WS2812B reference's 0.7×VDD / 0.3×VDD input thresholds across the stated rail range, including that offset and the 330 Ω resistor's drop at its 1 µA input-leakage specification. This is a static level check, not a claim about every unspecified strip variant or its internal far-end copper drop.

UART still has a common reference through the independent AUX returns. Normal console/pill loading is about 0.718 A after removing ring power from J6. The ring return budget is below 0.09 V relative to the AUX posts. Reserve 0.10 V for the console return, including its 16 AWG feed, aged VH ground contact and plane; use **0.20 V** as the conservative link-offset allocation. At 3.3 V I/O, RP2350 guarantees VOH≥2.62 V, VOL≤0.5 V, VIH≥2.0 V and VIL≤0.8 V: a 0.20 V offset leaves high≥2.42 V and low≤0.70 V. The console return figure is an engineering allocation, not a solved chassis/ground-plane network. This review does not certify noise immunity or a disconnected common return.

A route within 600 mm exists in the current conservative enclosure envelopes without the narrow tower/CLEAR gap. In the documented world frame, a planning centerline is AUX top `(447.9,359,29)` → `(423,296,40)` → `(423,160,40)` → `(219,160,40)` → `(219,232,50)` → local split `(150,232,55)`, about **551 mm**. It goes beside BANK and then through the clear space between the pedal rows, remaining in front of the tower. Allow up to 15 mm from the actual buck lead exit to the first point; roughly 34 mm remains for relaxed bends within the 600 mm maximum. This is an envelope proposal, not an installed cable model. The separate 40-strip housing and exact purchased-wire bend radius are not represented in the current assembly.

The retained buck's nominal 5 V label does not independently establish its loaded 4.75 V floor or temperature derating. That remains an ordinary first-assembly qualification, not a request for a pre-PCB prototype. Likewise, the 4.635 V figure is at the strip's supply pads, not a guarantee of every pixel's internal voltage. The defined harness removes the verified connector/console-path headroom problem while preserving unrestricted ring commands.

## Sources and evidence

Primary limits: [TI AHCT125](https://www.ti.com/lit/ds/symlink/sn74ahct125.pdf), [JST XH](https://www.jst-mfg.com/product/pdf/eng/eXH.pdf), [JST VH](https://www.jst-mfg.com/product/pdf/eng/eVH.pdf), [RP2350, Table 1436](https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf), [Worldsemi WS2812B reference](https://cdn-shop.adafruit.com/datasheets/WS2812B.pdf), [NBS copper-wire tables](https://nvlpubs.nist.gov/nistpubs/Legacy/hb/nbshandbook100.pdf).

Local evidence: `ring-voltage-margin.json`, `ring-return-bound.json`; native carrier `hardware/kicad/segno_pedal_ring.kicad_pcb`; enclosure source `hardware/enclosure/segno_enclosure.py`; obstacle envelopes in `docs/reviews/pcb-completion-1072/screen-power-placement.json`. The old console translation in `FUSION_MODELS.md` predates the source's 48 mm console move; the current generator was used for the console distance. All source hashes are in the JSON.
