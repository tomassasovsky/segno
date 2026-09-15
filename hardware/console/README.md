# Segno Floor Console — hardware design

Hardware for the standalone Pi 5 floor console. The BOM is
[`hardware/segno_console_shopping_list.md`](../segno_console_shopping_list.md).
Footswitches, the encoder, the CTRL jacks, MIDI and the WS2812 drive all
terminate on the **console board v2** — a Pico 2 (RP2350) board on a short
keyed ribbon to the Pi's 40-pin header
([`hardware/kicad/console_board.py`](../kicad/console_board.py), #747). The Pi
reads no controls directly and never bit-bangs WS2812; the earlier plan of a
USB-MIDI pedal board plus a separate RP2040 LED driver is dead. The Pico runs
[`firmware/console_board`](../../firmware/console_board/), and
[`pedal_link.h`](../../firmware/console_board/pedal_link.h) is the wire format
of the link to the Pi.

> **Status:** the board is fab-ready (#747); the enclosure is designed under
> `hardware/enclosure/`; the assembled-unit gates (latency soak, stage-abuse)
> are physical work, tracked as the on-hardware checklist in
> [`docs/RUNNING_ON_RPI.md`](../../docs/RUNNING_ON_RPI.md).

## Power

Canonical since #754: **one 20 V USB-C PD contract at a rear-panel coupler,
two 20→5 V bucks split by rail** — BUCK_PI feeds the Pi (via its USB-C, 25 W
worst case), BUCK_AUX feeds both screens, the console board and the LEDs (34 W
worst case). No mains enters the enclosure; the fuse sits in the 20 V feed.
The full budget, the trim/window arithmetic, and the wiring live in
[`segno_wiring.md` §2](../segno_wiring.md) — this README no longer keeps its
own copy of the table, because two copies of a power budget is how one goes
stale.

Rules that survive any future edit:

- The LED chain must **not** draw off the Pi's 5 V pin (ribbon pins 2/4 are
  deliberately unconnected — the board's `PI_POWER` gate enforces it).
- WS2812 peak is ~60 mA/LED at full white; cap brightness in firmware to keep
  the worst case inside BUCK_AUX's budget.
- The Pi caps downstream USB at 600 mA unless `usb_max_current_enable=1` is in
  `config.txt` — required, the touch panels and audio interface hang off it.

## Thermals

A Pi 5 in a closed enclosure under sustained audio + dual-display GPU load will
throttle without help:

- **Active cooling is required** — the official active cooler or an equivalent
  heatsink+fan, with an intake/exhaust path in the enclosure.
- **Soak gate (on-hardware):** ≥2 h of audio + dual-display + GPU load in the
  closed enclosure with **no thermal throttle** (`vcgencmd get_throttled` stays
  `0x0`) and no xrun-rate regression. Record results in `docs/RUNNING_ON_RPI.md`.

## Enclosure

Designed and generated under [`hardware/enclosure/`](../enclosure/) (sheet
metal, printed platforms, rear-panel stations); `segno_enclosure_design.md`
carries the design story. The 16″ touchscreen and 7″ waveform panel mount up
top; the footswitch + encoder deck is the stomp face; the Pi and the console
board both sit under the 16″ screen with the rear I/O cluster directly above
the board.
