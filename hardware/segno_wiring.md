# Segno loopstation — system wiring plan

How the Segno's subsystems connect: the THT **Pro Micro control board**
(`hardware/kicad/segno_pedal_main`), the **ring board** (`segno_pedal_ring`), the
**Raspberry Pi** (Pi build only), the two touchscreens, the external audio
interface, power, and the rear panel.

There are two builds (selectable in the 3D viewer). They share the **one control
board**; they differ only in whether a Pi is present and what the rear I/O exposes:

| | **Pi build** | **Base build** |
|---|---|---|
| Looper engine | Raspberry Pi (on-board) | external host (laptop/desktop) |
| Control board → engine | USB (Pi USB hat) | USB (to host) |
| Screens driven by | the Pi (HDMI ×2 + USB-hat touch) | the external host (HDMI in ×2 + USB touch) |
| Rear I/O sub-panel | 9V + btn + fuse + **Pi USB/Ethernet block** | 9V + btn + fuse + **2× HDMI + 2× USB-touch** |
| Audio interface | USB → Pi | USB → host |

---

## 1. Block diagram

> **Constraint:** the main board is already in production — it is NOT modified. Every
> addition below (the high-current 5V buck, the Pi's USB hat) is an **external add-on**;
> the 9V is split at the panel jack, ahead of the board.

```
   POWER
     9V DC barrel (center +, fused) ── rear panel jack
              │
              ├──────────────────► MAIN BOARD J3  (in production — untouched)
              │                       onboard MP1584 buck → 5V
              │                         ├─► Pro Micro            (5V_LOGIC)
              │                         └─► WS2812 indicator+ring (5V_LED)
              │
              └──────────────────► EXTERNAL 9V→5V buck  (≈ 5V/10A add-on module)
                                      ├─► Raspberry Pi          (5V into USB-C)
                                      └─► 7" + 16" screens      (5V)

   DATA / CONTROL
     Pro Micro ──USB──► [USB HAT on the Pi] ◄──USB── 2× screen touch     (add-on hat)
     Pi ──HDMI ×2──► 7" (left) + 16" (right) screens
     Pi rear USB-A ──► external audio interface ;  Pi Ethernet ──► network
     Pro Micro ◄── footswitches ×10 (D3–D12) · ring+encoder (8-pin cable) · MIDI DIN in/out
     power button ──► Pi GPIO (soft shutdown)

   GND: single common ground; DIN IN opto-isolated; M6 earth stud on the rear wall
```

---

## 2. Power distribution

**Two 5V bucks, because the main board is fixed.** The in-production control board
has its own onboard MP1584 (≈3A) fed from its `J3` 9V input — that already powers the
Pro Micro and the WS2812 strips, and **we leave it alone**. The Pi + screens draw far
more than that buck can give, so they get a **separate, external high-current buck**.

- The rear panel-mount **9V barrel jack** (fused, center-positive) is **split with a
  short Y-lead**: one branch to the board's `J3` (its onboard buck → logic + LEDs,
  unchanged), the other to the **external 9V→5V buck**. The split is in the harness,
  ahead of the board — nothing on the board changes.
