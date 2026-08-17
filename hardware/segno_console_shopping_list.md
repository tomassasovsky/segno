# Segno Floor Console — Local Shopping List (Argentina)

Quantities are **per console**. All parts are standard and available at local
electronics shops / MercadoLibre, except the Pi 5, screens, and USB interface
(import or specialty). Mirrors [`segno_pedal_shopping_list.md`](segno_pedal_shopping_list.md).

> The console is a **standalone Pi 5 appliance**. The foot controls
> (footswitches + encoder) connect through the 32U4 USB-MIDI pedal board
> (`segno_pedal_main` — see [`MANUFACTURING.md`](MANUFACTURING.md)); the Pi
> reads no controls directly. The WS2812 LEDs are offloaded to a small RP2040
> driver over UART (see
> [`firmware/led_driver/README.md`](../firmware/led_driver/README.md));
> the Pi never bit-bangs WS2812.

---

## Compute + displays

- [ ] Raspberry Pi **5** (8 GB recommended; 4 GB OK) ×1
      *(Pi 4 Model B 8 GB also works — see the Pi-4 note in
      [`docs/RUNNING_ON_RPI.md`](../docs/RUNNING_ON_RPI.md); tighter latency/thermal margin.)*
- [ ] Pi 5 **active cooler** (official, or a heatsink+fan) ×1 — **required** for a
      closed enclosure under sustained audio + GPU load
- [ ] microSD card, A2, 64 GB+ ×1
- [ ] **16″ touchscreen** monitor, 1080p, HDMI + USB-touch ×1 — main UI
- [ ] **7″ HDMI** display ×1 — waveform. **HDMI, not DSI** (decision below)
- [ ] micro-HDMI → HDMI cables (Pi 5 has 2× micro-HDMI) ×2
- [ ] USB-A → USB-B/-C cable for the touchscreen's touch panel ×1

## Audio

- [ ] USB **class-compliant** audio interface, Scarlett-class (e.g. Focusrite
      Scarlett 2i2 / Clarett, or any UAC2 interface) ×1
- [ ] Instrument (TS) + mic (XLR) cables as needed
- [ ] TS→TS loopback cable ×1 *(one-time latency calibration only)*

## Foot controls

Carried by the `segno_pedal_main` USB-MIDI board — fab + BOM in
[`MANUFACTURING.md`](MANUFACTURING.md) (order it alongside this list).

- [ ] Momentary **SPST footswitches** (stomp-rated) ×5 — rec/overdub, stop,
      undo, clear, encoder-press is separate
- [ ] **EC11 rotary encoder** (with push switch) ×1 — mounts on the encoder
      ring PCB (also in `MANUFACTURING.md`)
- [ ] Knob for the EC11 ×1
- [ ] USB-A → USB cable, Pi → `segno_pedal_main` ×1

## LEDs + driver

