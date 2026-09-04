# Segno console board v2 — Pico 2 firmware

The console's pedal firmware: `console_board.ino` on the board's Pico 2 (RP2350,
`hardware/kicad/console_board.py`, #747). A pure thin client, like the pedal it
replaces — it holds no looper state. It sends raw footswitch and encoder events
to segno over the link and renders the encoder ring and the indicator pills from
the state frames segno pushes back. segno runs the behavior machine.

| Signal | GPIO | Notes |
|---|---|---|
| Link TX / RX | GP16 / GP17 | UART0 → Pi uart3 (GPIO8/9, `/dev/ttyAMA3`), 115200 8N1 |
| Footswitches | GP2–GP11 | REC/PLAY, STOP, UNDO, MODE, TRACK1–4, CLEAR, BANK. Internal pull-up, active low, 8 ms stable-edge debounce |
| Ring data | GP12 | via 74AHCT125 → J6 pin 5, NeoPixel Ring 24 |
| Encoder A / B / SW | GP13 / GP14 / GP15 | Internal pull-ups plus the board's 10 k to the Pi's 3V3; one message per detent, decoded from pin-change interrupts |
| Indicator data | GP18 | via 74AHCT125 → J7 pin 2, **seven** WS2812 pucks in chain order: MODE (above footswitch 1), TRACK1–4, CLEAR, BANK |
| CTRL1 / CTRL2 tip | GP26 / GP27 | ADC0 / ADC1: a footswitch at the rails, an expression pedal's wiper between them |
| CTRL1 / CTRL2 ring | GP20 / GP21 | **not a trace on v2** — one wire from each jack's ring pin to the J22 expansion pads. With it, the B switch of a two-switch pedal (a BOSS FS-6's A&B jack) reports as `CTRL n · footswitch B`; without it the pin's internal pull-up holds it open and nothing reports |
| SMPS mode | GP23 | Driven high: PWM mode, less ADC ripple |

## Wire format: the pedal link

`pedal_link.h` / `pedal_link.c` is the whole protocol, plain C99, and it is
mirrored byte for byte by `PedalLinkCodec` in `packages/pedal_repository`. Every
message is one frame: `A5 <type> <len> <payload> <xor>`, where `xor` covers
type, length and payload. Plain 8-bit bytes — no MIDI, no 7-bit packing, no
version byte on the state frame; `HELLO` carries the protocol version so a
mismatched build shows up in segno's log.

| Type | Direction | Payload |
|---|---|---|
| `0x01 BUTTON` | board → segno | `button (0–9), pressed (0/1)` |
| `0x02 ENCODER` | board → segno | `int8 detents` (positive = clockwise) |
| `0x03 HELLO` | board → segno | `protocol, fw major, fw minor` — at boot and once a second; segno counts the board as connected while these keep coming |
| `0x10 STATE` | segno → board | 19 bytes: flags, mode, looper mode, global colour, bank, selected track, 8 track LEDs, loop length µs (LE32), master gain — see `pedal_link.h` |

segno answers every `HELLO` with its current `STATE`, so a board that just
(re)connected is current within a second; the board goes dark if no `STATE`
arrives for `PEDAL_LINK_FRAME_TIMEOUT_MS` (5 s) and on the goodbye flag, and
segno reads the board as disconnected after three silent hello intervals. Both
cadences live in `pedal_link.h`; the package's header test pins them. Frames the parser drops (bad type,
length or checksum) are counted on both ends; segno logs the count.

**Contract test.** `packages/pedal_repository` generates golden frames
(`test/fixtures/*.bin`) from the Dart codec; `firmware/test/run_tests.sh` decodes
and re-encodes every one with this C unit. Run it after touching either side:

```sh
bash firmware/test/run_tests.sh
# after changing the golden frames:
(cd packages/pedal_repository && flutter test tool/generate_golden_fixtures.dart)
```

## Build

Needs `arduino-cli`, the arduino-pico core (`rp2040:rp2040`, RP2350 support) and
the `Adafruit NeoPixel` library.

```sh
arduino-cli core install rp2040:rp2040 --additional-urls https://github.com/earlephilhower/arduino-pico/releases/download/global/package_rp2040_index.json
arduino-cli lib install "Adafruit NeoPixel"
arduino-cli compile --fqbn rp2040:rp2040:rpipico2 firmware/console_board --output-dir firmware/console_board/build
```

