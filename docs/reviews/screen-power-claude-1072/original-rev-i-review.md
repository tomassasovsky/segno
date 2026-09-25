# Segno screen-power board (rev I) — independent pre-fabrication review

Reviewed at `HEAD e98256a5`, target `hardware/kicad/screen_power/hand/screen_power_hand.kicad_pcb`, generator sources in the same folder. All findings below were re-derived from the netlist, the `.kicad_pcb`, and manufacturer datasheets — not from the repo's own README or `validation.json`.

---

## 1. Verdict

**Do not fabricate yet. There is one hard, board-level functional fault: the relay contact pins are wrong, and the USB touch path cannot conduct in either relay state.** Everything else I found is either sound, or a cheap improvement, or a preference.

| | Item | Class |
|---|---|---|
| **A** | K101/K201 wired to the two *fixed* contacts (2/4 and 7/5); the **common/pole pins 3 and 6 are left unconnected**. Touch D+/D− are permanently open. | **Blocking — must fix before ordering** |
| B | Q3 tab faces the board interior with 2.90 mm to C2; Q4 tab has 0.81 mm to R4. No production heatsink fits either. | Fix **only if** you want the heatsink option — see §4 |
| C | README's "6 A combined" contradicts its own branch budget (3+3+0.5+0.5 = 7.0 A + 50 mA bleeder) | Documentation fix |
| D | 1.5 mm necks at the FET pins; 220 µF bulk cap C2 hung off a 0.25 mm trace; whole rail crosses layers through F101's single pin-1 barrel | Cheap improvements, not faults |
| E | 0.25 mm default signal width (console benchmark uses 0.6 mm); "2 LAYERS" silk; label placement | Preference |

**Assembled-validation limits (unchanged by this review):** nothing in CAD establishes USB 480 Mbps eye quality through a mechanical relay, real screen inrush vs fuse I²t, relay hot-pickup at maximum enclosure temperature, discharge/shutdown timing, or enclosure fit. Those stay post-assembly.

---

## 2. The blocking fault: relay contact pinout

### What the design does

`switch_circuit.py:112-115`

```python
part("Relay", "IM03", f"K{n+1}", "IM02TS",
     "screen_power:Relay_DPDT_AXICOM_IMSeries_Pitch5.08mm_D0.90mm",
     {1: host, 8: coil, 2: pre+"_UP_N", 4: pre+"_DN_N",
      7: pre+"_UP_P", 5: pre+"_DN_P"}, "1-1462037-3", group)
```

Verified on the actual board — `K101` pads 3 and 6 carry **no net**:

```
pad 1 net='HOST1_5V'          pad 8 net='S1_DATA_COIL_LOW'
pad 2 net='S1_UP_N'           pad 7 net='S1_UP_P'
pad 3 net=''   <-- COMMON     pad 6 net=''   <-- COMMON
pad 4 net='S1_DN_N'           pad 5 net='S1_DN_P'
```

### What the part actually is

TE/Axicom IM relay datasheet **108-98001 Rev. K, page 5, "Terminal Assignment — Relay top view, Non-Latching Type, not energized"**. Rendered at 400 dpi and zoomed 5×, the drawing is unambiguous:

- Pin **7** riser goes up and turns right into a short fixed-contact segment.
- Pin **6** riser goes up and the **moving blade pivots there**, leaning left onto pin 7's contact.
- Pin **5** riser goes up and turns left into the opposite fixed contact.

So, per set: **common = 6, NC = 7, NO = 5**, and by mirror symmetry on the lower row **common = 3, NC = 2, NO = 4**. Coil = 1 (+) / 8 (−), which the design gets right.

Independent corroboration: KiCad 10's own `Relay:IM00` symbol (which `IM03` extends, and which this project uses) draws exactly this — the armature polylines `(0,-2.54)→(-1.905,3.81)` and `(10.16,-2.54)→(8.255,3.81)` pivot on the pin-3 and pin-6 risers.

