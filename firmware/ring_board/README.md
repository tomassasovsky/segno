<!-- cspell:words Seeed CCITT -->
# Segno ring board — XIAO RP2350 firmware

The ring board owns its encoder and one 40-LED ring. It receives the console's current
state over PIO UART, renders the established comet/breathing/gain-arc animation,
and reports cumulative encoder and button input. Brightness remains 128/255.

| Function | XIAO pad | RP2350 GPIO |
| --- | --- | --- |
| Ring data, through AHCT125 | D0 | GP26 |
| Encoder A | D1 | GP27 |
| Encoder B | D2 | GP28 |
| Encoder switch | D3 | GP5 |
| Receive from console GP13 | D9 | GP4 |
| Transmit to console GP14 | D10 | GP3 |

These are the side-pad connections in `hardware/kicad/ring_board.py`, using
the Seeed board variant shipped with arduino-pico 6.0.0. The UART runs at
115200 8N1 with a 256-byte receive queue. PIO/DMA LED output leaves encoder
and UART interrupts enabled.

The private link uses SLIP framing, CRC-16/CCITT-FALSE and version 2.
The console sends the canonical 21-byte pedal state every 100ms, including
the queued-track progress used by the console's pills. The XIAO
starts dark and goes dark if no valid state arrives for 500ms. Valid goodbye
state also clears it. Frozen or dark pixels are refreshed every 250ms.
The ring keeps its 700ms revolution period and scales the comet and gain arc
across all 40 pixels. The queue does not change the ring animation.

At the existing brightness cap, 40 pixels have a conservative full-white
color-channel estimate of 1.21 A, before LED idle and controller current.
An uncapped 40-pixel ring has a 2.4 A color-channel estimate. Firmware support
does not qualify the earlier 24-pixel carrier's mounting pattern or copper for
that larger load; the chosen module and hardware must be checked separately.

Input snapshots arrive every 20ms and contain a boot nonce, a cumulative
32-bit detent count and a cumulative 32-bit button-edge count. Duplicate
snapshots do nothing; dropped snapshots do not lose turns or a short
press/release pair. The console baselines a reboot or a connection absent
for 500ms, releases any held button, and does not replay offline turns.
Implausible jumps reset the baseline instead of generating an event storm.
The button is debounced for 8ms. Its raw state and edge counters are available
on the console; no looper action is assigned to this previously unused button.

Install the dependencies and run the commands in the
[console README](../console_board/README.md). Build output is
`firmware/ring_board/build/ring_board.ino.uf2`; appliance-release CI also emits
it as the `segno-ring-board` artifact. Before mounting the XIAO in the enclosure,
enter its USB BOOTSEL mode and copy the UF2 to its boot volume. The console's
SWD flasher does not address the ring module. There is no requirement for the
ring USB cable during normal operation.

The host tests exercise the production sketch's rendering and input logic,
and the real XIAO target compiles. Encoder direction/detent behavior, UART
noise immunity and actual LED timing still require the assembled board.