`build/console_board.ino.elf` is what OpenOCD flashes; `.uf2` is for BOOTSEL drag-and-drop
if the module's USB is ever reachable (it is not, once the board is in the console).

## Flash from the Pi over SWD

The board routes the Pi's GPIO24 (SWCLK, ribbon pin 18) and GPIO25 (SWDIO, pin 22)
straight to the module's debug pads, so the Pi is the programmer. This needs an
OpenOCD that knows the RP2350 and can bit-bang SWD through the Pi 5's RP1 GPIO
(`linuxgpiod`). Raspberry Pi ships one as a flat tarball (binary, `scripts/`, and
its own `libgpiod.so.2`). It also wants `libftdi1.so.2` and `libhidapi-hidraw.so.0`,
which the appliance image does not carry; the Debian arm64 packages `libftdi1-2`
and `libhidapi-hidraw0` drop in beside the binary (extract the `.deb` with `ar x`
and `tar xf data.tar.xz`, copy the two `.so.*` files and their symlinks). Put it
all under `/data/bringup/openocd` on the unit (`/data` is the persistent partition):

```sh
# on the Pi (the appliance is root@<ip>, key login)
mkdir -p /data/bringup/openocd && cd /data/bringup
curl -LO https://github.com/raspberrypi/pico-sdk-tools/releases/download/v2.3.0-1/openocd-0.12.0+dev-aarch64-lin.tar.gz
tar xzf openocd-0.12.0+dev-aarch64-lin.tar.gz -C openocd
# + libftdi1.so.2* and libhidapi-hidraw.so.0* into openocd/
LD_LIBRARY_PATH=openocd openocd/openocd --version
```

The image config now carries `dtoverlay=uart3-pi5` and `gpio=25=pu`
(`deploy/yocto/kas-segno-rpi5.yml`, `rpi5-console-board`). On a unit built before
that, both can be applied at runtime without a reboot: the firmware partition
holds the overlays, and `pinctrl` sets the pull.

```sh
mkdir -p /mnt/fw && mount -o ro /dev/nvme0n1p2 /mnt/fw      # the active firmware slot (rauc status)
dtoverlay -d /mnt/fw/overlays uart3-pi5                     # -> /dev/ttyAMA3
pinctrl set 25 pu                                           # SWDIO idle high; the Pi defaults it to pull-down
echo performance > /sys/module/pcie_aspm/parameters/policy  # else the first SWD pulses clock at 20 MHz
```

Then, with the console board powered from BUCK_AUX and the ribbon on:

```sh
cd /data/bringup
LD_LIBRARY_PATH=openocd openocd/openocd -s openocd/scripts -f pi5-swd.cfg \
  -c "program console_board.ino.elf verify reset exit"
```

`pi5-swd.cfg` (in this directory) sources Raspberry Pi's `raspberrypi5-gpiod.cfg`,
which locates the RP1 gpiochip from the device tree, and moves SWCLK/SWDIO to
GPIO24/25. The Pico's green LED blinks at 1 Hz once the firmware runs.

## Talk to it from the Pi

With `dtoverlay=uart3-pi5` in place the link is `/dev/ttyAMA3` and segno opens it
itself (`UartPedalLink` in `packages/pedal_repository`). For a bench check
without the app, watch the hellos arrive:

```sh
stty -F /dev/ttyAMA3 115200 raw -echo
od -An -tx1 -w7 -v /dev/ttyAMA3    # a5 03 03 02 01 00 03 (HELLO, protocol 2, fw 1.0), once a second
```

## Bring-up record

**2026-09-03, first unit.** Flashed over SWD from the appliance image (kernel 6.18,
RP1 = `gpiochip0`); OpenOCD found both Cortex-M33 cores, programmed and verified
the ELF, and the board came up on `/dev/ttyAMA3` at the first try. Verified on the
bench: all ten footswitches (clean DOWN/UP, correct order), encoder button, encoder
rotation (one message per detent, sign fixed so clockwise counts up), Ring 24 lap
in three colours and solid fill via J6, CTRL1/CTRL2 reading full scale through their
pull-ups with nothing plugged in — all with the bring-up text console this
firmware started as. Not yet exercised: indicator chain on J7 (no pucks
fitted), MIDI in/out (Pi side), CTRL jacks with a pedal, and the pedal-link
firmware itself against the app.
