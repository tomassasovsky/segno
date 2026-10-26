# Firmware

Firmware for the two controller boards in the Segno console. Both are RP2350
boards programmed as Arduino sketches on the
[arduino-pico](https://github.com/earlephilhower/arduino-pico) core
(`rp2040:rp2040`), built with `arduino-cli`. Neither holds looper state: the
app on the Raspberry Pi runs the looper and sends the boards what to display.

The boards themselves are in [`../hardware`](../hardware/README.md).

| Folder | Runs on | Contents |
| --- | --- | --- |
| [`console_board`](console_board/README.md) | The console board's Raspberry Pi Pico 2 (RP2350) | Reads the ten footswitches and the two CTRL jacks, drives the indicator pills, configures the USB-C power-delivery trigger, and talks to the app over a UART (the pedal link). Also relays the ring carrier's encoder input to the app. |
| [`ring_board`](ring_board/README.md) | The ring carrier's XIAO RP2350 | Reads the encoder and its push switch and drives the LED ring, from state the console board sends over a private link. Includes an A/B updater so the appliance can update it through the console board. |
| `libraries/SegnoRing` | Both boards | The private link between the console board and the ring carrier: frame format (`ring_link.h`, `ring_frame.h`) and the update protocol (`ring_update.h`). Passed to `arduino-cli` with `--libraries firmware/libraries`. |
| `test` | The development machine | Host tests that compile the firmware sources with stub headers and run them without hardware. |

## Building and flashing

Each board's README has the exact `arduino-cli` commands and library versions.
In short, the console board compiles for the core's Pico 2 board and the ring
carrier for its XIAO RP2350 board. The ring carrier build is then sealed with
`ring_board/seal.py`, which produces the files for the first USB install and
for later updates.

On a working console you do not flash either board by hand. The
[`appliance-release`](../.github/workflows/appliance-release.yml) workflow
compiles the firmware for both boards, and the Yocto image carries the
results. At boot the appliance programs the console board over SWD from the
Pi's GPIO pins, then updates the ring carrier through the console board, each
only when the board is not already running the shipped version. The ring carrier needs one USB
install per board before that works. See
[console board flashing](console_board/README.md#flashing) and
[ring carrier first install](ring_board/README.md#first-install-over-usb-once-per-carrier).

## Tests

```sh
bash firmware/test/run_tests.sh
```

This builds and runs every host test with the system C and C++ compilers. It
includes the pedal link contract test: the console board's `pedal_link.c`
decodes and re-encodes the golden frames that `packages/pedal_repository`
generates from the app's Dart codec, so the two sides of the link cannot
drift apart. Run it after changing anything under `firmware/` or
`packages/pedal_repository`. It also runs the CTRL jack, indicator pill,
power-delivery trigger, ring link, ring rendering and ring update tests.

The [console board README](console_board/README.md#wire-format-the-pedal-link)
documents the pedal link's frame format.
