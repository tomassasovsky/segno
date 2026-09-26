<!-- cspell:words seeed -->
# Segno console board v3 — Pico 2 firmware

`console_board.ino` is the thin client for the current v3 PCB. It forwards
footswitch and encoder input to the Pi, drives ten indicator pills, forwards
ring state to the independent XIAO, and reports the PD controller's status.
Firmware 2.1 speaks pedal protocol 7. The v2 direct ring/encoder wiring is removed.

## Wiring

| Function | Pico GPIO | Board connection |
| --- | --- | --- |
| Footswitches | GP2–GP11 | REC/PLAY, STOP, UNDO, MODE, TRACK1–4, CLEAR, BANK; internal pull-up, active low |
| Pi link | GP16 TX / GP17 RX | Pi UART3, GPIO9 RX / GPIO8 TX, 115200 8N1 |
| Ring link | GP13 TX / GP14 RX | J6 pins 3/4, full-duplex PIO UART, 115200 8N1 |
| Indicator data | GP18 | J24 pin 2, through AHCT125; 80 WS2812 pixels |
| CTRL tip | GP26 / GP27 | ADC0/1; 10k pull-up to the Pico's own 3V3 |
| CTRL ring | GP20 / GP21 | Jack ring through 4.7k; dual-switch pedal second contact |
| CTRL presence | GP19 / GP22 | Tip-normal contact through 4.7k; high = empty |
| PD status | GP0 SDA / GP1 SCL | J23 to STUSB4500 at address 0x28, 100kHz |
| SMPS mode | GP23 | High for PWM mode |

GP12 and GP15 are expansion pins. Firmware does not drive them as a ring or
read them as an encoder.

The presence reader disables the RP2350 input buffer between samples, using
Raspberry Pi's E9 workaround for A2 silicon. The physical switched contact
now decides removal; a fast expression-pedal move to full toe cannot falsely
report an unplug. Each new plug gets a 200ms settling interval. Established
switches use 8ms stable-edge debounce, and presence uses 50ms debounce.

PD reads never change PDOs or the controller's NVM. Missing, negotiating,
invalid, mismatched and stale contracts have distinct status. Voltage remains
unknown because the published ST register map does not define a reliable
negotiated-voltage register. A PDO index is not a voltage measurement. No
software cutoff is inferred from an unknown voltage.

The monitor waits 500ms at startup and after attachment, then samples every
250ms. Each I2C transfer has a 2ms timeout. It checks attachment, VBUS readiness,
policy state and a repeated RDO snapshot before reporting a contract. Failed
reads clear the previous current immediately; a stopped poll becomes stale
after 1.5s. The Pi receives a report once per second, and separately expires it
after three missed reports even if ordinary hello messages keep arriving.
`PedalRepository.pdStatus` and `pdStatusChanges` expose the observation; the
existing persistent log records changes. Unknown voltage is `0` on the wire
and `null` in Dart. The 20V input still needs a meter or PD analyzer check.

Sources and test limits are recorded in the
[PD/presence completion report](../../docs/reviews/pcb-completion-1072/pd-presence-completion.md).

## Indicator harness and rendering

The owner confirmed eight LEDs per pill and this **data** chain order on
September 24. Retain this harness when moving it from the old board to J24:

| Group | Pixels | Pill |
| --- | --- | --- |
| 0 | 0–7 | TRACK4 |
| 1 | 8–15 | TRACK3 |
| 2 | 16–23 | TRACK2 |
| 3 | 24–31 | TRACK1 |
| 4 | 32–39 | MODE |
| 5 | 40–47 | UNDO |
| 6 | 48–55 | STOP |
| 7 | 56–63 | REC/PLAY |
| 8 | 64–71 | CLEAR |
| 9 | 72–79 | BANK |

Looking at the faceplate, data enters each front-row pill (groups 0–7) from
the right; CLEAR and BANK (groups 8–9) receive data from the left. Firmware
maps these directions to left-to-right local pixel coordinates. The symmetric
gradient looks the same either way. Footswitch IDs are unchanged. Power uses
the separate tapped bus documented in `hardware/segno_wiring.md`, not a series
feed through all the strip copper. J24 is 1=GND, 2=data, 3=+5V.

