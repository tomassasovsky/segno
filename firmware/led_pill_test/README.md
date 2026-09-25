<!-- cspell:words smoothstep crtscts clocal -->
# Eight-LED pill diffuser test

Standalone bench firmware for the console board's Pico 2. J7 pin 2 receives
WS2812B data from GP18 through the existing level shifter. Exactly eight pixels
are addressed, in GRB order. Use the pill's existing 5 V supply and common ground.
All 40 pixels of the connected encoder ring are cleared at startup.

The default is green breathing with a one-second cycle and a peak green value
of 191/255 (75%). A smoothstep envelope ranges from 15% to 100% of that peak.
The spatial weights, left to right, are approximately
15%, 36%, 79%, 100%, 100%, 79%, 36%, 15%. No additional gamma correction or
global brightness scaling is applied. The simulator's brighter diffuser
exposure is a display effect, not an extra hardware gain.

Physical controls during the test:

| Switch | Test mode |
| --- | --- |
| REC/PLAY | Breathing |
| STOP | Off |
| UNDO | Steady on, with the same centre curve |

This is a bench instrument, not the console's normal pedal-link firmware.
Stop `segno.service` before the test so the app releases the UART and cannot
consume its replies. Normal footswitch, encoder and CTRL behavior is unavailable
until the regular firmware is restored.

## Build and check

Validated toolchain: arduino-pico 6.0.0 and Adafruit NeoPixel 1.15.5.

```sh
bash firmware/test/run_tests.sh
arduino-cli compile --fqbn rp2040:rp2040:rpipico2 \
  firmware/led_pill_test --output-dir firmware/led_pill_test/build
```

## Flash and control

Copy `build/led_pill_test.ino.elf` to a bench directory on the appliance.
Keep the shipped `/usr/lib/segno/console-board/console_board.elf` intact.
On the appliance, substituting the copied test ELF's absolute path:

```sh
systemctl stop segno.service
pinctrl set 25 pu
segno-openocd -f /usr/lib/segno/console-board/pi5-swd.cfg \
  -c "program /absolute/path/led_pill_test.ino.elf verify reset exit"
stty -F /dev/ttyAMA3 115200 raw -echo -crtscts clocal
printf 'pill demo\n' > /dev/ttyAMA3
timeout 15 cat /dev/ttyAMA3
```

Newline-terminated UART commands: `pill breathe`, `pill on`, `pill off`,
`pill full`, `pill demo`, `pill status`. `pill full` sends steady green at 255
to every pixel, bypassing the centre curve for diffuser brightness comparison.
The physical controls still select the normal breathing/on/off modes.
Demo repeats 8 seconds of breathing, 3 seconds on,
2 seconds off. Telemetry reports the selected mode, active mode and the eight
green-channel values. It confirms firmware execution; visually inspect the pill
to verify color, all eight pixels, brightness and diffuser appearance.

## Restore normal operation

On the appliance:

```sh
segno-openocd -f /usr/lib/segno/console-board/pi5-swd.cfg \
  -c "program /usr/lib/segno/console-board/console_board.elf verify reset exit"
systemctl start segno.service
```

A normal reboot also restores the shipped controller through
`segno-console-flash.service`. This test does not modify the shipped image,
version marker, application, or its autostart configuration.
