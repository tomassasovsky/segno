> **Screen-board correction, 25 September 2026:** This is a historical report. Its screen relay-pinout approval is superseded: IM02TS commons are 3/6, NC contacts are 2/7, and NO contacts are 4/5. Revision I Gerbers are withdrawn. Use the [corrected Revision J record](../screen-power-rev-j-1072/verification.md). Console and ring findings are unaffected.

# 40-pixel full-white fabrication verification — 25 September 2026

The September 26 [final voltage review](../production-final-1072/ring-voltage-margin.md)
supersedes this report's straight-through power-harness assumption for the
selected 40-pixel strip. The PCB current-capacity evidence remains applicable; current
assembly sends strip current directly from AUX and only DIN through carrier J2.


The new v3 console and white ring carrier now supply one 40-pixel RGB strip at
unrestricted full white without depending on a firmware brightness cap. These
exports replace the September 24 console and ring order files. The screen-power
revision I export is unchanged. This is a bare-board first-fabrication decision;
assembled operation has not yet been measured.

Issue: #1072. Hardware PR: #1080, based on #1066. Review baseline:
`f8d6f889ba51bf1a8cb5e29b6f00fd852465ee2d`. Exact native/source hashes are in
[sources.json](sources.json); independent source-to-export correspondence is in
[the parity record](raw/independent-artifact-parity.json).

## Electrical change

- Console: a dedicated 1.7 mm supply route from the input copper bar to J6,
  four parallel 0.5 mm drilled layer-transition vias and stronger ground-pad
  connections. The lower-current console-logic branch remains separate.
- Carrier: a direct 1.5 mm front-copper route from J1 to J2, bypassing the
  narrower buffer/module branch. Three parallel 0.4 mm drilled ground vias
  connect J2's wire pad to the main rear return plane. DOUT moves clear of the
  new supply path.
- Critical copper is locked, installed before signal routing, and checked on
  the actual saved boards before fabrication export. General track widening
  now preserves existing wider power routes. Failed DRC stops export.

Both remain two-layer, 1 oz, 1.6 mm boards. Components, connector pinouts,
footprint positions, outlines and all net assignments are unchanged; there is
no added component or copper-weight cost. The native comparison verifies all
206 connected console pads and 63 connected ring pads against their netlists.
See [geometry.json](geometry.json).