- [ ] **RP2040** board — Adafruit QT Py RP2040 or a Pi Pico ×1 (the LED driver)
- [ ] WS2812 **ring**, 12 LEDs (loop-position ring) ×1
- [ ] WS2812 **strip/indicators**, ≥10 LEDs (one pill per pedal, issue #366) ×1
- [ ] 3.3 V → 5 V level shifter (e.g. 74AHCT125N, **DIP-14**) ×1 — for the
      WS2812 data line off the RP2040
- [ ] 1000 µF electrolytic, 6.3 V+ ×1 — across the WS2812 5 V rail
- [ ] 330–470 Ω resistor ×1 — in series with the WS2812 data line

## Power

- [ ] Raspberry Pi 5 **official 27 W USB-C PD** supply ×1 — Pi 5 alone
- [ ] Separate **5 V / ≥3 A** supply for the WS2812 LEDs + RP2040 ×1
      *(do not draw the LED ring/strip off the Pi's 5 V pin)*
- [ ] The 16″ and 7″ screens use their **own** adapters (USB-C / barrel) ×2
- [ ] **Panel fuse holder** SCI **R3-11**, bayonet cap, 10 A / 250 VAC, Ø12.5
      cutout ×1 — [5-pack, $3.41 ea](https://www.amazon.com/dp/B0DY3XMGWM)
      (the 2-pack is $8.50 ea for the same part). The amp/pro-audio part, not a
      generic bakelite screw cap
- [ ] **T5A slow-blow** 5×20 fuses (T5AL250V) ×1 pack — NOT fast-blow; the two
      bucks' inrush will nuisance-blow a fast fuse
- [ ] **Momentary HIGH-ROUND** push button, 19 mm hole (Ø19.5), **unlit**,
      stainless ×1 — [APIELE, $4.50 ea](https://www.amazon.com/dp/B079HTQ7XD).
      Must be momentary: it drives a Pi GPIO soft shutdown, it does not break
      power. Domed, not flat — the dome is what gives it mechanical feel
### Sourcing — Argentina (MercadoLibre) vs Amazon

Rates at the time of writing: blue **1545**, card **1963** ARS/USD. An Amazon order
is paid at the *card* rate plus freight, so the crossover is well below face value.

| item | local (ARS) | Amazon | buy |
|---|---|---|---|
| **T5A slow-blow fuse** | 4 770 ("fusible 5×20 **lento** 5 A", Itytarg) | ~$7 for a 20-pack | **local** — one fuse, not twenty |
| **Fuse holder** | — | $8.50–11.13 | **local** |
| **DC 5.5×2.1 chassis, threaded** | 10 150 / 5 = 2 030 ea | DC-099 $1.52 ea (5-pack) | **local**, marginal |
| **Rubber feet, screw-on** | 5 500 | uxcell $5.69 / 4 | **local** |
| **DIN-5 female chassis** | 3 900 ea | REAN NYS325 $3.48 ea | see note |
| **TRS 6.35 D-series** | Neutrik **NJ3FP6C** 25 000 | MEIRIYFA $5.00 ea | see note |
| **Power button 19 mm SS** | 14 858 | APIELE **$4.50** ea | **Amazon**, ~40 % cheaper |
| **USB 3.0 coupler** | 17 650 generic · Neutrik NAUSB3 46 000 | already specified | **Amazon** |

> **DIN-5.** The local generic is cheaper, but `MIDI_BODY_D` = 15.1 is sourced from
> the REAN NYS325 specifically. Buying a generic means re-measuring the bore and the
> fixing pitch before the panel is cut — it moves a *sourced* number back to
> unconfirmed. Worth it only if the REAN is hard to get.
>
> **TRS — read the note in the design doc before buying locally.** A plain
> threaded-bushing chassis jack will not work in the Ø24 D punch. Locally that means
> the **Neutrik NJ3FP6C** specifically; it is 3× the clone but genuine Neutrik and
> **latching**, which on a floor unit with external control pedals is worth real
> money.
>
> **Possible simplification, not yet taken.** MercadoLibre also stocks the **Neutrik
> NAUSB3** USB 3.0 feedthrough (ARS 46 000), which is *also* a D-size part. Using it
> would put TRS ×2 and USB ×2 all on **one** cutout profile — the idea floated when
> #743 opened, now actually buyable. It costs ~ARS 92 k for the pair and would
> replace the 22.1 rounded square with a D punch, so it is a real change: raised,
> not taken.

- See the power budget in [`hardware/console/README.md`](console/README.md).

## Mechanical / enclosure

- [ ] Enclosure material (plywood / aluminium / 3D-printed panels) — tilted body
- [ ] M2.5/M3 screws + standoffs for the Pi, RP2040, and screen mounts ×1 set
- [ ] Stomp-panel face (steel/aluminium) for the footswitches ×1
- [ ] Rubber feet / non-slip base ×1 set
- [ ] Cable strain reliefs / grommets ×1 set

---

### 7″ display: **HDMI, not DSI** (spike outcome)

Both screens are wired as **HDMI** outputs, so they enumerate as uniform
`HDMI-A-1` (16″) / `HDMI-A-2` (7″) wlr outputs. This gives clean, deterministic
`wlr-randr` output-name pinning (matching Part 5's
[`deploy/rpi/pin-displays.sh`](../deploy/rpi/pin-displays.sh)) with no DSI ribbon
or DSI-specific compositor mapping. The official 7″ DSI panel's only advantage —
freeing a micro-HDMI port — is moot here since nothing else uses the second
HDMI, and its 800×480 is lower-res than an HDMI 7″. Resolution matters little for
a waveform, so pick any 7″ HDMI panel; set its per-output `--scale` in
`pin-displays.sh`.

### Notes

- Keep the engine at **48 kHz** with the PipeWire **Pro Audio** profile for the
  full channel count + lowest stable latency (see
  [`docs/RUNNING_ON_LINUX.md`](../docs/RUNNING_ON_LINUX.md)).
- The RP2040 LED driver talks UART to the Pi (GPIO14/15) — see the firmware
  README for wiring + the wire-format spec.
- The foot controls wire to the `segno_pedal_main` board (fabbed — see
  `MANUFACTURING.md`); there is no console-specific PCB. Enclosure/fab files
  live under `hardware/console/` once designed.
