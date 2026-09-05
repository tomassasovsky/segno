# DIN MIDI bench follow-up

Parked on 2026-09-05 at the owner's request, pending an **SN74AHCT125N**.
Tracking: [issue #1007](https://github.com/tomassasovsky/segno/issues/1007).
Branch: `codex/midi-out-ahct125-follow-up`.

This records the September 4 bench session. It is not a production integration
change or a confirmed diagnosis of the output failure.

## Results to preserve

| Check | Observed result |
| --- | --- |
| Launchkey 61 MK3 DIN OUT into Scarlett 4i4 MIDI IN | Notes, CC messages, and clock received; sender and that cable verified. |
| Pi UART0 internal loopback | All 256 byte values received exactly. Internal loopback was disabled before external tests. |
| Scarlett OUT into built-in appliance IN, final retest | Three exact 16-byte trials; 48/48 bytes; no framing, parity, or overrun errors. |
| Built-in appliance OUT into Scarlett IN, latest retest | Three failures; UART TX counter increased by 48 bytes; Scarlett received 0 bytes. |

Earlier IN tests failed before connector wiring was revisited. The precise
physical change that made IN pass was not confirmed. Do not claim that the
earlier input failure or the remaining output failure has a proven root cause.
The UART TX counter proves software/driver transmission activity, not a valid
signal at the DIN socket.

## Component to replace

U1 is fitted with **SN74HC125N**. The
[console-board circuit](../../hardware/kicad/console_board.py) specifies
**74AHCT125N**, powered from 5 V, with a 3.3 V input from the Pi.

The HC device does not guarantee reliable recognition of the Pi's 3.3 V high
level across this 5 V application. The AHCT device specifies a 2 V minimum high
input over its 4.5-5.5 V supply range. The mismatch is a plausible cause of the
OUT failure, but no voltage or waveform measurements have confirmed it.

- [TI SN74HC125 datasheet](https://www.ti.com/lit/ds/symlink/sn74hc125.pdf)
- [TI SN74AHCT125 datasheet](https://www.ti.com/lit/ds/symlink/sn74ahct125.pdf)

Power off before fitting **SN74AHCT125N**, preserving the package orientation.
U2 is an **H11L1** powered at 3.3 V; MIDI IN bypasses U1, so the passing input
test does not establish that U1 works.

## Verified wiring map

Use the connector's actual pin numbers. The front mating view and rear solder
view are mirror images; do not infer pin numbers from an unlabeled view.

| Board connector | DIN socket pin | Function |
| --- | --- | --- |
| J4 pin 1 | OUT pin 5 | U1 output through 220 ohms |
| J4 pin 2 | OUT pin 4 | 5 V through 220 ohms |
| J4 pin 3 | OUT pin 2 | Ground/shield |
| J5 pin 1 | IN pin 4 | Through 220 ohms to H11L1 pin 1 |
| J5 pin 2 | IN pin 5 | H11L1 pin 2 |

DIN pins 1 and 3 are unused. IN pin 2 is unconnected.

U1 MIDI OUT uses gate C: pin 9 is the input, pin 8 is the output, and active-low
enable pin 10 is grounded. Pin 14 is 5 V; pin 7 is ground. The Pi signal is
GPIO14/TXD0, physical header pin 8. MIDI IN feeds GPIO15/RXD0, physical pin 10.

If the replacement does not fix OUT, check supply at U1 pin 14 and enable at
pin 10 relative to pin 7. With TX idle, pin 9 should be about 3.3 V and pin 8
about 5 V. Static voltages do not prove correct MIDI pulses. Check continuity
through J4 and its resistors with power off; inspect the signal at pins 9 and 8
during transmission if a scope or logic analyzer is available.

## Resume the bench test

1. Fit the specified part, then connect appliance OUT to Scarlett IN and
   Scarlett OUT to appliance IN. Verify the labels; the plugs were deliberately
   swapped during an earlier diagnostic and should not be assumed correct.
2. Inspect current UART and ALSA device state. The tested UART was
   `/dev/ttyAMA0`; identify the Scarlett raw MIDI port using `amidi -l` rather
   than assuming its previous card number.
3. UART0 was initially disabled. The session temporarily applied the official
   Pi 5 `uart0-pi5` overlay, mapping GPIO14/15 to TXD0/RXD0. No boot configuration
   was changed. Verify whether the runtime overlay still exists; it does not
   persist across reboot. Use the overlay from the running image when needed.
4. Configure UART0 for **31,250 baud, 8 data bits, no parity, 1 stop bit**, raw
   mode with no flow control. Disable internal loopback and flush stale RX.
   Save and restore the previous UART settings around each test.
5. For each trial, send the following 16 bytes, substituting note 60, 61, then
   62 for `NN`: `90 NN 40 80 NN 00 B0 16 00 B0 16 40 B0 16 7F F8`.
   These are note on/off, three CC22 values, and one clock byte.
6. For IN, open the UART reader before transmitting from the Scarlett using
   `amidi -p <port> -S '<hex bytes>'`. Compare the received bytes exactly.
7. For OUT, start `amidi -p <port> -r <capture-file> -t 1 -a -c` before writing
   to UART0. Verify that capture started successfully. The `-c` option retains
   the clock byte; `-a` retains active sensing so unexpected traffic is visible.
   Compare the capture against the full expected sequence.
8. Record RX/TX and framing/parity/overrun counter deltas. Require three exact
   trials in each direction: **48/48 bytes per direction**, with zero errors.
   Close capture processes and restore UART settings when finished.

The diagnostic used Python's `os`, `fcntl`, `struct`, `select`, `subprocess`, and
`time` modules plus Linux arm64 `termios2` ioctls. The tested appliance lacked
Python `termios`, `ctypes`, and pyserial; do not assume they are installed.
The Linux arm64 ioctl numbers used were TCGETS2 `0x802c542a`, TCSETS2
`0x402c542b`, TIOCMBIC `0x5417` with TIOCM_LOOP `0x8000`, and TIOCGICOUNT
`0x545d`. Confirm the platform before reusing those ABI-specific values.

The pedal link is a separate UART (`/dev/ttyAMA3` on the tested system), and
was not changed. No diagnostic capture was left running; each test restored
its UART settings. The runtime UART0 overlay was left enabled at the end of
the session. Inspect state again after the part replacement or any reboot.

## Integration boundary

The session verified raw hardware traffic only. Segno's MIDI input was connected
to ALSA Midi Through, not the DIN UART, and no UART-to-ALSA connection or
persistent UART configuration was implemented. Track that integration separately
after hardware verification; a passing DIN test alone does not prove that the
application receives or sends MIDI through these sockets.

Resume issue #1007 when the part arrives, record the confirmed cause and final
results there, and keep the issue blocked on hardware verification until then.