### Consequence

Pins 2 and 4 are the NC and NO **fixed** contacts of the *same* pole. They are never connected to each other — not de-energised, not energised. Same for 7 and 5. The pole terminals that would bridge them are floating.

**Both touch channels are an open circuit on D+ and D−, permanently.** Neither touchscreen would enumerate. Power switching (Q3/Q4) is unaffected; only the data path is dead.

### Why the existing validation missed it

`check.py:141-143` encodes the same assumption and then *asserts* it:

```python
require(f"K{n+1}", {1:host,8:coil,2:pre+"_UP_N",7:pre+"_UP_P",4:pre+"_DN_N",5:pre+"_DN_P"})
if any((f"K{n+1}",pin) in pins for pin in ("3","6")):
    fail(errors,"relay_contacts",f"K{n+1}: normally closed and unused terminals must be unconnected")
```

The suite would now *reject the corrected board*. The README repeats the error at `README.md:245` ("commons 2/7; normally open 4/5; unused normally closed 3/6"). ERC/DRC cannot catch this — all eight relay pins are `passive`, and `0 unconnected items` only means every *net* is routed, not that the netlist is right.

### Smallest correct fix

Move the host side onto the poles and keep the NO contacts for the screen side (preserving "open when disabled"):

```python
{1: host, 8: coil, 3: pre+"_UP_N", 4: pre+"_DN_N",
 6: pre+"_UP_P", 5: pre+"_DN_P"}
```
plus the matching update in `check.py:141-143` (invert the pins-must-be-floating test to 2/7), and `README.md:245`.

**This is not a netlist-only edit — the local routing must be redone.** The pole pads sit at x = 28.6, one position inboard of the current 26.4. The upstream pair currently fans out from x = 24 to pads 2/7; the pads 2/7 holes still physically exist (the part has those pins), and the 2→3 pad gap is only 0.8 mm edge-to-edge, so a 0.85 mm trace cannot thread between them.

The clean route: **extend the coupled section along the relay centreline** (y = 36.0 / 61.0 sits exactly midway between the two 33.46 / 38.54 pad rows, giving a clear 3.68 mm channel) from x = 11 all the way to x ≈ 28.6, then fan out vertically ±2.54 mm straight down/up onto pads 3 and 6. That keeps the pair coupled for its whole run, keeps the fanout symmetric (zero added skew), and clears pads 2/7 entirely. One knock-on: the explicit F.Cu coil-return channel at x = 29.70 (`route_critical.py:57-60`) would then sit 0.55 mm from the new B.Cu fanout edge — nudge it to ~x = 30.0 or re-plan it, then re-run the plane-continuity sampling.

---

## 3. MOSFET losses — worked numbers

### 3.1 Actual gate drive (verified from the circuit, not assumed)

`POWER_GATE` sits on a divider between `COMMON_SOURCE` (via R4 = 330 kΩ) and Q1's saturated collector (via R3 = 4.7 kΩ). With Q1 sinking only ~0.62 mA (14 µA through R3+R4, plus ~0.61 mA of Q2 base current via D1/R5) against ≈2.6 mA of base drive from GPIO17 through R1, Q1 is deeply saturated (β required ≈ 0.24).

| AUX | V<sub>CE(sat)</sub> | I | V<sub>GS</sub> |
|---|---|---|---|
| 5.00 V | 0.05 V | 0 A | **−4.88 V** |
| 5.00 V | 0.05 V | 6 A | −4.77 V |
| 5.00 V | 0.20 V | 6 A | −4.62 V |
| 5.25 V | 0.05 V | 6 A | −5.02 V |
| 4.75 V | 0.20 V | 6 A | −4.38 V |

So the **−4.5 V datasheet column is the correct one**, and the README is right to use it. Reading the datasheet's *R<sub>DS(on)</sub> vs V<sub>GS</sub>* curve (p.4), −4.6 V is comfortably past the knee (~3.5–4 V), so the FETs are fully enhanced; the design is not sitting on the cliff.

