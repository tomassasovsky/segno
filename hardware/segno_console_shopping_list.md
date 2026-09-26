# Segno Floor Console — Local Shopping List (Argentina)

Quantities are **per console**. All parts are standard and available at local
electronics shops / MercadoLibre, except the Pi 5, screens, and USB interface
(import or specialty).

> The console is a **standalone Pi 5 appliance**. The foot controls
> (footswitches), pill LED drive and MIDI front end live on
> the **console board v3** — a Pico 2 (RP2350) board linked to the Pi's 40-pin
> header over a short keyed ribbon (`hardware/kicad/console_board.py`, #747).
> The Pi reads no controls directly and never bit-bangs WS2812. The console is
> the only product; there is no separate USB-MIDI pedal.

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
- [ ] Screen touch: USB-A male → XH4 ×2, XH4 → USB-C male ×1 and
      XH4 → Micro-B male ×1, connected through the screen-power board.
      Separate main-power leads: VH2 → UPERFECT USB-C and VH2 → APROTII
      Micro-B or power pads, positive and return at least 20 AWG.
      Use the exact [screen harness BOM](kicad/screen_power/external_bom.csv),
      including its required input fuse, holder and GPIO lead.

## Audio

- [ ] USB **class-compliant** audio interface, Scarlett-class (e.g. Focusrite
      Scarlett 2i2 / Clarett, or any UAC2 interface) ×1
- [ ] Instrument (TS) + mic (XLR) cables as needed
- [ ] TS→TS loopback cable ×1 *(one-time latency calibration only)*

## Foot controls

Terminated by the **console board v3** (`hardware/kicad/console_board.py`, #747)
— the loose parts here are only what bolts to the panel and plugs into it.

- [ ] Momentary **SPST footswitches** (stomp-rated, Cherub WTB-006 per
      [`MANUFACTURING.md`](MANUFACTURING.md)) ×10 — one per pedal, J10..J19
- [ ] **EC11 rotary encoder** (with push switch) ×1 — mounts on the encoder
      ring PCB (also in `MANUFACTURING.md`)
- [ ] Knob for the EC11 ×1
- [ ] JST-XH pre-crimped 2-pin leads for the footswitch looms ×10
- [ ] **Neutrik NJ6FD-V switched CTRL jacks ×2** — rear-mounted through
      Ø12 mm holes in the 1.5 mm panel. Four wires per jack: T, R, S and TN
      to console J20/J21. RN/SN remain unused. These are not D-punch parts.

## LEDs

The console Pico drives the pills. The independent XIAO on the ring carrier
drives the ring and reads its encoder; their level shifters and bulk capacitors
are on the respective board BOMs.

- [x] **40-LED WS2812B strip**, already fitted to the current pedal. Reuse it
      with the new carrier's J2 pin 3 for DIN and its separate strip housing.
      Feed power directly from the near-ring AUX split: at most 600 mm of
      16 AWG copper pair, then separate ≤50 mm 22 AWG pairs to the strip and
      carrier J1. Buy suitable insulated splice materials and genuine XH
      contacts for the 22 AWG pigtail. Do not also populate the optional
      24/16-module pads. See the current wiring diagram.
- [ ] WS2812B **indicator pills** — **144 LEDs/m, bare/non-waterproof
      (labelled IP20 or IP30 — the same uncoated strip either way), 12 mm
      wide**, ×**1 m**. Cut into **10** eight-LED segments of 55.56 mm,
      one per pedal. You need 0.556 m; 1 m covers mis-cuts.
      Candidate: LOAMLIN WS2812B 144LED/m, 3.2 ft, **IP30 non-waterproof**,
      white PCB, DC5V —
      [LOAMLIN 144/m 3.2 ft](https://www.amazon.com/dp/B0BDS7NHQM), $9.99. Right part on every axis that
      matters, and its own listing states 0.1 W/LED per colour, which confirms
      the power model below.
      The spec is load-bearing, not a preference:
      **144/m** because the pill only has 3.2 mm of diffuser to spread through,
      so anything sparser reads as separate dots (60/m is 5.2:1 — three blobs),
      and because the pill is rendered as a gradient, which needs steps to be
      smooth; **non-waterproof** because it is inside a sealed console and is the
      thinnest — IP65/IP67 add 0.87/1.72 mm and push the LED further from the
      lens.
      ⚠️ **MEASURE THE STRIP BEFORE PRINTING THE DIFFUSERS.** The candidate's own
      listing contradicts itself on width — product image says 12 mm, its
      compare-with-similar row says "IP30/65 - 10mm; IP67 - 12mm". The channel
      grips 0.4 mm per side, so 2 mm of error either jams the strip or drops it
      straight through. Width reaches **only the 3D-printed diffuser**, never
      anything a shop cuts, so print those after the strip lands. Confirm width,
      pitch and PCB thickness together.
      Note it is built from 50 cm PCBs, so there is a **solder joint every
      50 cm**. 80 LEDs are needed of 144, so there is room to cut around it

## Power (#754 — one 20 V PD contract, two bucks)

- [ ] **USB-C PD panel coupler**, D punch — QIANRENON
      [B0CQ4VD2N2](https://www.amazon.com/dp/B0CQ4VD2N2) ×1 (100 W, 10 Gbps —
      the 10 Gbps grade matters: all 24 ways wired means CC reaches the trigger;
      charge-only couplers drop CC and nothing powers up)
- [ ] **STUSB4500 PD trigger board** (SparkFun) ×1 — program the PDO to
      **20 V / 5 A** before first power-up; the shipped default asks 20 V at
      only 1 A
- [ ] **20 V → 5 V buck** (eleUniverse 8–36 V→5 V 10 A IP67,
      [B0GGHN97TK](https://www.amazon.com/dp/B0GGHN97TK)) ×**2** — BUCK_PI and
      BUCK_AUX, split by rail, never paralleled (wiring doc §2)
- [ ] **100 W-class USB-C PD supply** (20 V / 5 A capable) + 5 A-rated C-to-C
      cable ×1 — the external brick; no mains enters the enclosure
- [ ] **2×20 keyed IDC ribbon**, ~10 cm ×1 — console board J2 → Pi header
- [ ] **Würth 61204021621** vertical keyed 2×20 board header ×1 — J2.
      The console footprint uses 1.25 mm finished holes and 1.80 mm minimum pads
      for this part’s maximum post size; a generic substitute needs its own fit check.
- [ ] **Würth 61300621121** vertical 2×3 pin header ×1, optional — J22 expansion;
      the same 1.25 mm holes / 1.80 mm pads apply.
- [ ] **Panel fuse holder**, generic 5×20 screw-cap, 10 A / 250 VAC, **Ø12.0**
      aperture ×1 — e.g. [NeoLum 4-pack](https://www.amazon.com/dp/B0GF33P9FF).
      Generic by decision. NOTE the aperture: the SCI R3-11 upgrade wants
      Ø12.5 and the panel is no longer cut for it
- [ ] **T5A slow-blow** 5×20 fuses (T5AL250V) ×1 pack — NOT fast-blow; the two
      bucks' inrush will nuisance-blow a fast fuse
- [ ] **Momentary HIGH-ROUND** push button, 19 mm hole (Ø19.5), **unlit**,
      stainless ×1 — [APIELE, $4.50 ea](https://www.amazon.com/dp/B079HTQ7XD).
      Must be momentary: it pulses the Pi 5's own power-button pads (its J2,
      through the console board's J8→J9 lead) — no GPIO is involved and it does
      not break power. Domed, not flat — the dome is what gives it a real click
> **Everything on this list is bought from Amazon.com** (decision, 2026-08-17).
> A MercadoLibre comparison was run and is in git history at `d5295b69` /
> `1621f676` if local sourcing ever comes back up; the one finding worth keeping
> is that a plain local 6.35 chassis jack will NOT fit a D punch. Moot since
> 2026-09-04: the CTRL jacks are Neutrik NJ6FD-V in a plain Ø12 hole (#993).

- The power budget is [`segno_wiring.md` §2](segno_wiring.md) — canonical since
  #754.

## Console v3, ring carrier and screen-power boards

Use the current generated/maintained BOMs rather than earlier board lists:

- [Console v3](kicad/fab/segno_console_board_bom.csv).
- [Ring carrier and selected 40-LED strip](kicad/fab/segno_combined_bom_lcsc.csv).
- [Screen board](kicad/screen_power/hand/bom.csv) and
  [external harness parts](kicad/screen_power/external_bom.csv).

Fit the specified **74AHCT125N** DIP parts at console U1 and ring U2.
Their TTL-level inputs accept the 3.3 V control signals; do not substitute
74HC125. The console buffer drives MIDI OUT and pills; the carrier buffer
drives the ring strip.

Use the console/carrier runtime in
[PR #1082](https://github.com/tomassasovsky/segno/pull/1082), including its E9
workaround for A2 Pico silicon. The hardware branch's old firmware snapshot
is not that runtime. Board order settings and the separate enclosure-release
limits are in [MANUFACTURING.md](MANUFACTURING.md#3-pcbs).

## Mechanical / enclosure

- [ ] Enclosure material (plywood / aluminium / 3D-printed panels) — tilted body
- [ ] M2.5/M3 screws + standoffs for the Pi, the console board, and screen mounts ×1 set
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
- Footswitches, CTRL jacks and pill LEDs terminate on console v3; the encoder
  and 40-LED strip terminate on the independent ring carrier. Pi GPIO14/15
  carry MIDI, and the pedal link uses uart3 (GPIO8/9) over the ribbon.
