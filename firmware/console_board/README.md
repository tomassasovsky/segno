# Segno console board v3 — Pico 2 firmware

The console's pedal firmware: `console_board.ino` on the board's Pico 2 (RP2350,
`hardware/kicad/console_board.py`, #1072). A pure thin client, like the pedal it
replaces — it holds no looper state. It sends raw footswitch, encoder and CTRL
events to segno over the link, renders all ten eight-pixel indicator pills from
the state frames segno pushes back, and forwards what the LED ring needs to the
ring carrier's XIAO ([`firmware/ring_board`](../ring_board/README.md)), which
runs the encoder and the ring. segno runs the behavior machine.

| Signal | GPIO | Notes |
|---|---|---|
| Link TX / RX | GP16 / GP17 | UART0 → Pi uart3 (GPIO8/9, `/dev/ttyAMA3`), 115200 8N1 |
| Footswitches | GP2–GP11 | REC/PLAY, STOP, UNDO, MODE, TRACK1–4, CLEAR, BANK. Internal pull-up, active low, 8 ms stable-edge debounce |
| Ring link | GP13 / GP14 | J6 pins 3/4: PIO UART to the ring carrier's XIAO RP2350, 115200 — GP13 drives, GP14 listens. R11/R12 pull both lines up to the Pico's own 3V3, so the link idles high while the Pi is off. Private protocol: `firmware/libraries/SegnoRing/src/ring_link.h` |
| Indicator data | GP18 | via 74AHCT125 → J24 (`PILLS`) pin 2, **80** GRB WS2812 pixels, eight per pill, sent with PIO/DMA |
| CTRL1 / CTRL2 tip | GP26 / GP27 | ADC0 / ADC1: a footswitch at the rails, an expression pedal's wiper between them. The first press on a jack the board has not yet classified is held 200 ms (a plug sliding in drags the tip low the same way); once the jack is known to hold a footswitch, edges are debounced at 8 ms and sent at once |
| CTRL1 / CTRL2 ring | GP20 / GP21 | Each jack's ring through 4.7 kΩ (R19/R20). The B switch of a two-switch pedal (a BOSS FS-6's A&B jack) reports as `CTRL n · footswitch B`; its first press on a jack the board has not yet seen a switch on is held 200 ms, so a plug brushing the contact cannot fake it |
| CTRL1 / CTRL2 present | GP19 / GP22 | The Neutrik NJ6FD-V's ring-normal contact through 4.7 kΩ (R21/R22): high only while the jack is empty, **present = low** against the internal pull-down. Read through `console_presence.h`, which keeps the pad's input buffer off between samples (RP2350-E9). An empty jack reports CTRL kind `NONE` and is classified afresh on the next plug |
| SMPS mode | GP23 | Driven high: PWM mode, less ADC ripple |
| PD trigger I2C | GP0 / GP1 | J23: I2C0, 100 kHz, to the STUSB4500 on the SparkFun PD board (its own pull-ups). Provisioned at boot and read once a second: see [PD trigger](#pd-trigger-firmware-23) |

## The ring carrier

The encoder and its 35-pixel LED ring are on the ring carrier, run by its own
XIAO. Over the ring link the Pico sends a five-byte ring state derived from each
app frame — the activity colour, the master level, and whether the app is live,
the transport active, a loop loaded and the LEDs dimmed — at once on every frame and every
100 ms otherwise. The XIAO sends cumulative encoder and button counters every
20 ms; the Pico turns them into one `ENCODER` frame per click and one
`ENCODER_BUTTON` frame per edge, exactly what the v2 board sent from its own
pins. A rebooted or silent XIAO replays no turns and releases a held button.
Because the ring never sees pedal-link frames, a pedal-link protocol change
does not need the XIAO reflashed.

### Ring-update bridge (firmware 2.1)

The XIAO has no SWD path, so the Pi updates it through this board (#1342).
`segno-ring-flash` runs after the console flash and before the app, and sends
`RING_BRIDGE` (pedal-link type `0x12`, payload `'R' 'B'`); the app never sends
it. The board then darkens the pills, stops its own HELLO and ring state, and
copies every byte between the Pi's UART and the ring's in both directions. It
leaves the bridge on the Pi's `BRIDGE_END` update frame, which it spots in the
Pi's stream (the ring ignores it), or after 5 s without a byte from the Pi,
and carries on as before. The update itself is the ring's; see
[its README](../ring_board/README.md#updates-over-the-console).

### Dimming with the screens (firmware 2.2)

When the console idles and the app dims the screens, the app sets STATE flags
bit 4 (`dimmed`, pedal-link protocol 11, #1349) until the next touch, key,
footswitch or playback wakes them. The board then shows the pills at about
20 % (`ring_link::DIM_LEVEL`, 51/255, applied after the channel budget) and
sets the ring state's DIMMED flag, so ring firmware 1.1 and later dim the ring
by the same share.

### PD trigger (firmware 2.3)

The STUSB4500 negotiates the 20 V supply by itself, from the profile in its
NVM, each time it powers up (#1352). `pd_trigger.c` makes that profile the
console's and reports what was negotiated:

- **At boot**, before the link starts, the board reads the NVM. If any profile
  field differs, it erases and programs the NVM with what it read plus the
  profile, then reads it back and compares it. It writes nothing on a trigger that
  already matches, so the NVM is written once per trigger. The profile:
  PDO1 5 V / 0.5 A, PDO2 20 V / 3 A, PDO3 20 V / 5 A, three PDOs,
  `REQ_SRC_CURRENT` (once a PDO matches, request all the current the source
  offers at that voltage), power only above 5 V, no external power, no USB
  comms. Every other NVM field is left as the trigger had it.
- **After every HELLO** it sends `PD_STATUS` (protocol 12): the profile state
  (not read, matches, written, write failed) and the live contract from the
  chip's RDO and negotiated-voltage register.

A profile written at boot governs the next negotiation, which happens only
when the trigger loses power (the console is unplugged). Until then the
contract takes less than the source offers, and the app asks for a power
cycle: a banner on the stage, and a line on the Safe to switch off face.

A trigger that does not answer is asked again every tenth `HELLO`, and is
provisioned when it does (J23 seated after boot). The write is ST's full-erase
sequence, the one SparkFun's library proved: all five sectors erased and
programmed back. A power cut in that second can leave a trigger that no longer
powers the console; `hardware/console/stusb4500_pdo` reprograms it from an
Arduino UNO.

`firmware/test/test_pd_trigger.cpp` runs the driver against a simulated
STUSB4500, NVM controller included (`firmware/test/stusb4500_sim.h`).

## Physical rendering and source boundary

Firmware 2.0 is the v3 board on public UART protocol 10, unchanged from
firmware 1.14 (the v2 board, which rendered the ring itself on GP12 and read
the encoder on GP13–15). Update this firmware and its matching app together;
no downgrade or compatibility format is emitted.

The fitted chain order is Track4, Track3, Track2, Track1, Mode, Undo, Stop,
Record/Play, Clear, Bank. The first eight groups enter from the right;
Clear/Bank enter from the left. Button IDs on the wire keep their existing
Record/Play, Stop, Undo, Mode, Track1–4, Clear, Bank order.

The app supplies every pill's active bit and RGB hue. Inactive means dark;
local switch contact, legacy track colors and mode do not override that fact.
Optical output retains the sourced peak 191, center weights
38/92/201/255/255/201/92/38, color gamma and total channel budget 6000.
The limiter recomputes from the source frame so refreshes do not progressively
dim the display. NeoPixelBus PIO/DMA preserves interrupts during the
80-pixel transfer. Forced refresh, goodbye and stale-link darkening cover the
whole chain. RGB black is a valid deliberately dark hue.

**Song queue (#1077).** While a Song section waits for the playing one's next
lap edge, STATE byte 51 names the footswitch whose pill shows it and byte 52
how much of the wait has played (0..254 of 255). The board fills that pill
left to right in the hue and activity the app gave it; nothing local advances
the fill, and a queue never lights the whole pill. The engine ends the wait by
starting the section, and the next frame carries no queue
([plan](../../docs/plan/2026-09-24-feat-song-pill-completion-plan.md),
[simulation](../../docs/simulations/song-pill-completion.html)).

No physical deployment or electrical/optical validation is implied by the host
tests or a successful Arduino compile.

## Wire format: the pedal link

`pedal_link.h` / `pedal_link.c` is the whole protocol, plain C99, and it is
mirrored byte for byte by `PedalLinkCodec` in `packages/pedal_repository`. Every
message is one frame: `A5 <type> <len> <payload> <xor>`, where `xor` covers
type, length and payload. Plain 8-bit bytes — no MIDI, no 7-bit packing, no
version byte on the state frame; `HELLO` carries the protocol version so a
mismatched build shows up in segno's log and cannot exchange control/state.
STATE bytes 0–18 retain their current meanings; bytes 19–48 hold ten RGB
triples, bytes 49–50 hold the physical activity mask (bits 10–15 must be
zero), and bytes 51–52 the Song queue: the queued footswitch + 1 (0 none) and
its progress 0..254 (0 without one). The parser accepts exactly 53 bytes and preserves the last good frame
on malformed input. Logical track LEDs remain snapshot facts; they do not
compete with the ten-button mask for physical output.

| Type | Direction | Payload |
|---|---|---|
| `0x01 BUTTON` | board → segno | `button (0–9), pressed (0/1)` |
| `0x02 ENCODER` | board → segno | `int8 detents` (positive = clockwise) |
| `0x03 HELLO` | board → segno | `protocol, fw major, fw minor` — at boot and once a second; segno counts the board as connected while these keep coming |
| `0x04 CTRL` | board → segno | `jack, contact, kind, value` (unchanged four bytes) |
| `0x05 ENCODER_BUTTON` | board → segno | `pressed (0/1)` — the encoder's push switch, one message per debounced edge (protocol 9) |
| `0x06 PD_STATUS` | board → segno | `profile, mismatch, mV (LE16), mA (LE16), source max mA (LE16)` — after every `HELLO` (protocol 12) |
| `0x10 STATE` | segno → board | 53 bytes: flags, mode, looper mode, global colour, bank, selected track, 8 track LEDs, loop length µs (LE32), master gain, ten RGB triples, active mask (LE16), queued switch, queue progress — see `pedal_link.h` |

segno answers every compatible `HELLO` with its current `STATE`, so a board that just
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
`Adafruit NeoPixel@1.15.5` and `NeoPixelBus by Makuna@2.8.4`.

```sh
arduino-cli core install rp2040:rp2040 --additional-urls https://github.com/earlephilhower/arduino-pico/releases/download/global/package_rp2040_index.json
arduino-cli lib install "Adafruit NeoPixel@1.15.5" "NeoPixelBus by Makuna@2.8.4"
arduino-cli compile --libraries firmware/libraries --fqbn rp2040:rp2040:rpipico2 firmware/console_board --output-dir firmware/console_board/build
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
od -An -tx1 -w7 -v /dev/ttyAMA3    # a5 03 03 0c 02 03 0d (HELLO, protocol 12, fw 2.3), once a second
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