### 3.2 Datasheet values used

[Vishay SUP70101EL, Doc 77632, Rev. A 20-Feb-17](https://www.vishay.com/docs/77632/sup70101el.pdf) — P-channel, −100 V, TO-220AB:

- R<sub>DS(on)</sub> **max 0.0150 Ω / typ 0.0114 Ω at V<sub>GS</sub> = −4.5 V, T<sub>J</sub> = 25 °C** (p.2)
- R<sub>θJA</sub> **40 °C/W typical**, footnote b: *"when mounted on 1″ square PCB (FR4 material)"*; R<sub>θJC</sub> 0.4 °C/W (p.1)
- T<sub>J,max</sub> 175 °C; C<sub>iss</sub> 7000 pF; Q<sub>gs</sub> 29 nC, Q<sub>gd</sub> 30 nC @ 50 V; R<sub>g</sub> 6.5 Ω typ
- Temperature multiplier from the *On-Resistance vs. Junction Temperature* curve, V<sub>GS</sub> = 4.5 V trace (p.4): 1.00 @ 25 °C → 1.35 @ 100 °C → 1.78 @ 175 °C. I linearised this as **k(T) = 1 + 0.0052·(T − 25)** (slightly conservative between 75–125 °C).

**The 40 °C/W does not apply to this board.** The footprint is `TO-220-3_Vertical` with **no tab pad** — pads 1/2/3 only. The tab is unsoldered and in free air; the only conduction path is three leads into 1.5 mm traces. The honest number is the classic free-air TO-220 figure, ~62 °C/W. I bracket 40 (optimistic / datasheet condition) to 75 (still, hot air) below.

### 3.3 Self-consistent iteration

Solving P = I²·R₀·k(T<sub>J</sub>), T<sub>J</sub> = T<sub>A</sub> + P·R<sub>θJA</sub>, **per device** (both carry the same series current):

| Current | Case | T<sub>A</sub> = 50 °C, 62 °C/W | T<sub>A</sub> = 60 °C, 75 °C/W |
|---|---|---|---|
| **3.25 A** | nameplate-current reading of your bench notes (1.4 + 0.8 + 2×0.5 + R8) | 0.19 W → **T<sub>J</sub> 62 °C** | 0.20 W → **75 °C** |
| **4.25 A** | worst power-field reading (10 W + 6 W)/5 V + 2×0.5 A touch + R8 | 0.34 W → **71 °C** | 0.36 W → **87 °C** |
| **6.0 A** | README's stated shared design load | 0.74 W → **96 °C** | 0.81 W → **121 °C** |
| **7.0 A** | actual sum of the branch budgets (3+3+0.5+0.5) | 1.09 W → **118 °C** | 1.22 W → **151 °C** |
| 9.5 A | sum of fuse ratings (not a design point) | 2.71 W → 218 °C | thermal runaway |

Pair totals and rail drop at T<sub>A</sub> = 50 °C / 62 °C/W, using the **max** 15 mΩ:

| I | R<sub>DS(on)</sub> hot | 2·I·R (drop) | pair loss |
|---|---|---|---|
| 3.25 A | 17.9 mΩ | 0.116 V | 0.38 W |
| 4.25 A | 18.6 mΩ | 0.158 V | 0.67 W |
| 6.00 A | 20.5 mΩ | 0.246 V | 1.48 W |
| 7.00 A | 22.2 mΩ | 0.311 V | 2.18 W |

(With the 11.4 mΩ *typical* part the 6 A case falls to T<sub>J</sub> 83 °C, 0.178 V, 1.07 W.)

Note the README's "1.08 W at 6 A" is the **25 °C** figure; the hot figure is ~1.5 W and the rail drop is **0.25 V**, which matters for a 5 V screen at the end of a 28 AWG lead.

### 3.4 Turn-on transient — not a thermal concern

Gate charge for a 0 → −5 V swing at V<sub>DS</sub> = 5 V is ≈ 52 nC per FET (Q<sub>gs</sub> 29 + Miller ≈ 12 using C<sub>rss</sub> ≈ 2400 pF near 0 V + C<sub>iss</sub>·ΔV ≈ 10), 103 nC for the pair. Pull-down current through R3 starts at 1.05 mA, so the **transition takes ≈ 140 µs** — a crude but real soft-start.

Capacitive-charge energy is fixed at ½CV² regardless of speed and is **split between the two series FETs**: 6.2 mJ each for 1000 µF of aggregate load, 15.6 mJ each for 2500 µF. Over a ~140 µs–2 ms transition on a TO-220 (Z<sub>th(JC)</sub> at 200 µs ≈ 0.03 °C/W), the transient junction rise is single-digit °C. **No SOA or thermal issue at turn-on.** Fuse-clearing overcurrent (say 12 A for ~50 ms until the 4 A fuse opens) gives ~5 W for 50 ms — also negligible.

Turn-off is the slow edge: gate RC = R4 · 2C<sub>iss</sub> = **4.6 ms**, so ~20 ms to fully off, versus relay release in a few ms (lengthened by the 1N4007). Data disconnects before power, which is the correct order for a USB host. Good.

---

## 4. Heatsinks: need, room, isolation

### Need

**No. Bare, upright, no heatsink is defensible at every load you have evidence for.** Even at the pessimistic 4.25 A reading in a 60 °C enclosure with 75 °C/W, T<sub>J</sub> is **87 °C** against a 175 °C limit — 88 °C of margin, and R<sub>DS(on)</sub> self-heating is stable (the runaway term I²R₀aθ = 0.10, far from 1). Even the README's own 6 A design load lands at 96–121 °C, still inside spec.

The number that *is* uncomfortable is the 7 A sum-of-branches case in a hot box: **151 °C**, i.e. no meaningful margin. Which brings up:

> **README inconsistency (item C).** "Shared design load: up to 6 A combined" does not agree with "design for 3 A continuous" per main branch × 2 plus "500 mA" per touch branch × 2 plus R8's 50 mA = **7.05 A**. Pick one number and make the copper, the fuse choice and the thermal statement agree with it. The physically honest number for your screens is ~3.3–4.3 A; if you state 4.5 A shared, everything on this board has real margin and the sentence stops contradicting itself.

### Room — the owner's instinct is correct

Measured from the board file (courtyards and F.Fab package outlines):

| | Package (F.Fab) | Metal tab band | Tab faces | Nearest obstruction |
|---|---|---|---|---|
| **Q4** (rot 0) | x 26.00–36.00, y 5.80–10.20 | y 5.80–7.07 | **−y, toward the top board edge** | **R4 courtyard at y 4.995 → 0.81 mm**; then 5.0 mm to the edge |
| **Q3** (rot 180) | x 39.00–49.00, y 5.80–10.20 | y 8.93–10.20 | **+y, into the board interior** | **C2 courtyard at y 13.10 → 2.90 mm** (C2 is a D6.3 radial, ~11 mm tall) |

Package-to-package gap is 3.00 mm, and because the tabs face *opposite* ways they never face each other — that part is fine.

The 3D render confirms this directly: Q4 shows black plastic toward +y with the tab plate behind it; Q3 shows the bare silver tab plate facing +y at the camera. Both tab mounting holes are unused and both packages stand ~15.5 mm tall on three 1.4 mm-hole leads — they are the tallest things on the board by ~5 mm and are **mechanically unsupported** in a floor console.

**No production clip-on TO-220 heatsink fits.** The smallest common types (Aavid 577002B, Fischer FK 224) project 9.5–16 mm from the tab face. Q3 has 2.90 mm before C2; Q4 has 0.81 mm before R4's body (R4 is only ~2.5 mm tall, so a heatsink whose fins start above ~3 mm would clear it and then overhang the board edge). A flat 20 × 20 × 1.5 mm bolted plate is the only thing that fits Q3, and it would lie over live copper.

### Isolation — genuinely hazardous if you retrofit

Both tabs are live drains at different nets: **Q3 tab = AUX_5V, Q4 tab = SWITCHED_5V**. The F.Cu ground pour fills right up to both footprints, and Q3's heatsink shadow (x 41.8–46.0, y 11–15.2) contains a live 0.25 mm AUX_5V trace. A bare metal heatsink resting on the board there shorts a drain to the GND pour through any solder-mask nick. The README's "do not fit an uninsulated shared heatsink" is right but understates it — even *individual* heatsinks need an insulating pad or standoff here.

### If you want the option, do this instead (free, and better)

**Lay Q3 and Q4 flat, tab down, each tab soldered to its own large drain-net copper pad with an M3 hole through an isolated island** (AUX_5V for Q3, SWITCHED_5V for Q4, on the front pour with a keepout around each). This simultaneously:

- drops R<sub>θJA</sub> toward the datasheet's 40 °C/W or better (the tab is the 0.4 °C/W path; the leads are not),
- removes the 15 mm unsupported vertical part and the mechanical risk,
- gives 100 % isolation from GND by construction (no bare metal above the board),
- costs one M3 screw and two shoulder washers, no new expensive parts, no SMD.

Room exists: the strip y 2–12 across x 26–49 currently holds R4, Q3, Q4 and nothing else; R4 is a 10.16 mm axial that can move down beside R3. This is worth doing **only** if you want a thermal-upgrade path — the numbers in §3.3 say you don't need one for your actual screens.

---

## 5. Copper, routing and USB — audit

### Measured, and fine

- **Widths**: 4.5 mm F.Cu shared trunk (x = 64, y 28→65.25); 3.0 mm B.Cu/F.Cu branches; 2.0 mm main outputs; 0.8 mm touch; 1.5 mm device-pin necks. IPC-2221 external rise at 35 µm:

  | width | 6 A | 7 A |
  |---|---|---|
  | 4.5 mm | 6.8 °C | 9.6 °C |
  | 3.0 mm | 13.2 °C | 18.8 °C |
  | 1.5 mm | **41.5 °C** | **58.9 °C** |

  2.0 mm @ 3 A = 5.3 °C; 0.8 mm @ 0.75 A = 1.0 °C. All comfortable except the necks (below).

- **Ground return**: both pours fill. F.Cu is a **single 3840 mm² island with zero holes**; B.Cu is 3193 mm² plus one 20 mm² pocket at the R7 pull-down that is stitched by the explicit via in `route_critical.py:106-108`. Sampling every 0.5 mm in y, the narrowest horizontal cut still has **34.8 mm of F.Cu + 14.9 mm of B.Cu** (at y = 65). Return impedance is a non-issue; DRC reports 0 violations and 0 unconnected items.

- **USB pairs**: 0.85 mm / 0.16 mm gap on B.Cu, no data vias, referenced to the F.Cu pour. Lengths are **exactly matched intra-pair by construction** (UP 20.55 mm each, DN 26.35 mm each) because `pair()` in `route_critical.py:20-46` generates symmetric mitered offsets from a shared centreline. I independently sampled the F.Cu fill at 0.1 mm steps under the centre and both edges of all 40 USB segments (5688 points): **91.4 % over solid ground, and every single miss is inside a through-hole pad anti-pad** (x 7.0–8.1 = J101/J201, x 54.9–56.0 = J102/J202, x 25.5–26.4 and 30.8–31.6 = relay pads). Outside pad voids, reference continuity is unbroken.

- **Plane slots near the pairs**: the only F.Cu tracks anywhere near the corridors are the 0.25 mm coil-return channel at x = 29.70 (deliberately threaded between the relay's two contact columns — this checks out; there is no USB copper between x 26.4 and 30.8 on B.Cu) and the 0.25 mm HOST_5V diagonal 1.6 mm below the UP pair. The 4.5 mm SWITCHED trunk is at x = 64, well clear of the pairs' x ≤ 56 extent. **This is careful, deliberate work and better than typical two-layer practice.**

- **Impedance**: my own Hammerstad estimate for 0.85/0.16 on 1.53 mm FR-4 lands ~95–100 Ω differential against KiCad's 89.6 Ω; either way it's inside USB 2.0's 90 Ω ±15 %. With 20–26 mm of trace at a ~500 ps rise time, mismatch is second-order anyway. The real USB risk is the **relay contacts in series**, which no geometry fixes and no CAD check can qualify. Correctly acknowledged in the README.

### Real weaknesses (not faults — cheap to fix, worth doing with the relay reroute)

1. **1.5 mm necks at the FET pins.** `route_critical.py:64-66, 70`: AUX ≈ 6.1 mm, COMMON_SOURCE ≈ 5.6 mm (Q3) + 3.7 mm (Q4), SWITCHED 3.05 mm. IPC-2221 says 41.5 °C at 6 A for an *isolated infinite* trace; these are 3–6 mm stubs bounded by 2 mm pads and 3 mm copper, so the real rise is much lower. But the pads are 1.905 mm wide and the traces leave **perpendicular to the pad row**, so you can widen to **1.9 mm for free** without touching pad-to-pad clearance. That takes the IPC figure from 41.5 °C to 28 °C. Do it.

2. **C2's 220 µF bulk cap hangs off a 0.25 mm trace.** `AUX_5V` runs 3.0 mm from J1 to (47, 11), then C2 is fed by a ~6 mm run of **0.25 mm** from (46.018, 11) → (41.818, 15.2) → C2. The only bulk energy storage on the board is connected by a signal-width trace, which defeats most of its inrush/droop value. Widen to 1.5–2 mm and shorten. Same for C1's 5.7 mm 0.25 mm run (cosmetic — there's no switcher on this board, so C1 does little either way).

3. **The entire rail changes layers through F101's pin-1 barrel.** `route_critical.py:68-72` states this as a deliberate choice ("no power vias are used"). Electrically it's fine: a 1.0 mm barrel is ~0.35 mΩ, and the fuse's 0.64 mm lead is soldered on both faces in parallel — call it 5 mW at 4 A. But it means F102, F201 and F202 (up to 4 A in the stated design case) **depend on the quality of one fuse's two solder joints**, and there is no redundancy if F101 is ever desoldered or replaced. Two or three 0.6/0.3 mm stitching vias beside that pad cost nothing and remove the single point of failure. (17 vias on this board vs 128 on the console benchmark — you have room to be generous.)

4. **Fuse derating.** 500 mA in a 750 mA fast fuse = 67 % (≈76 % after ~12 % ambient derate at 50 °C) — acceptable, but the touch current is unmeasured and the README itself notes a screen may join its two supplies internally. 3 A in a 4 A = 75 % (≈85 % derated) is right at the usual guidance limit; your actual branch current is ~1.4–2.0 A so in practice it's fine. Worth stating the real expected current rather than the 3 A budget.

5. **No reverse-polarity behaviour on J1.** Keyed VH makes this unlikely, but if AUX is reversed, C2 (polarised) is reverse-stressed and Q2's E-B junction sees 5 V against a 2N3906 V<sub>EBO</sub> of 5 V. One sentence in the assembly notes; no circuit change warranted.

6. **Off-state gate impedance.** R4 = 330 kΩ means any leakage into `CONTROL_SINK` develops V<sub>GS</sub> = −I·330 kΩ. At 5 µA (1N4148's 150 °C worst-case I<sub>R</sub>) that's −1.65 V, at the threshold. At any realistic enclosure temperature leakage is <100 nA → −33 mV, so this is fine — but it is the one place where a 10× lower R4 (33 kΩ, still only 150 µA of Q1 collector current) would buy a large margin for nothing. Optional.

### Preference, not correctness

- **0.25 mm default signal width.** The console benchmark (`out_console/segno_console_board.kicad_pcb`, 99.6 × 99.6 mm, 2 layers, 66 parts) routes at **0.6 mm** with 0.4/0.7/0.8/1.7 mm specials. 0.25 mm here is manufacturable but visually and practically thinner than your own house style, and thin for a board you'll probe and rework by hand. 0.4–0.5 mm as the class default would match the benchmark and cost nothing — `DATA_ENABLE` alone is 102 mm of 0.25 mm trace snaking around the board.
- **Silkscreen.** All texts are on-board (tightest: '4 GND' at x = 0.49 mm, 'SEGNO SCREEN POWER / REV I' at y = 0.67 mm — legal but close enough that JLC may blur them; 0.3 mm is the usual floor). The per-pin `1 +5V / 2 D− / 3 D+ / 4 GND` maps on the back are functional, not gratuitous, and I'd keep them. `'2 LAYERS'` at (27, 73.5) B.Silk (`finish.py`) is a fab note living on the product — drop it. `'5V IN'` appears identically on both faces at the same coordinates; harmless, mildly redundant. `'SEGNO SCREEN POWER'` floating at (26, 50.5) in the middle of the field reads a bit unplaced next to the console board's tighter labelling.
- **Connector alignment is good and meets your brief**: left column x = 7 (J2, J101, J201), right column x = 56 (J1, J103, J102, J203, J202), all vertical rows, pin 1 consistently at largest y.

### Things I checked that are correct — don't re-litigate them

- **Back-to-back topology.** Q3 D=AUX / Q4 D=SWITCHED, sources joined, R4 pulling the gates to the *joined sources* (not to AUX). Both body diodes point into `COMMON_SOURCE`, so the off-state blocks in both directions and a live panel on a dead AUX cannot back-feed. Correct.
- **D1 orientation.** KiCad `Diode:1N4148` pin 1 = K, pin 2 = A. Net: K = `CONTROL_SINK`, A = `BUFFER_SINK`. Conducts base current into Q1, blocks `CONTROL_SINK` being dragged toward a dead AUX. Exactly as the comment claims.
- **D101/D201 flyback.** K = HOST_5V, A = coil-low. Correct.
- **Q1/Q2 (EBC) and Q101/Q201 (S-G-D).** All symbol pin functions match the TO-92 parts.
- **Host isolation.** `HOST1_5V` = {J101.1, K101.1, D101.1, C101.1} only. Pi VBUS reaches nothing but its own coil and bypass. This is the safety property the whole board exists for, and it holds.
- **Coil pickup.** 4.75 V × (145·0.9)/(145·0.9 + 5.3) = 4.565 V vs TE's 3.38 V operate at 23 °C. Arithmetic is right; hot pickup still needs measuring.
- **R8 footprint/part.** `PR01000101000FA100` is a Vishay PR01 — **1 W in an 0207 case** (6.3 × 2.5, 0.6 mm leads), so `R_Axial_DIN0207_P10.16mm` with a 0.8 mm drill is correct. I initially suspected a 0414 mismatch; it isn't one.
- **Fuse footprint.** `Fuse_Littelfuse_251_P12.70mm` documents 7.11 mm body / 0.64 mm leads in 1.0 mm holes — correct for the subminiature 251, not the 5 × 20 mm cartridge.
- **Mounting keepouts.** 3.5 mm NPTH with 4.25 mm copper keepouts on both faces at (4,4), (64,4), (4,72), (64,72); no track or via intrudes; R8 and its trace clear H3/H4.
- **DRC.** `kicad-cli pcb drc --severity-all` → **0 violations, 0 unconnected items** at KiCad 10.0.4.

---

## 6. Assumptions and confidence

| Claim | Confidence | Basis |
|---|---|---|
| Relay commons are pins 3 and 6 | **Very high** | TE 108-98001 Rev. K p.5 terminal-assignment drawing read at 5× zoom, **and** KiCad `Relay:IM00` symbol armature geometry. Two independent sources agree; the repo disagrees with both. |
| Touch D+/D− are open in both states | **Very high** | Follows directly, plus `K101/K201` pads 3 and 6 confirmed netless on the board file. |
| R<sub>DS(on)</sub>, R<sub>θJC</sub>, T<sub>J,max</sub>, C<sub>iss</sub>, Q<sub>g</sub> | **High** | Vishay 77632 Rev. A, pp. 1–2. |
| Temperature multiplier k(T) | **Medium-high** | Read off the p.4 curve by eye; ±5 %. Conservative in the mid-range. |
| **R<sub>θJA</sub> ≈ 62 °C/W** for this mount | **Medium — this is my judgement, not a datasheet value** | The 40 °C/W figure is explicitly for a 1″-square PCB mount; this footprint has no tab pad and the tab is in free air. 62 °C/W is the standard free-air TO-220 figure. I bracketed 40–75; the verdict (no heatsink needed) holds across the whole bracket for your loads. |
| Screen currents | **Low — deliberately** | Your bench fields are mutually inconsistent, so I used them only as *bounds*: 3.25 A (current readings) and 4.25 A (wattage readings), and separately tested the README's 6 A and the branch-sum 7 A. I did **not** treat any of them as a measured simultaneous maximum, and the "no heatsink" verdict survives all four. |
| Trace ΔT | **Medium** | IPC-2221 external, 35 µm. Conservative for short necks bounded by large pads — it assumes isolated infinite traces. |
| Differential impedance | **Low-medium** | My closed-form estimate (95–100 Ω) and KiCad's (89.6 Ω) bracket the target. Not orderable as controlled-impedance on 2 layers anyway. No USB compliance claim either way. |

**Not examined:** gerber/drill output (no `hand/fabrication/` exists in this worktree — it's gitignored, so nothing here has been sent to a fab), the `.kicad_sch` sheets' visual correctness, `COSTS.md`, 3D model fidelity, cable/harness fit, enclosure fit.

**Note on any already-published package:** if a Gerber set was exported from this revision elsewhere, it carries the relay fault. Regenerate after the fix rather than patching.

---

## 7. What I'd do, in order

1. **Fix the relay pins** (`switch_circuit.py:114-115` → 3/6 as poles, 4/5 as throws), invert the `check.py:142-143` floating-pin assertion to pins 2/7, correct `README.md:245`.
2. **Reroute the upstream pair** down the relay centreline to x ≈ 28.6 with a symmetric vertical fanout onto pads 3/6, and nudge the x = 29.70 coil channel clear. Re-run DRC and the plane-continuity sampling.
3. Widen the four FET necks 1.5 → 1.9 mm, widen C2's feed to ~1.5 mm, add 2–3 stitching vias beside F101 pin 1.
4. Reconcile the 6 A / 7 A statement to a single honest number (~4.5 A shared is defensible for your screens and makes everything else consistent).
5. Decide on the TO-220 mount. **Upright-with-no-heatsink is thermally fine** — the only reasons to change are the mechanical robustness of a 15 mm unsupported part in a floor console and keeping a thermal upgrade path. If you want either, lay them flat with tab-soldered isolated drain pads; otherwise ship them upright and leave R4/C2 where they are.
6. Then order bare boards.

Sources: [Vishay SUP70101EL (Doc 77632)](https://www.vishay.com/docs/77632/sup70101el.pdf) · [TE/Axicom IM Relay 108-98001](https://www.farnell.com/datasheets/477186.pdf) · [JST XH](https://www.jst-mfg.com/product/pdf/eng/eXH.pdf)