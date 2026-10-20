<!-- cspell:words MLCC IOVDD EEUFR -->
# Ring correction: independent bug-focused delta review

2026-09-27. Baseline `a1ff9d6d491c09f6e7f3c8b818440eb5c0493b7e`; target is the working ring correction, native SHA-256 `2a2d139d824a981edb4f455533b4d57a190f456496606b1f80d9dc52b9c097cb` and project `a6cffa59f01474001d594b966af544395dd25a9448ea00834447ec3fc61b89f0`.

**No actionable finding. Scoped review complete.** This review covers the ring source/native/assembly correction, not concurrent console changes, final manufacturing ZIP parity or the whole-PR merge gate. No implementation file was changed.

## Scope and independent checks

Read the complete ring-related source and documentation diff and enclosing generator checks, native encoder guard, retained-power check and their deliberate fault controls. Traced the filter to the actual pinned XIAO runtime: quadrature reverse transitions cancel, invalid diagonal jumps reset, completed cycles count only at idle `11`, and the push switch has an 8 ms software filter. Reducing hardware filtering does not remove the existing software debounce mechanism.

Independently loaded old/current native boards through KiCad 10. All **564 tracks/vias**, **73 pad geometries/nets**, and **19 footprint placements/orientations** match the baseline. Only C2/C3/C4 component values change, to 10 nF; C5 remains 100 nF. Parsed old/current netlists: topology identical and only these three component records change. No layers, pin assignments or routing changes were smuggled into the refill.

Both actual GND zones read back as through-hole thermal connection, 0.5 mm relief gap and 0.5 mm spokes. U2 pin 1 uses 45 degrees. The two +5V TAP_FILLET zones retain full connections. Encoder C/S2 and other through-hole GND pads inherit thermal policy; module SMD ground remains solid. Native and project now enforce 0.2 mm clearance.

Executed `ring_encoder.py --self-test`: **all thirteen fault controls passed**, including removal of thermal policy, a pad's solid override, weakened minimum/default clearance and restoring the old filter value. Executed independent native DRC with `--severity-all --all-track-errors --exit-code-violations`: **exit 0, zero violations, zero unconnected items and zero schematic-parity items**. The independent DRC and fault-control results were retained for the final release audit. Existing ignored categories are missing courtyard, track endpoint not centered on via, tuning-profile geometry, footprint filter mismatch and footprint type mismatch; thermal starvation and clearance are not ignored. DRC plus preserved nets supports connectivity of the refilled ground; it does not certify solder dwell or thermal behavior of an assembled unit.

## Capacitors and timing

The [Vishay K-series primary sheet](https://www.vishay.com/docs/45171/kseries.pdf), pp. 1–4, supports the exact `K103K10X7RF53H5`: 10 nF, ±10%, X7R, 50 V, size 10, 0.50 ±0.05 mm wire and H5 formed 5 mm lead pitch. Its 3.6 ×2.3 mm plan dimensions fit the existing D5/W2.5 envelope; the maximum lead diameter 0.55 mm fits the 0.72 mm minimum finished hole from a nominal 0.8 mm drill and −0.08 mm tolerance. Maximum lead seating allowance plus body height totals 6.2 mm. The assembly documentation correctly warns that this is a rectangular radial MLCC despite the generic disc footprint name; no new footprint is electrically necessary.

The [RP2350 primary electrical table](https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf), current Table 1436, sets input HIGH at 2.0 V for 3.3 V IOVDD. Independently calculated `−10500 Ω × 10 nF ×1.10×1.15 × ln(1−2/3.3)` = **0.123734 ms**. This deliberately omits the parallel internal pull-up and includes the specified resistor/capacitor/temperature allowances. Same Sky ACZ11 revision 1.08 was read from the saved primary PDF: its phase interval is at least 3.5 ms at 60 rpm and its optional filter uses 0.01 µF. The documentation correctly calls the local one-resistor circuit different from that optional filter and does not promise a maximum rotational speed or contact lifetime. The source/netlist/native/BOM consistently use three 10 nF filters and retain C5 decoupling.

## Local strip bulk and harness contract

The [Panasonic exact EEUFR1A102 page](https://industrial.panasonic.com/ww/products/pt/aluminum-cap-lead/models/EEUFR1A102) confirms a polarized 1000 µF, 10 V part, 10 ×16 mm body, 5 mm pitch and at most 28 mΩ impedance at 100 kHz. The BOM and assembly instructions put it across the **strip's own** +5 V/GND entry with correct polarity, individually insulated joints, short leads, strain relief and clear vent. It is explicitly separate from carrier C1. This agrees with [Adafruit's supply-entry guidance](https://learn.adafruit.com/adafruit-neopixel-uberguide/best-practices); no hot-plug or current-limiting claim is added.

The selected harness still supplies the strip directly from the near-ring AUX split and gives the carrier a separate short pair; console J6 carries only UART and ring J2 carries only DIN for this assembly. Moving the strip's pulse reservoir to its entry does not send full-white current through the newly relieved carrier GND pads. The retained J1-to-J2 and alternative-module copper is preserved, and its checks are accurately renamed as carrier distribution checks. The full-white requirement and its existing wire/current budget are retained. Actual cable execution and enclosure placement of the extra capacitor remain assembly matters, not claims proven by carrier DRC.

The exact threaded encoder/nut purchase instructions replace misleading generic current-part references while preserving the earlier measured EC11 bench assembly as historical. Netless mechanical tabs remain explicitly unqualified as an ESD bond; no undocumented shaft continuity was assumed.

## Evidence identifiers

- `ring_board.py`: `71c991457364f2b4216bfd930e94dc40342056a35dcbe084231bd9b3c8347b50`
- `ring_board.net`: `56ee1e75943d6bd98118aae47c6e3ed4982c16a11d036edb247161e61b4a678a`
- `ring_encoder.py`: `6d84cba69c3ad5a95cf9971b05c4a41e6a9cc9a5d5abe896910a708f8251d306`
- `ring_power.py`: `abb7fc160175df9052f0f34e8578d122ec89b5a834ae323781330f67c2d8d8c0`
- Combined ring BOM: `adc75b11dd4d6a7ff099cc6f6d40511a37b533dac63f48e37f2650dbda2d7219`

This is author-side source/CAD evidence. It does not constitute CI, USB certification, an assembled encoder test, proof of the external harness's voltage drop, or a manufacturing order approval. Final export/native/ZIP consistency belongs to the release verification after all three boards settle.