- **External buck → 5.0V, sized for the Pi + screens (≈ 8–10A).** Feed the **Pi via
  its USB-C** (uses the Pi's own input protection — cleanest). Feed the screens 5V
  from the same buck.
- **You cannot put 9V on the Pi** — every Pi power input (USB-C, GPIO 5V pins) is 5V
  only; 9V would destroy it. The external buck is what makes the 5V.
- Add input bulk/TVS on the external buck's 9V input; keep the board's existing bulk
  as-is.

**Current budget (Pi build, worst case):**

| Load | Rail | Typical | Peak |
|---|---|---|---|
| Pro Micro + footswitches | board buck | 0.05 A | 0.05 A |
| WS2812 indicators (10, #366) + ring (12) = 22 | board buck | 0.25 A | 1.3 A (all white) |
| Raspberry Pi (Pi 5 under load) | **external buck** | 1.0 A | 2.4 A |
| 7" + 16" touchscreens | **external buck** | 1.5 A | 3.0 A |
| Pro Micro + 2× touch via the Pi's USB hat | external buck (via Pi) | 0.1 A | 0.2 A |
| External audio interface (USB-bus-powered) | external buck (via Pi) | 0.2 A | 0.5 A |
| **Board buck** | | ~0.3 A | ~1.4 A |
| **External buck** | | ~2.8 A | ~6.1 A |

→ External buck rated **≥ 8A @ 5V**. The 9V brick must cover both bucks: ~7.5A @ 5V
total ≈ **~50W**, so a **9V/6A (54W) supply** or larger.

**Power button** → Pi GPIO (soft shutdown / wake), not a hard 5V cut, so the Pi can
flush the SD card. It carries no load current, so it must be a **momentary** part (APIELE 19 mm
high-round). It is **unlit** — an LED ring only comes on flat, near-travel-free
faces, and the domed head is what gives it a real click. So it is two wires to a
GPIO and nothing else: no 5 V run to the rear panel, and no "does the lamp mean
brick-on or buck-on" question. **The machine has no power indicator**; the 7" and
16" screens do that job, from the side the player is actually on.

**Fuse** protects the shared 9V input, in series ahead of the Y-split. Converting
the 5 V budget above: 7.5 A × 5 V = 37.5 W, so at 9 V and ~85 % buck efficiency the
input sees **4.9 A peak / 2.0 A typical**. Fuse **T5A slow-blow** — above the
coincident peak, at/below the 9 V/6 A supply, well under the holder's 10 A.
**Slow-blow is required:** both bucks charge their bulk caps at switch-on and a
fast-blow T5 equivalent will nuisance-blow.

---

## 2b. Pro Micro ↔ Pi link, and MIDI moves to the Pi (#746)

**Why this exists.** The Pi 5's four USB-A ports are exactly consumed — 2 touch,
2 rear panel couplers — and a hub is ruled out, so the Pro Micro cannot have one.
Its only hardware UART (`Serial1`, D0/D1) was already the DIN-5 pair, so the fix is
to **move MIDI onto the Pi** and give `Serial1` to the pedal link. The Pi runs the
looper, so MIDI timing belongs there anyway; the Pro Micro reduces to footswitches
and LEDs.

```
   Pro Micro D1/TX (5V) ──[1k8]──┬──────────────► Pi uart2 RX      (pedal protocol,
                            [3k3]│                                   115200)
                              GND┘   3.24 V

   Pi uart2 TX (3.3V) ──► 74AHCT125 ──5V──► Pro Micro D0/RX

   Pi uart0 TX (3.3V) ──► 74AHCT125 ──5V──►[220Ω]──► DIN MIDI OUT pin 5
                                              +5V ──[220Ω]──► DIN MIDI OUT pin 4

   DIN MIDI IN pin 4 ──[220Ω]──► H11L1 (run at 3.3V) ──► Pi uart0 RX
   DIN MIDI IN pin 5 ──────────► H11L1 ;  pin 2 NOT connected (isolation)
```

### The level shifting, and why each direction is different

The Pro Micro is **5 V logic**; Pi GPIO is **3.3 V and not 5 V tolerant**. Connecting
D1 straight to a Pi pin can damage the RP1. The two directions are not symmetric:

| direction | problem | fix |
|---|---|---|
| **Pro Micro TX 5 V → Pi RX** | over-voltage — this one can destroy the Pi | **resistor divider**, 1k8 series + 3k3 to GND → **3.24 V** |
| **Pi TX 3.3 V → Pro Micro RX** | works, but marginal | **74AHCT125** buffer |

On the second one: the ATmega32U4 at VCC 5 V has `V_IH` = 0.6 × VCC = **3.0 V**, so a
3.3 V input has **0.3 V of margin** — it runs, but it is not something to ship. The
**AHCT** family has **TTL-level inputs** (`V_IH` 2.0 V) and CMOS 5 V outputs, so
3.3 V in gives a clean 5 V out.

The divider is genuinely fine here, not a bodge: Thévenin ≈ 1.16 kΩ into ~30 pF of
stray is a **35 ns** edge, against an 8.7 µs bit at 115200. Use 1k8/3k3 rather than
10k/20k — the ratio is the same but the higher values slow the edges.

### The consolidation

**We need the 74AHCT125 anyway.** A spec-compliant MIDI OUT is a 5 V current loop
(two 220 Ω), and the Pi's 3.3 V TX cannot drive it properly — so a buffer is
required for MIDI OUT regardless. It is a **quad**, so one part covers *both* 3.3→5
paths and still leaves two gates spare (tie unused inputs low).

And **MIDI IN needs no shifter at all**: the H11L1 is a Schmitt-trigger *logic-output*
opto, so running it from **3.3 V** makes it output 3.3 V straight into the Pi.

### Parts

| qty | part | job |
|---|---|---|
| 1 | **74AHCT125** (quad, 5 V) | Pi TX → Pro Micro RX · Pi TX → MIDI OUT |
| 1 | **H11L1** opto, powered at **3.3 V** | DIN MIDI IN → Pi RX |
| 2 | 220 Ω | MIDI OUT current loop |
| 1 | 220 Ω | MIDI IN LED |
| 1 | 1N4148 | MIDI IN reverse clamp |
| 1 | 1.8 kΩ + 1 | 3.3 kΩ | divider, Pro Micro TX → Pi RX |
| 2 | 100 nF | decoupling (AHCT125, H11L1) |

Both DIN jacks and all of the above live on a **small daughterboard**. On the main
board, simply **do not populate** J4/J5, U2 (H11L1) and the MIDI-OUT resistors —
that leaves D0/D1 free at their pads with nothing to cut. If a board is already
assembled, those connections have to be lifted instead.

### Pi UARTs

`uart0` (GPIO14/15) → MIDI at 31250. A second UART via `dtoverlay` — `uart2` is
GPIO4/5 on the Pi 5 — → the Pro Micro at **115200**. Baud is free now: the pedal
protocol is a custom framed stream, not MIDI, so it no longer has to run at 31250.
**Confirm the overlay-to-GPIO mapping on the actual device** before the harness is
made.

---

## 3. Control board (Pro Micro) — I/O

Unchanged from the standalone pedal design (`segno_pedal_pcb_design.md`):

- **Footswitches** — D3..D12, each a 2-pin JST-XH header with hardware RC debounce,
  one per pedal (10 total: REC/PLAY, STOP, UNDO, MODE, TRACK1–4, CLEAR, BANK).
- **Indicator LEDs** — D2 → WS2812 chain (330 Ω series). The manufactured V1
  board + firmware carry `indicatorLeds[7]` (index 0 Mode, 1–4 Track1–4, 5 Clear,
  6 Bank); the console design now has a pill above EVERY pedal (10, issue #366) —
  widening the chain + index map to 10 is an open firmware/board follow-up.
- **Ring + encoder** — A3 → ring data (via a 74AHCT125 buffer) and A0/A1/A2 → EC11,
  all over **one 8-pin cable** to the ring board (12× WS2812 ring + encoder).
- **MIDI** — DIN-5 IN through an H11L1 optocoupler (breaks ground loops); DIN-5 OUT
  through a 74AHCT125 buffer; the same 31250-baud stream is mirrored to USB.
- **USB** — the Pro Micro's native USB carries the pedal protocol (USB-MIDI/serial).

---

## 4. Raspberry Pi connections (Pi build)

- **Power** — 5 V from the **external buck into the Pi's USB-C** (see §2). Not 9V,
  not the board's small buck.
- **USB hat (add-on)** — a USB hat on the Pi adds **internal** USB ports, so the
  internal devices don't consume the rear ports:
  - **Pro Micro → USB hat** — control/MIDI data (keeps the existing USB-MIDI firmware;
    the Pi runs the looper engine).
  - **2× screen touch → USB hat.**
- **Screens** — 2× micro-HDMI → 7" (left) + 16" (right) for video; touch over the USB
  hat above. Screen 5V from the external buck.
- **Audio interface** — external USB audio interface on a **rear** Pi USB-A port (line
  in/out live outside the box); the rear ports stay free for it because the internal
  devices are on the hat.
- **Position (#743)** — the Pi moved to the floor **under the 16" screen**
  (u 625, v 316), 50.5 mm clear of the rear wall. There is no longer a window for
  its port stack to reach, and that space is now the connector bay. Its own
  USB-A / Ethernet / HDMI / SD face inward and are **not reachable without opening
  the case** — by intent. Nothing is stacked over it, so it drops from bespoke
  35.3 mm risers to the **same plain 15 mm M2.5 standoffs as the main board**.
  Cable consequence: ~250 mm more to the rear USB couplers, shorter 16" HDMI,
  longer 7" HDMI.

---

## 5. Rear panel mapping

Since #743 there is **no window and no sub-panel**. The rear wall is a folded face
of `segno_base`, and every connector is a panel-mount part fitted directly into
it. Nine stations on one centreline, left to right:

| station | qty | wiring note |
|---|---|---|
| 9 V barrel | 1 | DC-099, 30 V / 10 A |
| power / shutdown button | 1 | **momentary, unlit** → Pi GPIO soft shutdown. Two wires, no 5 V run to the rear panel. This machine has **no power indicator at all**: the two screens are the indicator |
| fuse | 1 | generic 5×20 screw-cap holder (10 A), Ø12.0, in series with the 9 V input ahead of the Y-split. **T5A slow-blow** — fast-blow will nuisance-blow on buck inrush |
| MIDI DIN-5 | 2 | IN + OUT. **IN is opto-isolated on the board** — the socket alone is not enough |
| TRS 6.35 (D-series) | 2 | external control pedals |
| USB 3.0 coupler | 2 | |
| earth stud | 1 | between the cluster and the vent block |

The Pi's own HDMI, Ethernet and SD are **no longer reachable from outside** — that
is deliberate. Anything the build needs comes back out through the stations above,
so a USB coupler wired as a pass-through needs an internal A-to-A lead to the Pi.
The external audio interface is still outside the box on a USB lead.

---

## 6. Grounding & ventilation

Single common ground; the DIN **IN** is opto-isolated to break ground loops. An M6
earth stud on the rear wall bonds the chassis. The Pi sits on its risers in the
rear bay with vent slots in the bottom plate (intake, between the platform rows) and
the rear wall (exhaust) — air crosses the boards/Pi and the Pi's active cooler.

---

*Provisional pending a build: exact buck sizing/splitting and the screen power method
(buck vs separate brick) depend on the final screen modules chosen.*