The centre-bright gradient is symmetric: linear PWM weights
38, 92, 201, 255, 255, 201, 92, 38, averaging 57.45%. Colours retain the previous
gamma correction and brightness is capped at 128/255. Tracks use the active
bank; MODE shows the selected mode, CLEAR the held clear state, BANK bank B.
REC/PLAY shows transport activity. STOP is red while held and UNDO is blue while
held; these acknowledge the physical presses, not transport/history status.
BANK uses the same full-blue source intensity as MODE before the common cap.

In Song playback mode, a queued track fills left to right over the remainder of
the currently playing section's loop. Its completion comes from the audio
engine, through the app's state frames. The old track stays steady green until
the engine switches at the next loop boundary; then its pill goes dark and the
new one becomes steady. Repeating the queued target or pressing the current
source cancels the queue; another target replaces it. Bank changes only alter
which four tracks are visible. Record and FX mode keep their own indications.

Protocol 7 adds two STATE bytes: target + 1 (zero means no queue) and completion
0..254 with denominator 255. The board never advances a queue with a local timer
or claims playback from a completed animation. The matched app and native
engine are required. This protocol replaces version 6 without a compatibility
mode. Both the Pico and XIAO use private ring-link version 2.

NeoPixelBus sends LED data with PIO and DMA while UART interrupts remain
active. The earlier Adafruit `show()` masked interrupts for the entire strip,
which would lose ring UART bytes with 80 pixels. Adafruit supplies the same
gamma functions only. LEDs start dark, without a startup sweep, and remain
dark until the Pi sends valid state. A goodbye clears them; a missing host
state clears them after five seconds. The ring has an additional 500ms
console-link timeout, described in [its README](../ring_board/README.md).

## Build and test

Tested dependency versions:

```sh
arduino-cli core install rp2040:rp2040@6.0.0 --additional-urls https://github.com/earlephilhower/arduino-pico/releases/download/global/package_rp2040_index.json
arduino-cli lib install "Adafruit NeoPixel@1.15.5" "NeoPixelBus by Makuna@2.8.4"
arduino-cli compile --libraries firmware/libraries --fqbn rp2040:rp2040:rpipico2 firmware/console_board --output-dir firmware/console_board/build
arduino-cli compile --libraries firmware/libraries --fqbn rp2040:rp2040:seeed_xiao_rp2350 firmware/ring_board --output-dir firmware/ring_board/build
bash firmware/test/run_tests.sh
```

The shared `firmware/libraries/SegnoPanel` library contains the canonical
pedal codec and the private ring link. The host suite compiles both actual
sketches with simulated I/O: it checks cable-loss/reboot recovery, short
button pulses, parser corruption, counter wrap, all 80 pixels, ring animation,
CTRL insertion/removal, E9 sequencing and read-only PD polling. The C codec
round-trips the Dart-generated golden frames. CI also builds both real MCU
targets with the dependency versions above.

## Installation and physical acceptance

The appliance release includes `console_board.elf` and a protocol/firmware
marker. Its existing `segno-console-flash` startup unit installs the matched
console firmware over Pi GPIO24/25 SWD. GPIO25 needs `gpio=25=pu` in boot
configuration. For explicit manual installation on the appliance:

```sh
segno-openocd -f /usr/lib/segno/console-board/pi5-swd.cfg \
  -c "program /usr/lib/segno/console-board/console_board.elf verify reset exit"
```

The XIAO is independent and must receive its own UF2 before enclosure mounting.
No firmware was flashed during the September 22 pre-order audit. The previous
September 3 bring-up exercised v2 wiring; it is not proof of this v3 assembly.

Before release, exercise every switch and CTRL contact on the assembled v3,
turn the encoder during maximum LED activity, verify pill order and brightness,
unplug/reconnect the ring link, and confirm boot/shutdown darkness. Measure
AUX voltage at the screens during simultaneous startup. Host tests and successful
MCU compilation do not prove electrical timing, cable pinout or power margin.
