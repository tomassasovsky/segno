# Ten-pill wiring diagnostic

Temporary Pico 2 firmware for the existing console PCB: 80 WS2812 pixels on
GP18, with the old 24-pixel encoder ring on GP12 held dark. This is a bench
instrument, not a replacement console firmware or a v2 mode in v3 firmware.

The input chain is TRACK4, TRACK3, TRACK2, TRACK1, MODE, UNDO, STOP, REC/PLAY,
CLEAR, BANK. The first eight pills receive data from their right end; the final
two receive it from their left end. Each contains eight LEDs.

It boots dark. The UART command `chain run` starts two 50-second passes.
Each pill gets one second red, one second green, one second blue, a green
left-to-right chase, and a short dark gap. Only one pill and one color channel
are illuminated at a time, capped at 32/255. At the conservative 20 mA per
channel estimate, the maximum added LED load is about 20 mA, plus the idle
current of already-connected pixels. This is a continuity/color/order test,
not a full-load power test. No full-brightness command exists.

It returns to dark after 100 seconds without requiring host communication.
`chain off` or the physical STOP switch blanks it immediately. Repeated run
commands while active do not extend the deadline. Normal console input handling
is unavailable during the diagnostic.

Build with the installed arduino-pico and Adafruit NeoPixel libraries:

```sh
arduino-cli compile --fqbn rp2040:rp2040:rpipico2 \
  firmware/pill_chain_test --output-dir /tmp/segno-pill-chain-build
```

Before flashing, preserve and hash the appliance's **currently installed** ELF
and version marker; do not substitute firmware from a different checkout.
Stop `segno.service` to release its UART. Leave the shipped firmware files
untouched. Use the appliance's existing SWD configuration for both the test
and restoration, verify programming, and configure an independent timed
restore before starting. Restore the preserved ELF after the test, restart
the app, and confirm its reported controller version matches the original.
UART is 115200 baud on `/dev/ttyAMA3` with newline-terminated commands.

Telemetry proves which pattern was sent, not that a physical LED lit. The owner
must observe all ten pills, colors, and chase direction to confirm the harness.
