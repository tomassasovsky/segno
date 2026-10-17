<!-- cspell:words Seeed CCITT BOOTSEL TBYB picotool bootrom -->
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
  colour (RGB, black when none), the master level, and four flags — LIVE (the
  app is connected), ACTIVE (the transport is doing something), LOADED (a
  loop exists) and DIMMED (the console idled and the screens dimmed, #1349). The ring goes dark if no valid STATE arrives for 500 ms.
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
  scaled uniformly.
- **Dimmed**: while DIMMED is set, every push drops to about 20 % (51/255) after
  the budget, whatever the view, and at once on a still frame. A lit channel
  stays at least 1, so the dimmed breathe never reaches black. LED output is PIO/DMA (NeoPixelBus), so the link and
  encoder interrupts keep running during a push.

## Encoder

ACZ11BR1E-20FD1-20C, 20 detents: clockwise is `11 → 01 → 00 → 10 → 11` with A as
the high bit, viewed from the shaft. Each complete cycle counts one click; reverse
transitions from contact bounce cancel their forward steps and an invalid two-bit
jump resets the cycle. The push switch is debounced for 8 ms.

## Build

```sh
arduino-cli compile --libraries firmware/libraries --fqbn rp2040:rp2040:seeed_xiao_rp2350 firmware/ring_board --output-dir firmware/ring_board/build
python3 -I firmware/ring_board/seal.py firmware/ring_board/build/ring_board.ino.bin firmware/ring_board/build/sealed
```

`seal.py` uses the picotool that ships with the arduino-pico core and writes:

| File | For |
| --- | --- |
| `partition_table.uf2` | the one USB install: `partition_table.json`, partitions A and B of 512 KB each, linked as an A/B pair |
| `ring_board.uf2` | the one USB install: this build, hashed and versioned |
| `ring_board.bin` | updates over the console: the same build, hashed, versioned and flagged try-before-you-buy |
| `version` | `firmware=M.m size=N sha256=HEX`, the marker the appliance's flasher reads |

The version is `FW_MAJOR`/`FW_MINOR` in `ring_board.ino`. **Bump it with every
change**: the appliance updates a ring whose version differs from the image's,
in either direction. A downgrade sticks: the version is sealed into the image,
and when the bootrom tries a lower version than the other partition holds, the
confirmation erases the higher one, so an appliance rolled back to an older
image puts the ring back on that image's firmware.

## First install, over USB, once per carrier

The console cannot program a XIAO that has no updater or no partition table,
so each carrier is installed over USB once:

1. Turn AUX off, unplug J1 and keep the strip unpowered.
2. Hold the XIAO's BOOT button while plugging its USB-C into a computer.
3. Copy `partition_table.uf2` onto the `RP2350` drive. With no image to boot
   yet, the drive comes back; if it does not, hold BOOT and reconnect.
4. Copy `ring_board.uf2` onto the drive. The bootrom writes it into partition A
   and boots it.
5. Unplug USB before reconnecting J1 and restoring AUX: D1 stops USB from
   feeding the AUX harness, but nothing stops live AUX from reaching the
   computer.

The USB image is sealed **without** try-before-you-buy on purpose: a TBYB image
boots only from a flash-update boot and then needs the Pi's confirmation, so a
drag-and-drop TBYB install would run once and never boot again.

## Updates over the console

After that, the appliance keeps the ring current (#1342). The image ships
`ring_board.bin` and `version` under `/usr/lib/segno/ring-board/`;
`segno-ring-flash` runs at boot, after `segno-console-flash` and before the
app, and talks to this board through the console's bridge
([console README](../console_board/README.md#ring-update-bridge-firmware-21)).
The protocol is `firmware/libraries/SegnoRing/src/ring_update.h`, on the same
UART as the ring link with its own channel byte, so neither interferes with
the other and the update protocol never moves with the ring-link version.

1. QUERY → HELLO: firmware version, update protocol, and whether this boot is
   on trial or flash has no partition table. A current ring ends the session
   here, in well under a second.
2. BEGIN (size, SHA-256): the board picks the partition it is not running from
   and erases that partition's first sector at once. The bootrom finds an
   image through the block loop in that sector, so an abandoned transfer can
   never boot.
3. DATA, 1 KB at a time, each acknowledged after it is written (stop and wait:
   the XIAO runs from the flash it writes, so nothing may arrive mid-erase).
   The first 4 KB are kept in RAM. A repeated chunk (a lost ACK) is
   acknowledged again without being written twice.
4. COMMIT: if the SHA-256 of everything received matches BEGIN's, the board
   writes the first sector, acknowledges, and reboots with the bootrom's
   flash-update boot into the new partition.
5. The bootrom checks the image hash and runs it **on trial** under a 16.7 s
   watchdog. The Pi hears its HELLO (proving the new image can talk through
   the console) and sends CONFIRM; the board calls `explicit_buy()`, and only
   then does the new image become the one that boots.

Anything short of that leaves the previous firmware booting: power cut or
unplugged J1 mid-transfer, a wrong digest, a hash the bootrom rejects, or a
new image that never answers. `segno-ring-flash` exits 0 whatever happens,
retries on the next boot, and stops after three failed attempts at one
version, so an image the ring rejects does not slow every boot. A transfer cut
by the line counts too; to retry a held version, remove
`/data/segno/ring-board/attempts` (the journal says so). A ring that does not
answer at all (its USB install not done yet, a console without the bridge, or
no ring) is recorded in `/data/segno/ring-board/silent` for that image's ring
version, and later boots of the same image skip the 1.5 s wait. A new image
asks again; after the USB install on an unchanged image, remove that file. An update
takes about ten seconds at 115200 baud.

`firmware/test/test_ring_board.cpp` runs this sketch on the host: the comet
profile and output, breathe, arc, freeze, budget, dimming, link timeout and the input
snapshots. `firmware/test/test_ring_update.cpp` runs updates end to end, the
Pi's engine against this sketch on simulated flash and bootrom. Encoder feel,
UART noise immunity, LED timing and the bootrom's own trial and revert still
need the assembled board.
