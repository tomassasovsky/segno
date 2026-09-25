<!-- cspell:words smoothstep -->
# Segno console board v2 — Pico 2 firmware

The console's pedal firmware: `console_board.ino` on the board's Pico 2 (RP2350,
`hardware/kicad/console_board.py`, #747). A pure thin client, like the pedal it
replaces — it holds no looper state. It sends raw footswitch and encoder events
to segno over the link and renders the encoder ring and all ten eight-LED pills from
the state frames segno pushes back. segno runs the behavior machine.

| Signal | GPIO | Notes |
|---|---|---|
| Link TX / RX | GP16 / GP17 | UART0 → Pi uart3 (GPIO8/9, `/dev/ttyAMA3`), 115200 8N1 |
| Footswitches | GP2–GP11 | REC/PLAY, STOP, UNDO, MODE, TRACK1–4, CLEAR, BANK. Internal pull-up, active low, 8 ms stable-edge debounce |
| Ring data | GP12 | **v2 only**: via 74AHCT125 → J6 pin 5, one continuous 40-pixel GRB WS2812B strip. On v3 (#987) the ring board clocks its own LEDs and GP12 is on the expansion header |
| Encoder A / B / SW | GP13 / GP14 / GP15 | **v2 only**: internal pull-ups plus the board's 10 k to the Pi's 3V3; one message per detent, decoded from pin-change interrupts |
| Ring link | GP13 / GP14 | **v3** (#987): full-duplex UART to the ring board's XIAO RP2350 — GP13 drives, GP14 listens, 115200, PIO UART (neither pin is on a free hardware UART). The console board's 10 k pull-ups hold both lines. **Not implemented in this firmware yet**: it still drives GP12 and reads GP13–15 as an encoder, which is the v2 board |
| Indicator data | GP18 | via 74AHCT125 → J7 pin 2, **80 GRB WS2812B pixels**, eight per pill; PIO/DMA output |
| CTRL1 / CTRL2 tip | GP26 / GP27 | ADC0 / ADC1: a footswitch at the rails, an expression pedal's wiper between them. The first press on a jack the board has not yet classified is held 200 ms (a plug sliding in drags the tip low the same way); once the jack is known to hold a footswitch, edges are debounced at 8 ms and sent at once |
| CTRL1 / CTRL2 ring | GP20 / GP21 | On v3 a trace from each jack's ring through 4.7 kΩ (R19/R20). **Not a trace on v2** — one wire from each jack's ring pin to the J22 expansion pads does the same. With it, the B switch of a two-switch pedal (a BOSS FS-6's A&B jack) reports as `CTRL n · footswitch B` (its first press on a jack the board has not yet seen a switch on is held 200 ms, so a plug brushing the contact cannot fake it); without it the pin's internal pull-up holds it open and nothing reports |
| CTRL1 / CTRL2 present | GP19 / GP22 | Internal pull-down, **present = low**. On v3 the switched jack's tip-normal contact (Neutrik NJ6FD-V, through 4.7 kΩ R21/R22) drives it high only while the jack is empty; an empty jack reports CTRL kind `NONE` and is classified afresh on the next plug. On v2 these are J22's unpopulated pads: they float low, every jack reads "plugged", and the firmware's plug heuristics (a 40% jump starts a 200 ms quiet period; a jump that parks on the top rail for 1 s is an empty jack) do the same job less certainly |
| SMPS mode | GP23 | Driven high: PWM mode, less ADC ripple |
| PD trigger I2C | GP0 / GP1 | **v3** (J23): I2C0 SDA/SCL to the STUSB4500 on the SparkFun PD board, to read the negotiated contract (RDO 0x91–0x94, capability mismatch; voltage at 0x21) and report it up the pedal link. **Not implemented in this firmware yet.** On v2 the same read is possible from J22's GP20/GP21 when those pads are free |

## Wire format: the pedal link

Firmware 1.11 preserves REC/PLAY indication from loop activity, not from
the Rec/Mute/FX interaction mode or whole-performance recording arm state:

| Loop state | REC/PLAY pill |
| --- | --- |
| Empty and ready | Green breathing, one-second cycle |
| Recording | Steady red |
| Overdubbing, or recording while another loop plays | Steady yellow |
| Playing | Steady green |
| Stopped with a loop loaded | Off |
| App disconnected or shutdown | Off |

All lit states keep the diffuser test's centre curve: approximately
15%, 36%, 79%, 100%, 100%, 79%, 36%, 15%, with a peak channel value of 191.
Breathing uses smoothstep between 15% and 100% of that peak. The 40-pixel ring
uses its own output budget; no second global dimmer or brightness gamma
is applied to the pill curve. Colour gamma retains the calibrated yellow hue.
All 80 fitted pixels are addressed. The data-chain order is TRACK4, TRACK3,
TRACK2, TRACK1, MODE, UNDO, STOP, REC/PLAY, CLEAR, BANK. The first eight pills
enter from their right end; CLEAR/BANK enter from their left. The four track
pills show the app's corresponding active-bank colors. MODE is red for Record,
green for Mute and blue for FX. CLEAR lights red while the app reports it held;
BANK lights blue at the same brightness as the other pills for bank B and is dark for bank A. STOP lights red and
UNDO blue while their physical switches are held. Those two lights acknowledge
input, not a confirmed operation or undo availability, which the protocol does
not report. All pills go dark on shutdown or a stale app connection.

The full pill-chain channel sum is limited to 6000 out of the per-channel
0–255 scale. Under the conventional 20 mA per full channel model, this caps
pill color-channel current at approximately 471 mA. The 40-pixel ring's
11520-channel budget adds at most 904 mA. Adding an estimated 120 mA idle
allowance for all 120 LEDs and 140 mA of console logic gives about **1.635 A**,
below the old PCB's approximately 1.65 A track budget. These are conservative
planning estimates, not a measured current guarantee. The new wider-power-path
PCB has its own firmware and power budget.

The limiter preserves hue and the centre curve and only dims a crowded pattern
when needed. REC/PLAY alone retains the approved peak of 191. Recomputing from
the original frame every tick avoids repeated dimming and restores brightness
when other pills turn off. Normal footswitch, encoder and CTRL handling and
their existing pin assignments remain. NeoPixelBus PIO/DMA sends the longer
pill strip without masking interrupts for its 2.4 ms transfer. The ring stays
on the existing GP12 driver and completes one revolution every 1100 ms.

The sustained comet has two leading pixels at a physical channel output of 192,
followed by a gradual one-sided fade spanning 30 of the 40 pixels, head included.
It retains at least half brightness through the first 17 pixels. Fractional
circular interpolation keeps motion smooth across the last-to-first pixel.
Only hue receives gamma: applying gamma again to the physical output profile
would shorten the visible tail. Startup, volume arcs and idle breathing retain
their previous output at a peak of 96. Every transfer passes through the ring's
total-channel limit, preserving the existing combined current ceiling even
though the localized comet head is brighter. Stop still freezes the comet;
volume overlays restore that frozen position and colour afterwards.

In Song playback mode, the queued track's pill fills green from physical left
to right over the remainder of the current loop. Protocol 7 carries the app's
normalized progress; the firmware never advances or completes a queue using
its own clock. Progress stops short of a full pill until the app confirms the
transition. Cancellation restores the app's normal track color; another bank,
another mode, goodbye and link expiry cannot leave a stale queued fill.


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
| `0x10 STATE` | segno → board | 21 bytes: flags, mode, looper mode, global colour, bank, selected track, 8 track LEDs, loop length µs (LE32), master gain, queued track (0 = none, 1–8 = logical track + 1), queued progress (0–254) — see `pedal_link.h` |

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
Adafruit NeoPixel 1.15.5 and NeoPixelBus 2.8.4 libraries.

```sh
arduino-cli core install rp2040:rp2040 --additional-urls https://github.com/earlephilhower/arduino-pico/releases/download/global/package_rp2040_index.json
arduino-cli lib install "Adafruit NeoPixel@1.15.5" "NeoPixelBus by Makuna@2.8.4"
arduino-cli compile --fqbn rp2040:rp2040:rpipico2 firmware/console_board --output-dir firmware/console_board/build
```

`build/console_board.ino.elf` is what OpenOCD flashes; `.uf2` is for BOOTSEL drag-and-drop
if the module's USB is ever reachable (it is not, once the board is in the console).

## Flashing

The appliance does it. The image carries this firmware, an OpenOCD built for
the one adapter that reaches the board (`segno-openocd`), and a marker naming
the firmware version and link protocol the app expects; a oneshot before
`segno.service` listens for the board's `HELLO` and reprograms it over SWD only
when it is not already running what shipped (#989). So the two halves of a
build cannot ship out of step, and a board is repaired by a reboot rather than
by a laptop.

The board routes the Pi's GPIO24 (SWCLK, ribbon pin 18) and GPIO25 (SWDIO, pin
22) straight to the module's debug pads, so the Pi is the programmer. SWDIO
needs a pull-up the Pi firmware does not apply by default — `gpio=25=pu` in
`config.txt`, which the image sets.

To flash by hand during bring-up, on the unit:

```sh
segno-openocd -f /usr/lib/segno/console-board/pi5-swd.cfg \
  -c "program /usr/lib/segno/console-board/console_board.elf verify reset exit"
```

Point `program` at your own build to try a change; the next boot puts the
shipped firmware back, which is the intended behaviour — the image is the
source of truth for what the board runs.

## Talk to it from the Pi

With `dtoverlay=uart3-pi5` in place the link is `/dev/ttyAMA3` and segno opens it
itself (`UartPedalLink` in `packages/pedal_repository`). For a bench check
without the app, watch the hellos arrive:

```sh
stty -F /dev/ttyAMA3 115200 raw -echo
od -An -tx1 -w7 -v /dev/ttyAMA3    # a5 03 03 07 01 0b 0d (HELLO, protocol 7, fw 1.11), once a second
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
