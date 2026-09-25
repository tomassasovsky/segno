# New-v3 runtime preservation — #1081

This draft preserves the new console/ring implementation from the hardware
workspace. It is separate from the old console firmware installed on the pedal.
The new hardware uses a Pico 2 console and XIAO RP2350 ring/encoder controller;
its UART and GPIO assignments must not be replaced with the old board's map.

The source includes a shared panel library, 80 indicator pixels, 40-pixel ring,
CTRL switched-jack presence, read-only PD reports, protocol 7 and both-target
release builds. The console forwards render state and receives encoder/button
state over the independent ring link; corrupt or stale packets cannot keep LEDs
lit. The carrier J2 wire pads can connect the external strip. Its power behavior
at the selected LED count still needs qualification on the assembled hardware.

## Dependencies and reconciliation

Hardware PR #1080 supplies the board designs and GPIO17 screen-power lifecycle.
Current-old-board PR #1079 owns the final common Song queue, engine and app
behavior. This draft preserves its earlier intertwined implementation so it is
not lost; it is not a second independent implementation intended to merge as-is.
Reconcile the common app/engine/protocol changes with the final reviewed #1079
head, retaining only the new-v3 hardware-specific changes and PD diagnostics.
The sustained ring-fade tuning currently installed on the old console also
needs an explicit decision and port before claiming equivalent new-v3 behavior.

## Observed checks

- Fresh firmware host runner: eight suites pass and all 58 C/Dart fixtures match.
- Both actual MCU targets compile: Pico 2 uses 71,272 bytes of flash and
  11,172 bytes of RAM; XIAO RP2350 uses 64,024 bytes of flash and 10,812 bytes
  of RAM. No binary was deployed.
- Pinned installed toolchain: arduino-pico 6.0.0, Adafruit NeoPixel 1.15.5,
  NeoPixelBus 2.8.4.
- Historical local implementation and review reports remain under
  `docs/reviews/pcb-completion-1072/` and `docs/reviews/song-pill-completion-1077/`.
  They do not establish current-head review or CI for this draft.

The full common runtime validation and current-head independent review will be
repeated after reconciliation, rather than treating historical results as a
release gate. No new-v3 image or firmware was deployed. Keep this PR draft and
`autonomy:blocked-verify` until the common runtime is reconciled, CI/review pass,
and assembled new-board controls, ring and shutdown behavior are verified.
