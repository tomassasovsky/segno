<!-- cspell:words Seeed CCITT -->
# Segno ring carrier — XIAO RP2350 firmware

`ring_board.ino` runs the ring carrier's XIAO RP2350 (`hardware/kicad/ring_board.py`,
#987): the Same Sky ACZ11 encoder and the 35-pixel console strip ring (#1090).
It renders a five-byte ring state the console board's Pico sends over the
private ring link and reports cumulative encoder and button counters back. It
never sees the app's pedal-link frames, so a pedal-link protocol change does
not need it reflashed.

| Function | XIAO pad | RP2350 GPIO |
| --- | --- | --- |
| Ring data, through the 74AHCT125 to J2 pin 3 | D0 | GP26 |
| Encoder A | D1 | GP27 |
| Encoder B | D2 | GP28 |
| Encoder switch | D3 | GP5 |
| Receive from console GP13 (J1 pin 3) | D9 | GP4 |
| Transmit to console GP14 (J1 pin 4) | D10 | GP3 |

## Ring link

`firmware/libraries/SegnoRing/src/ring_link.h`, shared with the console: SLIP
framing, CRC-16/CCITT-FALSE, version 3, PIO UART at 115200 8N1.

- **STATE**, console to ring, on every app frame and every 100 ms: the activity
  colour (RGB, black when none), the master level, and three flags — LIVE (the
  app is connected), ACTIVE (the transport is doing something) and LOADED (a
  loop exists). The ring goes dark if no valid STATE arrives for 500 ms.
- **INPUT_STATE**, ring to console, every 20 ms: a boot nonce, the cumulative
  detent count and the cumulative button edge count (odd means pressed).
  Snapshots recover dropped short presses as well as missing clicks; the
  console turns them into the pedal link's `ENCODER` and `ENCODER_BUTTON`
  frames.

## Rendering

The approved console ring behaviour, now on this board:

- **Comet** in the activity colour while the transport is active, one turn every
  1100 ms. The owner-approved 40-pixel sustained-fade duty profile is resampled
  to the same angles on 35 pixels, with the two-pixel lead held at 192 and the
  last quarter dark. Only the hue gets gamma.
- **Frozen comet** in its last colour when stopped with a loop loaded.
- **Breathe** green at the ambient brightness (96) when live and idle; it never
  reaches black.
- **Gain arc** in the activity colour (or green) for 900 ms whenever the master
  level changes between two live states.
- Every push shares one channel budget, 35 × 3 × 96 = 10,080; a larger frame is
  scaled uniformly. LED output is PIO/DMA (NeoPixelBus), so the link and
  encoder interrupts keep running during a push.

## Encoder

ACZ11BR1E-20FD1-20C, 20 detents: clockwise is `11 → 01 → 00 → 10 → 11` with A as
the high bit, viewed from the shaft. Each complete cycle counts one click; reverse
transitions from contact bounce cancel their forward steps and an invalid two-bit
jump resets the cycle. The push switch is debounced for 8 ms.

## Build and install

```sh
arduino-cli compile --libraries firmware/libraries --fqbn rp2040:rp2040:seeed_xiao_rp2350 firmware/ring_board --output-dir firmware/ring_board/build
```

The console's SWD flasher does not reach this module. To install
`build/ring_board.ino.uf2`: turn AUX off, unplug J1 and keep the strip
unpowered, hold the XIAO's BOOT button while plugging its USB-C into a computer,
and copy the UF2 onto the `RP2350` drive. Unplug USB before reconnecting J1 and
restoring AUX: D1 stops USB from feeding the AUX harness, but nothing stops
live AUX from reaching the computer. The console and this board must both run
ring link version 3.

`firmware/test/test_ring_board.cpp` runs this sketch on the host: the comet
profile and output, breathe, arc, freeze, budget, link timeout and the input
snapshots. Encoder feel, UART noise immunity and LED timing still need the
assembled board.
