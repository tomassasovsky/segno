# Segno console board v3 — Pico 2 firmware

The console's pedal firmware: `console_board.ino` on the board's Pico 2 (RP2350,
[`hardware/kicad/console_board.py`](https://github.com/tomassasovsky/segno-hardware/blob/main/hardware/kicad/console_board.py)
in segno-hardware, #1072). A pure thin client, like the pedal it
replaces — it holds no looper state. It sends raw footswitch, encoder and CTRL
events to segno over the link, renders all ten eight-pixel indicator pills from
the state frames segno pushes back, and forwards what the LED ring needs to the
ring carrier's XIAO ([`firmware/ring_board`](../ring_board/README.md)), which
runs the encoder and the ring. segno runs the behavior machine.

| Signal | GPIO | Notes |
|---|---|---|
| Link TX / RX | GP16 / GP17 | UART0 → Pi uart3 (GPIO8/9, `/dev/ttyAMA3`), 115200 8N1 |
| Footswitches | GP2–GP4, GP12, GP6–GP11 | REC/PLAY (GP2), STOP (GP3), UNDO (GP4), MODE (GP12), TRACK1–4 (GP6–GP9), CLEAR (GP10), BANK (GP11). Internal pull-up, active low, 8 ms stable-edge debounce. MODE moved from GP5 in firmware 2.4 (#1388): GP5 died on the first unit, and the board design moves SW_MODE to GP12 too. GP5 is left unconfigured |
| Ring link | GP13 / GP14 | J6 pins 3/4: PIO UART to the ring carrier's XIAO RP2350, 115200 — GP13 drives, GP14 listens. R11/R12 pull both lines up to the Pico's own 3V3, so the link idles high while the Pi is off. Private protocol: `firmware/libraries/SegnoRing/src/ring_link.h` |
| Indicator data | GP18 | via 74AHCT125 → J24 (`PILLS`) pin 2, **80** GRB WS2812 pixels, eight per pill, sent with PIO/DMA |
| CTRL1 / CTRL2 tip | GP26 / GP27 | ADC0 / ADC1: a footswitch at the rails, an expression pedal's wiper between them. The first press on a jack the board has not yet classified is held 200 ms (a plug sliding in drags the tip low the same way); once the jack is known to hold a footswitch, edges are debounced at 8 ms and sent at once |
| CTRL1 / CTRL2 ring | GP20 / GP21 | Each jack's ring through 4.7 kΩ (R19/R20). The B switch of a two-switch pedal (a BOSS FS-6's A&B jack) reports as `CTRL n · footswitch B`; its first press on a jack the board has not yet seen a switch on is held 200 ms, so a plug brushing the contact cannot fake it |
| CTRL1 / CTRL2 present | GP19 / GP22 | The Neutrik NJ6FD-V's ring-normal contact through 4.7 kΩ (R21/R22): high only while the jack is empty, **present = low** against the internal pull-down. Read through `console_presence.h`, which keeps the pad's input buffer off between samples (RP2350-E9). An empty jack reports CTRL kind `NONE` and is classified afresh on the next plug |
| SMPS mode | GP23 | Driven high: PWM mode, less ADC ripple |
| Light sensor | GP28 | ADC2 on J22 pin 5, optional (#1564): a TEPT5600 phototransistor from J22's +3V3 (pin 1), its load resistor (2.2 kΩ as fitted) and 100 nF to ground (pin 6) at the J22 end of the lead. Nothing fitted reads as no sensor: see [Light sensor](#light-sensor-and-led-level-firmware-27) |
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
powers the console;
[`hardware/console/stusb4500_pdo`](https://github.com/tomassasovsky/segno-hardware/tree/main/hardware/console/stusb4500_pdo)
in segno-hardware reprograms it from an Arduino UNO.

`firmware/test/test_pd_trigger.cpp` runs the driver against a simulated
STUSB4500, NVM controller included (`firmware/test/stusb4500_sim.h`).

### Light sensor and LED level (firmware 2.7)

An optional light sensor on J22 lets the app set the LED brightness from the
room (#1564). The wiring is in segno-hardware's `hardware/segno_wiring.md`.
`ambient_light.c` is the board's half:

- **Reading.** GP28 is read every 10 ms (eight ADC conversions averaged) with
  the pad's pulls off. One second of readings is averaged, which takes out
  mains flicker and dimmer PWM. The board keeps the median of the last five
  seconds, so a hand, a shadow or a strobe hit shorter than about two seconds
  never reaches the level, then averages that with a time constant of about
  3 s. The reported level moves only when the average has moved a quarter of
  a doubling (about 19 %) from it, so light that hovers does not make the LEDs
  step back and forth. A real change lands in about 5 to 10 s.
- **Units.** `AMBIENT` carries the reading, not lux: `2^(level / 16)` ADC
  counts of 4095, 0 for one count or less, 190 at the top of the range
  (3700 counts, where the transistor runs out of headroom). Darkness is
  reported as 0 exactly, and while the sensor is at the top of its range the
  level is 190 exactly. The sensor's gain
  varies 9x between Vishay's bins and its lens is sanded flat, so the board
  does not guess it. The app calibrates against a dark and a bright reading the
  owner captures in Settings, and the load resistor can be swapped without
  touching this firmware.
- **No sensor.** Every 2 s the board switches the pad's pull-up on for one
  10 ms slot, then its pull-down for the next, and reads the pin in each. A
  pin that follows the pull-up into the top quarter of the scale and the
  pull-down into the bottom quarter has nothing on it; a fitted load holds it
  near its own reading. A pin that stays at ground with the pull-up
  on is shorted there and counts as no sensor too. The first verdict holds at
  once, and a change needs two probes in a row. With no sensor the board sends
  `AMBIENT` with sensor 0, and the app offers no automatic brightness.
- **No blanking.** The pills stay lit while the board reads. The sensor is
  flush in the plate looking straight up, and every pill, the ring and both
  screens are flush with or below the plate, at least 76 mm away, about
  90 degrees off its axis, so the console's own light reaches it only by
  reflection. The median, the slow average and the hysteresis take that up.
  If a bench shows the console's light moving the reading by more than the
  hysteresis, the sampling slot can blank the pills.

`LED_LEVEL` (`0x14`) is the app's answer: how bright the pills and the ring
are, 1..255 of full. The board scales every pill pixel by it after the channel
budget, together with the idle dim as one factor (`ring_link::outputLevel`),
rounding each pixel once so its hue holds: a lit pixel keeps its strongest
channel at 1 at least, and weak channels drop out rather than rising to match
it. It fades to a new level at 3 steps per 20 ms render (the whole range in
about 1.7 s), except while no frame is showing, when it takes the level at
once: the app sends the level before the `STATE` that answers a hello, so a
reconnect never lights full and fades down. The board sends the level to the
ring carrier as the ring link's `LEVEL` just before every ring state. Without a
`LED_LEVEL`, and again when the app's frames stop, it is 255: exactly what
firmware 2.6 showed. Both messages are optional (still protocol 12):
firmware 2.6 drops `LED_LEVEL` and an older app drops `AMBIENT`, each at the
type byte, cleanly even when a payload byte is the sync byte.

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

**Song queue (#1077, #1323).** While a Song or Band section waits for the
sounding one's end, STATE byte 51 names the footswitch whose pill shows it and
byte 52 how much of the wait has played (0..254 of 255). The board fills that
pill left to right in the hue and activity the app gave it. Since firmware
2.5, every filled pixel has one level (110, the mean of the diffused levels,
so a fully filled queued pill has the same total brightness as the diffused
curve) with no centre curve, and the leading pixel fills partially so the edge moves
smoothly. Nothing local advances the fill, and a queue never lights the whole
pill. The engine ends the wait by starting the section, and the next frame
carries no queue. A pill that leaves the queue and stays lit blends from its
last fill to the diffused curve over 300 ms; one that goes dark does so at
once. The board keeps no Song or bank logic: it reacts only to the queued
button the app sends. The wire is unchanged
([plan](../../docs/plan/2026-10-13-fix-song-band-one-section-plan.md)).

**Clear-track hold (#1534, firmware 2.6).** While a hold that clears a
track is pending (the Track Hold set to Clear track, or a Custom pedal whose
Hold is Clear or Clear all), the app sends `CLEAR_HOLD` (`0x13`) every 20 ms
with the held footswitch and how much of the long-press threshold has run
(0..254). The board draws red from both ends of that pill toward the centre
over whatever the pill shows, at the same uniform level as the Song queue
(110), with the leading pixel on each side partly filled so the edges move
smoothly. While the fill runs, the app colours the held pill with its own
state (green playing, red recording) instead of the pressed colour. On a pill
the app shows red (a recording track, or any state it colours red), the pill's own red drops to about a third
(`PILL_CLEAR_UNDER_RED`, 85 of 255) and the fill is drawn at full brightness
(`PILL_PEAK`) over it. A hold released early or cancelled (or one that can no
longer fire) gets a message with no footswitch, and the pill shows its normal
state again at once. A fill that no message refreshes for 500 ms is dropped
and forgotten, so a lost message cannot leave a pill red; a pill the app does
not light never fills, and goodbye and a lost link end the fill.

When the hold fires and the clear is accepted, the app sends 255 once (a
refused clear sends none). The board confirms the clear on its own clock,
on a pill it lights at that moment, each pill independently: the full red pill flashes
`PILL_CLEAR_FLASHES` (3) times, `PILL_CLEAR_FLASH_MS` (120 ms) on and as long
dark, about 0.7 s, and then shows what `STATE` says (the empty-track state).
The app's no-footswitch message, later `STATE` frames and the 500 ms stale
time do not cut the flash short; a new hold on that pill takes it over, and
goodbye and a lost link end it.

`CLEAR_HOLD` does not change the protocol version (still 12). Firmware 2.5 and
older reject the unknown type at its type byte and keep rendering `STATE`, so
an older board shows no fill and nothing wrong; a protocol bump would instead
make the app refuse those boards altogether. The two-byte payload keeps the
rejection clean: a progress byte equal to the sync byte has only the checksum
behind it, so the next frame starts in the type or length slot and is parsed.

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
| `0x07 AMBIENT` | board → segno | `sensor (0 none, 1 reading, 2 at the top of the range), level` — the reading, `2^(level / 16)` ADC counts; after every `HELLO`; optional, firmware 2.7 (#1564) |
| `0x10 STATE` | segno → board | 53 bytes: flags, mode, looper mode, global colour, bank, selected track, 8 track LEDs, loop length µs (LE32), master gain, ten RGB triples, active mask (LE16), queued switch, queue progress — see `pedal_link.h` |
| `0x13 CLEAR_HOLD` | segno → board | `button + 1 (0 none), progress 0..255` — every 20 ms while a clear-track hold runs (0..254), 255 once when it fires (the board flashes the pill); optional, firmware 2.6 (#1534) |
| `0x14 LED_LEVEL` | segno → board | `level 1..255` of full brightness, for the pills and the ring — when it changes and, once the app has set one, before the `STATE` that answers each `HELLO`; optional, firmware 2.7 (#1564) |

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
od -An -tx1 -w7 -v /dev/ttyAMA3    # a5 03 03 0c 02 07 09 (HELLO, protocol 12, fw 2.7), once a second
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
