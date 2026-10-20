<!-- cspell:words ampacity EEUFR netclass -->
# Independent adjudication of Claude's ring findings

Hardware baseline: `a1ff9d6d491c09f6e7f3c8b818440eb5c0493b7e`. Functional
runtime baseline: `dd46ab0d1a44bc55c7f42bc7db7992773c7a4113`. This records the
initial read-only assessment and subsequent authorized source edits. The
[final independent correction review](ring-independent-review.md) covers the
completed native correction and its exact identity.

1. **Encoder filtering:** accept reduced capacitance as a useful margin
   correction; reject the claimed guaranteed 240 rpm failure and contact-life
   prediction. ACZ11 revision 1.08 specifies phase intervals of at least 3.5 ms
   at 60 rpm, not a maximum operating speed. With 10 kΩ parallel to 86 kΩ and
   100 nF, the nominal rise to the RP2350's 2.0 V HIGH threshold is 0.834 ms;
   10.5 kΩ and 120 nF give 1.046 ms. Scaling a 3.5 ms interval to 240 rpm gives
   0.875 ms, so this model can lose the high-high detent at tolerance corners.
   That is not a guaranteed manufacturer waveform at 240 rpm. Missing idle 11
   can prevent completed cycles without creating the alleged two-bit jump.
   With 10 nF ±10%, X7R's +15% temperature allowance and +5% resistance,
   release is below 0.13 ms even without the internal pull-up. The 8 ms software
   pushbutton filter remains. This local one-resistor circuit is not the
   manufacturer's optional two-resistor filter and establishes no contact peak
   current or lifetime guarantee. Exact THT option: Vishay K103K10X7RF53H5,
   10 nF ±10%, 50 V X7R, 5 mm formed lead pitch, 3.6 × 2.3 mm body and
   0.50 ±0.05 mm leads. It fits the current footprint. See the
   [primary K-series sheet](https://www.vishay.com/docs/45171/kseries.pdf),
   pages 1–4. Stock availability was not inferred.

2. **Ground soldering:** accept the solid-pour hand-soldering concern, not a
   proven inability to solder within three seconds. A disposable native copy
   with through-hole thermal connections, 0.5 mm gap/spokes and 0.2 mm project
   clearance initially had one starved thermal at U2.1 on F.Cu. Rotating that
   pad's spoke angle from 90° to 45° gave zero DRC violations/unconnected pads.
   Through-hole-only thermal policy keeps module SMD ground solid. Every route
   and placement was preserved. Relief does not certify solder dwell; adding
   four spoke widths is not a universal ampacity calculation. The selected
   carrier load is 0.2 A, with strip current on its separate harness.

3. **Strip reservoir:** accept a local capacitor as a conservative BOM/harness
   improvement. The existing 470 µF capacitor is electrically nearby, so the
   claim of no reservoir was overstated and no failure was demonstrated.
   Specify Panasonic EEUFR1A102, 1000 µF / 10 V, across the strip entry:
   positive to +5 V, striped negative to GND, individually insulated joints,
   secured body outside the diffuser's optical region and clear vent. Its
   [exact primary page](https://industrial.panasonic.com/ww/products/pt/aluminum-cap-lead/models/EEUFR1A102)
   gives 10 × 16 mm body, 5 mm pitch, 28 mΩ maximum impedance at 100 kHz and
   1790 mA RMS ripple rating. [Adafruit's supply-entry guidance](https://learn.adafruit.com/adafruit-neopixel-uberguide/best-practices)
   recommends 500–1000 µF. Added bulk increases initial charge demand; this is
   not an inrush limiter or a hot-plug qualification. No PCB footprint is needed.

4. **Project clearance:** accept. The effective 0.13 mm class contradicts the
   0.2 mm routing contract. The temporary copy passes at 0.2 mm. Enforce that
   minimum and default clearance, retaining the existing routing guard and
   current geometry.

5. **Power guard scope:** accept the documentation correction. Existing J1/J2
   copper and vias serve retained alternative module/distribution paths. The
   selected 40-pixel strip receives only DIN from J2. Rename the misleading
   guard messages without removing the retained copper checks or historical
   evidence. Carrier checks do not prove harness voltage, crimps or local bulk.

6. **Mechanical tabs:** reject an alleged verified ESD fix. The ACZ11 drawing
   provides no guaranteed tab-to-shaft/bushing continuity or ESD strategy.
   Connecting netless mounting pads to logic GND would not establish the
   claimed shaft/nut/knob discharge route or a chassis grounding strategy.
   Keep them netless and document the limit. No owner measurement is needed
   for this bare-PCB correction.

7. **Part naming:** accept current shopping/manufacturing updates. Preserve
   the old 16-LED bench diffuser's physically measured EC11 assembly as a
   different historical artifact. Enclosure D_ENC=7.2 remains appropriate;
   nominal assumptions stay marked. Remove the obsolete tab-removal direction
   from current-part instructions, without changing historical geometry.

## Authorized implementation

C2/C3/C4 source and netlist use 10 nF; C5 is unchanged. The exact capacitors and
separate 1000 µF strip-entry part are in the BOM, assembly and shopping documents.
Two added filter fault controls bring the generator total to eight, all passing.
The native guard checks through-hole ground thermal policy, 0.5 mm gap/spokes,
0.2 mm minimum/all-netclass clearance and the new capacitor values. All thirteen
native fault controls and seven retained carrier-power controls pass.

Claude owns the authorized native thermal/project/value correction; final
native/CAM comparisons are reported separately. Source compilation, shell syntax
and scoped whitespace checks pass. Historical EC11 bench dimensions are clearly
distinguished. No new board area, layers, component movement or routing was
needed for this ring correction.
