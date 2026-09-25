> **Screen-board correction, 25 September 2026:** This is a historical report. Its screen relay-pinout approval is superseded: IM02TS commons are 3/6, NC contacts are 2/7, and NO contacts are 4/5. Revision I Gerbers are withdrawn. Use the [corrected Revision J record](../screen-power-rev-j-1072/verification.md). Console and ring findings are unaffected.

<!-- cspell:words Omron Axicom Mbps datasheets energization Digi -->
# Screen-power revision C verification — issue #1072

Status: CAD verified prototype; physical qualification and shutdown software remain outstanding. No manufacturing order or production release has been made.

## Scope

Revision C changes both screen boards in the existing worktree. Console and ring boards are unchanged. The two-wire GPIO17/GND cable from console J25 remains the only GPIO connection. There are no external USB-C electronic modules.

- Replaced both expensive Omron RF relays with through-hole TE/Axicom IM03TS (1-1462037-8), listed at US$4.48 each on 2026-09-22. The relay pair costs US$8.96 instead of US$50.20; pricing excludes shipping/taxes.
- Used native KiCad IM03 symbols, independently checked TE pin mapping, and enlarged the standard footprint holes to 0.80 mm against TE’s 0.75 mm minimum.
- Reworked connector placement, manually routed USB and power, and added top-side connector purposes.
- Bundled models for all 37 populated parts in each variant. Five models are original simplified assembly geometry with linked manufacturer dimensions; the other models retain KiCad attribution.
- Portable native KiCad projects, populated renders, copper plots, assembly drawings, BOMs, STEP, and prototype Gerbers accompany each package.

## Observed validation

| Check | Hand | Factory |
| --- | --- | --- |
| Native ERC findings | 0 | 0 |
| Native DRC findings | 0 | 0 |
| Unconnected items | 0 | 0 |
| Populated model assignments | 37 | 37 |
| Passed fault injections | 15 | 12 |

KiCad 10.0.4. Full native schematic/generated netlist/PCB parity, independent circuit boundaries, actual console GPIO copper continuity, minimum power-copper connectivity, continuous inner ground planes and all-through-hole hand assembly pass. USB data uses 0.26 mm bottom copper with no data vias; maximum skew in each section is 0.696 mm. This is geometric validation, not an impedance or USB compliance measurement.

[Full validation](validation.json) records the exact checked source hashes and fault-injection results. [Model parsing](model-solids.json) independently loaded all 20 STEP files; each contained valid solids with positive volume. Final native views were visually inspected for populated components, connector directions, readable labels and routing.

## USB observation and electrical limits

The running appliance showed APROTII 1a86:e5e3 at 12 Mbps, and UPERFECT SiS 0457:0819 at 12 Mbps behind hub 1a40:0101 at 480 Mbps. The owner confirmed both touch leads go directly to the Pi. Thus the UPERFECT upstream board path must preserve 480 Mbps. No appliance settings were changed. USB descriptor power is not a measured screen load.

TE publishes RF characteristics for IM03TS; this supports prototype selection but does not establish assembled differential USB performance. At minimum assumed host VBUS and coil resistance and maximum driver resistance, calculated initial coil voltage is 4.598 V, versus the 3.75 V initial pickup threshold at 23 °C without pre-energization. Hot re-enable must be tested after coil self-heating at minimum supply and maximum intended enclosure temperature. No full-temperature assembly rating is claimed.

Q3/Q4 loss is calculated as 0.27 W per pair at 3 A combined, or 1.08 W at 6 A, using maximum 25 °C on-resistance. Hot resistance increases loss. These calculations do not establish enclosed temperatures or heatsink requirements; the tabs are live drains.

## Remaining physical acceptance

- Qualify the actual cables, 480 Mbps hub connection, both touch controllers, USB suspend/wake/reconnect, hot relay restart, and signal integrity.
- Measure screen current, voltage drop, inrush, fuse coordination and component temperature; verify the existing power harness and enclosure clearances.
- Check HDMI residual power and complete screen darkness with all cables attached.
- Implement and validate early GPIO enable and power-off before HDMI shutdown, using the measured screen discharge time.

The project remains `autonomy:blocked-verify`. [Assembly and connector map](../../../hardware/kicad/screen_power/README.md) is the wiring authority. [Independent reviews](review.md) cover the final local change; they do not certify hardware performance.