The design allowance is 40 × 60 mA = **2.4 A** for RGB-white channels, another
40 mA for pixel idle, and 200 mA for the ring controller/buffer: **2.64 A** at
the console-to-ring connector. The 60 mA value is a conservative planning
allowance, not a measurement of the purchased strip.
[Adafruit's power guide](https://learn.adafruit.com/adafruit-neopixel-uberguide/powering-neopixels).

Use **22 AWG power and ground** between console J6 and ring J1 and from J2 to
the strip. Use the specified XH contacts, including SXH-001T-P0.6 for the
22 AWG harness. JST rates XH at 3 A with 22 AWG; the shared VH console-input
harness needs 16 AWG for its 10 A rating. Thin USB signal leads are not a
substitute for these power wires.
[JST XH](https://www.jst-mfg.com/product/pdf/eng/eXH.pdf),
[JST VH](https://www.jst-mfg.com/product/pdf/eng/eVH.pdf).

Using the repository's conservative IPC-2221 external-copper estimate at a
10 °C temperature rise, with 20% negative track-width tolerance included:

| Feed | Nominal width | Width used in calculation | Estimated current | Design load |
| --- | --- | --- | --- | --- |
| Console to ring | 1.7 mm | 1.36 mm | 2.99 A | 2.64 A |
| Carrier to strip | 1.5 mm | 1.20 mm | 2.73 A | 2.44 A |

The 1 oz copper and width tolerance follow
[JLCPCB's manufacturing capabilities](https://jlcpcb.com/capabilities/Capab).
Nominal positive-trace loss at 20 °C is approximately 73 mV on the 93.95 mm
console feed and 18 mV on the 22.64 mm carrier feed. These estimates exclude
connector, harness, return-path and warm-copper losses; they are not measured
temperature or voltage guarantees. Native filled ground paths were reviewed
separately from the positive-track calculation.

## Whole-system boundary

The 5 V / 10 A AUX buck remains a shared limit. The conservative budget with
both screens at their combined 6 A design envelope, a full-white ring, and
the current normal pill patterns is approximately **9.41 A**:

| Load | Current allowance |
| --- | --- |
| Screens | 6.000 A |
| Full-white ring channels | 2.400 A |
| Normal pill channels | 0.498 A |
| Idle allowance, all 120 pixels | 0.120 A |
| Console logic | 0.140 A |
| Ring controller/buffer | 0.200 A |
| Screen discharge resistor | 0.050 A |

The normal-pill calculation uses the eight-pixel envelope and brightness 128
in the separate v3 runtime draft #1082 at `92af127d`: nine maximum single-colour
pills and the REC/PLAY amber pill. See [system wiring](../../../hardware/segno_wiring.md).
This gives about 0.59 A nominal margin, not a supply transient or enclosed
temperature guarantee. All 120 LEDs at unrestricted white together with the
screens would instead require approximately **13.71 A** and is outside this
10 A system's capacity. No brightness cap is required specifically to protect
the revised 40-pixel ring feed.

Fit only one LED option: the 40-pixel strip at J2, or the alternative 24-pixel
module at J3, or the 16-pixel module at J4. Firmware must match that selection.
This PCB change does not change or flash either firmware, alter the pedal's
animations, or upgrade the physical old v2 console already in use.

## Verification

- Final console and ring KiCad DRC, all severities and all track errors:
  **zero violations and zero unconnected items**. Raw results are
  [console-drc.json](console-drc.json) and [ring-drc.json](ring-drc.json).
- Actual-board power guards pass; each rejects seven injected faults. The
  console routed-board gate and the ring circuit checks pass.
- Width-helper regression preserves wider copper; restoring the old shrinking
  behavior makes that regression fail. Injected DRC failure stops console
  export before deleting or creating manufacturing files.
- Python compilation and shell syntax pass. Fresh console placement keeps the
  fixed power path valid before signal routing; DSN exports preserve locked
  copper. Native board visual review accompanies the numerical geometry checks.
- Every revised ZIP member matches its loose export. An independent fresh
  native-board export matches all 22 console/ring files after creation timestamps
  alone are normalized. Screen ZIP hash is unchanged from its completed review.
- Architecture, test quality, simplicity, VGV and bug-focused reviews found no
  actionable defects; final publication readiness is recorded alongside them
  in [raw/](raw/). Repository CI is absent for this feature-branch base, not green.

The earlier full hardware review remains the baseline for unchanged screen,
GPIO and other circuitry. The final delta review is recorded under
[code review](raw/code-review.md).
These checks support first fabrication without additional owner measurements.
Cable polarity, actual LED/USB behavior, supply drop and heating remain checks
for the first assembled boards. No manufacturing order has been placed.

## Current fabrication archives

Use the archives under `hardware/kicad/fab/`. Full member hashes are recorded
in [manufacturing-zips.json](manufacturing-zips.json).

| Archive | SHA-256 |
| --- | --- |
| `segno_console_v3_gerbers.zip` | `88960bd4d96e7f06e7c9a60fb59f99a8735a10ec35e0865b3b64e40c7efab2eb` |
| `segno_pedal_ring_gerbers.zip` | `d27aff2c3694b6c0f48cedd2f0bf6e9b38093dabef02558c775b456732f006ef` |
| `segno_screen_power_rev_i_gerbers.zip` | `25370578cbb1184f6d2bc1913c88746ff87ce91809779c7878d62f4af735a878` |

Order five bare boards of each design, FR4, two layers, 1.6 mm, 1 oz, tented
vias, without assembly or a stencil. Console: 99.5 × 99.5 mm, purple/white,
lead-free HASL. Ring: 80 mm diameter, white/black, lead-free HASL. Screen:
68 × 76 mm, purple/white, ENIG. Preserve the supplied finished outlines and
plated/non-plated drills. See [ring assembly](../../../hardware/kicad/RING_ASSEMBLY.md)
for the module, wiring and programming instructions.
