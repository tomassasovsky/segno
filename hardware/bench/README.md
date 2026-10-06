# Bench tests

Tools that only mean something with hardware in front of you. They live here
rather than in `firmware/test/` because nothing in CI can run them.

| Script | What it proves |
| --- | --- |
| `midi_din_test.py` | The console board's two DIN MIDI sockets carry exact bytes in both directions ([#1007](https://github.com/tomassasovsky/segno/issues/1007)) |

---

## midi_din_test.py — DIN MIDI, after fitting the SN74AHCT125N

**Resolved on 2026-09-17: the OUT socket had DIN pins 4 and 5 swapped.** The
chip was not the cause. The test below is what proved it, and it is the test to
re-run whenever this wiring is touched.

The record of the September 4 session is
[`docs/research/2026-09-05-din-midi-bench.md`](../../docs/research/2026-09-05-din-midi-bench.md):
MIDI IN passed 48/48 bytes, MIDI OUT sent 48 bytes from the UART and the Scarlett
received none. U1 was fitted with an **SN74HC125N** where the design asks for an
**SN74AHCT125N**, which is a plausible cause and was never confirmed. This script
is that session's procedure, so the retest is one command instead of an evening.

### Before the swap, look at the panel

**The same chip drives the ring and the indicator pills** on this board (U1 gate B
and gate A; MIDI OUT is gate C). They work today with the HC part fitted. So if
the LEDs keep working after the swap but MIDI OUT still fails, the chip was never
the fault, and the DIN wiring or J4 is where to look next. Note what the panel
does now, before you change anything.

### Fit the part

1. Power the console down and unplug it. Fit the **SN74AHCT125N** at U1.
2. Read the top of the part: it must say `SN74AHCT125N`. `HC` is the part that is
   coming out; the letters are the whole difference.
3. Pin 1 goes where pin 1 went: the notch faces the same way as the old part and
   as the silkscreen. Check every pin sits in its hole before soldering.
4. Power up and confirm the ring and the pills still light. If they stopped, the
   part is in backwards or a pin is folded under the body — stop and fix that
   before testing MIDI.

### Cable it up

- Appliance **MIDI OUT** to the interface's **MIDI IN**.
- The interface's **MIDI OUT** to the appliance **MIDI IN**.

Check the labels on the sockets rather than trusting the last person's cabling:
the plugs were deliberately swapped during an earlier diagnostic.

### Run it

Copy the script to the appliance and run it there:

```bash
scp hardware/bench/midi_din_test.py root@192.168.50.124:/tmp/
```

```bash
ssh root@192.168.50.124 'python3 /tmp/midi_din_test.py --preflight'
```

`--preflight` changes nothing. It reports whether `/dev/ttyAMA0` exists, whether
`amidi` is installed, and which MIDI ports ALSA can see. If the UART is missing,
UART0 is not enabled: the earlier session applied the image's own `uart0-pi5`
overlay at runtime, and that does not survive a reboot.

```bash
ssh root@192.168.50.124 'python3 /tmp/midi_din_test.py --loopback'
```

The UART's internal loopback, with no board and no cables in the path. It proves
the script, the UART and the baud rate before any result about the board means
anything. The real test always runs with loopback off.

```bash
ssh root@192.168.50.124 'python3 /tmp/midi_din_test.py'
```

The acceptance test. Three trials per direction — notes 60, 61 and 62 — each one
sixteen bytes: note on, note off, three CC 22 values and a clock byte. It prints
every trial, the bytes when they differ, and the UART's own error counters. It
exits 0 only on a pass.

`--port` names the interface when more than one is connected (`--port scarlett`),
`--only in` or `--only out` runs a single direction, and `--uart` moves off
`/dev/ttyAMA0`. The pedal link's UART is refused by name — it carries the console
board's traffic and must not be reconfigured.

### What counts as a pass

**48 of 48 bytes in each direction, byte for byte, with no framing, parity or
overrun errors, and the internal loopback off.** Anything less is a fail, and a
direction that passes two trials out of three is a fail.

### If OUT still fails

The script prints the measurement list. In short: 5 V at U1 pin 14, enable
(pin 10) at 0 V, about 3.3 V on pin 9 and 5 V on pin 8 with TX idle, then
continuity from J4 through its 220 Ω resistors to the DIN pins. The bench doc has
the full connector map, and a DIN socket's front and rear views are mirrored —
read the pin numbers rather than inferring them.

### What this does not prove

That Segno sends or receives MIDI through these sockets. The app's MIDI input was
connected to ALSA Midi Through, not to this UART, and nothing here makes the UART
configuration persist across a reboot. That integration is separate work; raw DIN
traffic passing is only the hardware half.

Record the result on [#1007](https://github.com/tomassasovsky/segno/issues/1007),
including which cause turned out to be the real one.
