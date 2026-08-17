# Segno — sheet-metal enclosure for the segno Pi loopstation

A wedge-shaped folded-aluminium console that houses this repo's standalone build
(a Raspberry Pi + the V1 [`segno_pedal_main`](segno_pedal_pcb_design.md) board)
and **integrates ten foot pedals
into the chassis** the way the real "Chewie II" / Sonnit reference does. Form
(850 × 465 × 100 mm, top sloping toward the player) and layout from the reference;
internals are this project's. Branded **Segno**.

The deliverable is a **manufacturing package** (STEP + DXF + PDF) produced by the
parametric generator [`enclosure/segno_enclosure.py`](enclosure/segno_enclosure.py),
validated by an in-generator **assertion suite** (see §8). Decisions came from
[brainstorm](../docs/brainstorm/2026-06-27-segno-enclosure-brainstorm-doc.md) →
[research](../docs/research/2026-06-27-segno-components-research.md) →
[plan](../docs/plan/2026-06-27-feat-segno-enclosure-rework-plan.md) → technical review.

> **Integrated pedals.** The foot controls are ten **whole Cherub WTB-006
> footswitches** (109.87 × 76.35, 29.3 mm tall incl. anti-slip pads, caliper-
> measured — `hardware/cherub_wtb006_pedal/`), modded so their switch leads wire
> straight to the board. Each **stands on a printed pedestal**; the pedal
> protrudes through a ~79 × 116 mm slot (slot depth is slope-corrected: the slot
> lives in the 12.5° faceplate but the pedal is horizontal). **No top-face
> fasteners; no cables leave the box.**

---

## 1. Overall geometry & construction

| dimension | value | note |
|-----------|-------|------|
| Width `W` | **850 mm** | reference footprint |
| Depth `D` | **397 mm** | sized to a comfortable gap behind the front row (no dead band) |
| Rear height | **100 mm** / front lip **12 mm** | low-raked wedge |
| Top slope | **12.5°** | sloped length 407 mm |
| Material | **2.0 mm 5052-H32 aluminium** | bend R 2.0, K 0.33 |

**Construction = folded lower body + removable top lid.** **Nothing on this build
is welded.** `segno_base` is ONE flat blank: the bottom plate in the centre with
the front, rear and both side walls as flaps that fold up 90° on its four bottom
edges, and the rear flap folding a second time into the transition shoulder. The
four vertical corners are open butt seams closed by **riveted internal
L-brackets**. That keeps the whole shell inside a cut + bend + powder-coat
instant quote, with no fabrication step that needs a welder. The
**faceplate is a removable lid**. The faceplate is **not a bare plate** — it is a
shallow pan whose front lip, rear edge and **both sides fold down into skirt
flanges**, and the **screws go through those skirt flanges**, never through the
faceplate's top face. The lid drops over the body, **resting on the walls' inward
top flanges** (a support ledge), and M4 screws pass through each **wall web** into
the down-turned **lid skirt** behind it — so every fixing sits on a vertical face
(front lip + the two sides), hidden from the playing surface. Lifting the lid takes
the **screens, the encoder/ring PCB and the indicator LEDs** with it, while the
**pedals stay on their printed platforms** in the lower body (the slots clear the
pedals straight up) — so service is "back out the side + front-lip screws and lift
the lid," and the Pi/board are reached from the open top.

```
  REMOVABLE TOP LID                       FOLDED LOWER BODY (weld-free)
  └ faceplate pan (cutouts) + down-turned ├ front wall (12) + top flange (lid ledge)
    front/side/rear skirt flanges +       ├ rear wall (100) + I/O + vents + top flange
    screens + encoder/ring PCB + LEDs     ├ 2× side panel + top flange (lid ledge)
    (screws through the skirts)           ├ bottom plate (centre of the blank)
                                          └ 10× printed ring + sled + pedals
```

Per-edge intent: the wall **bottom edges fold** up from the bottom plate (they are
the same piece of metal, so there is no joint at all); the wall+side **top edges fold** to an
inward flange that the lid **rests on** (support ledge, no fixings on the top face);
the lid's **down-turned skirt flanges** take M4 screws driven horizontally through
the **wall webs** (front lip + both sides), so no fixing ever pierces the faceplate
surface.

---

## 2. Foot pedals on printed pedestals

Ten whole **Cherub WTB-006** footswitches stand inside on printed pedestals,
toe toward the player, protruding through the top slots — giving the
reference's piano-key look with no visible fasteners and the switch wiring
fully internal.

- **Slot:** `FSW_SLOT_W` 79.35 (u) × `FSW_SLOT_D` 115.61 (v) mm — the WTB-006
  envelope (76.35 × 109.87) + 3 mm clearance, with the slot depth divided by
  cos(slope) because the slot lives in the sloped faceplate while the pedal is
  horizontal. **No mounting holes** in the faceplate.
- **Pedestal = RING + SLED** since #719 (`segno_platform_front_ring` ×8,
  `_mid_ring` ×2, and ONE `segno_platform_sled` ×10). The pedal bolts to the sled
  on the bench, sled and pedal drop into the ring as a unit, and the **four
  existing chassis screws** pass up through clearance holes in the ring's floor
  and thread into the sled — clamping ring + sled + base plate in one joint, so
  the ring needs no fastener of its own and `segno_base.dxf` does not change.
  The ring's seat sits `CONSOLE_SLED_T − 1.0` below the old deck line, so once
  the sled is on it the pedal's CASE TOP still lands **flush with the slot's
  upper (rear) rim** exactly as `platform_h(v)` (front ≈ 15.2, mid ≈ 59.3 mm)
  put it — issue #373's rule is untouched, and an assertion holds the metal base
  to the same z to 1e-9 rather than trusting the arithmetic. Perimeter strips
  outside the opening are relief-shaved to ~0.3 under the real plate
  (drift-calibrated); side-screw bosses keep ~1 mm under the faceplate. The
  bottom anti-slip pad now comes **off** (the base holes are under it), so the
  1.2 mm pad pocket is gone and the joint clamps metal-to-plastic. The
  `PLATFORM_HEADROOM` assertion still enforces headroom against the local lid
  height.
- **Layout (two rows, per the reference):** a front row of **8 evenly-spaced**
  pedals (REC/PLAY · STOP · UNDO · MODE · TRACK 1–4) and an upper pair **CLEAR /
  BANK aligned in `u` over UNDO and MODE**, placed so their **label tops align
  with the screens' shared top line** (issue #366). **An LED pill indicator sits
  above EVERY pedal (10 total)** — the board's `indicatorLeds[7]` chain contract
  must widen to 10 (open firmware follow-up). The mid-row platforms are taller (the lid is higher there); the generator
  computes both heights and the depth assertions confirm the 16" screen fits behind.

> The `PEDAL_*` constants are **caliper-measured from a real WTB-006**
> (2026-07-28, issues #358/#360) — unlike the earlier ASP-1 placeholder they are
> no longer provisional. Pedestal **retention** was the last PROVISIONAL piece
> (pocket + gravity; no fastener engaged the pedal) — **retired by #719**: the
> pedal is now bolted to a sled with four M3s.
>
> **Base screw holes (issue #716).** The underside does carry four M3-ish holes
> after all, in two rows — the `PEDAL_BASE_*` constants. They sit *under* the
> anti-slip pad, so both rows are dimensioned off the **side screw axis**, the
> only datum findable without pulling the pad: rear row = axis **+4.0 toward the
> back**, front row = rear row **+80.0 toward the toe**, spans **55.75** (rear)
> and **53.00** (front), symmetric about the centre-line. Bolting through these
> is what will retire the PROVISIONAL retention above — but not before the
> **fit-test jig** proves the pattern on a print (§8).
>
> **The sled (issue #719) — shipped on BOTH the mini console and the 10-pedal
> console.** Those screws go DOWN
> through the base, so the head lands *inside* the pedal and the pedal must be
> open to be fastened. But the shell halves are held by one ~83 mm through-pin
> needing ~91 mm of clear axial run, and the widest gap beside a seated pedal is
> **12.4 mm** in either enclosure — so no wall shape fixes this; the neighbouring
> pedal is the blocker, not the tub. The pedal can therefore only be closed on
> the bench, which means it must be screwed down on the bench too. The deck comes
> out as a separate **sled** (`SLED_T` 7.0) the pedal bolts to, dropped into the
> tub as one unit and retained by a single M3 up through the tub deck. It is a
> `SLED_CLR` 0.2 mm/side slip fit with a 0.6 mm bottom lead-in chamfer — 0.5/side
> printed and seated but wiggled, and since the retention screw only clamps, the
> bore fit is the **only** thing locating the pedal. The clearance lives on the
> SLED (it derives from `SKIRT_IN_*`), so re-tuning it reprints a 19 g part
> rather than the tray. The tub
> deck drops by `SLED_DECK_DROP` = 6.0 so the pedal's metal base lands exactly
> where the pad-on design put it — **nothing above the base moves**, so the
> faceplate, the slot and the flush-at-rim rule are untouched. The bottom
> anti-slip pad comes off (it has to; the base holes are under it), which also
> means the joint clamps metal-to-plastic instead of through 2.2 mm of rubber.
>
> On the **10-pedal console** the ring is a free part, and a ring held only by
> the faceplate keeps 0.30 mm of vertical play — the buzz `SKIRT_GAP` already
> warns about. So it is **SANDWICHED**: the ring gets a floor, the sled lands on
> it, and the four chassis screws pass up through clearance holes in that floor
> into the sled. One joint clamps ring + sled + base plate; the ring carries no
> insert and no fastener. `CONSOLE_SLED_T` 12.633 (thicker than the mini's 7.0,
> because this sled takes M3×5 from **both** faces) leaves `RING_FLOOR` 1.6 on
> the front row and a tall deck on the mid row — same formula, only the front is
> tight. The four stations come from `platform_foot_xy()`, which the ring, the
> sled and `platform_foot_holes()` all read, so **`segno_base.dxf` is unchanged**
> — proven by diffing it to zero substantive lines after the refactor.
>
> **The mini tray is symmetric about `CX = Wt/2`.** It used to inherit the
> pedals' absolute console `u` with its left edge at 0, which left the pair
> 1.74 mm right of centre: the right tub fused into its wall while the left
> needed a filler block, and every hard-coded x — anchors, feet, ribs, lid tabs —
> was tuned around that. Only the *pitch* has to be faithful, so the width now
> follows from the pitch and every x is `CX ± something`; both tubs fuse and the
> filler is gone (195.29 wide, was 198.775). `MINI_SYM` holds it by splitting the
> solid at `CX` and comparing the halves' **mass properties** — volume, centroid
> and inertia tensor. Not by cutting the solid against its own mirror: when the
> part is symmetric the two are geometrically identical, every face is
> coincident, and OCC's boolean returns *empty*, which reads as "totally
> asymmetric" and is the exact opposite of the truth.
>
> **The lid now sits flush on all four sides.** As a flat plate raked to 12.5°
> with square-cut edges, its top face used to stand `T·sin` = 0.43 mm proud of
> the front wall and 0.43 mm shy of the rear, and its square plan corners
> overhung the tray's R6 fillets by `6 − 6/√2` = 1.76 mm. Both dated from the
> first tray. Fixed in one exact operation rather than two computed bevels: the
> lid is built `T·tan` longer at the rear, then — **in the seated frame** —
> intersected with a vertical prism of the tray's own plan outline. Front and
> rear come out plumb and the corners land on the tray's radius at *every*
> height, which a fillet applied in the flat frame could not do (it would rake
> over with the plate). `MINI_FLUSH` holds the seated bbox to the tray outline.
>
> **The case is a wedge in plan, not only in height.** `PEDAL_W` 76.35 is the
> width at the **back edge**; it tapers to `PEDAL_TOE_W` 73.08 at the toe, so a
> clearance quoted off `PEDAL_W/2` is understated by up to 1.63 mm per side.
> Anything sitting close to a side wall must ask **`pedal_half_width(x)`** where
> along the case it actually stands — the faceplate slot already reasons this way
> (its real per-side clearance is ≥1.15, not 1.0), and the fit-test jig's columns,
> scribed outline and clash stand-in all do now too.

---

## 3. Top faceplate — control layout (Chewie-II)

`u` = 0…843 L→R (player's left→right), `v` = 0…468 front→rear.

| feature | qty | size (mm) | maps to |
|---------|-----|-----------|---------|
| WTB-006 pedal slot | 10 | 79.35 × 115.61 | 8 front (evenly spaced) + CLEAR/BANK over UNDO/MODE, no fasteners |
| indicator LED pill | 10 | 60 × 6 slot | one above every pedal (#366; `indicatorLeds` chain must widen 7 → 10) |
| 7" touchscreen | 1 | 156 × 88 aperture | waveform / loop view (left), top-aligned |
| 16" touchscreen | 1 | 350 × 199 aperture | main segno UI (right), top-aligned |
| encoder + diffused ring | 1 | Ø7 + Ø58/40 | centred under the 7" screen at `ENC_V` (does NOT follow CLEAR/BANK rearward — it would hit the 7" screen); EC11 + 12 THT LEDs |
| power / mode LED | 2 | Ø8 | bezel, flanking the encoder |

- **Screens mount from behind**; the aperture is **smaller than the bezel** so the
  monitor clamps against the panel (rear `screen_bracket` parts retain them). The
  16" is a ViewSonic TD1655-class portable touch monitor (355 × 223 × 15 mm).
- **LEDs are 5 mm through-hole, cabled.** The ring is a cut annulus with a diffuser
  + 12 THT LEDs behind.
- **No logo cutout** on the panel (removed). "Segno" remains the product/drawing name.

---

## 4. Rear I/O & ventilation

Rear wall (`u` = 0…850, `z` = 0…90). **There is no I/O window and no bolt-on
sub-panel** (#743): the Pi moved inboard and every connector is a panel-mount
part fitted straight into the wall — which is a **folded face of `segno_base`,
not a welded panel** (`segno_base` is one blank: floor + 4 walls, weld-free,
corner brackets rivet). Losing HDMI / Ethernet / SD access from outside is
deliberate — reflashing or a wired network means opening the case.

Nine stations on one centreline at `REAR_IO_Z` (= wall mid-height, 45), left to
right, power first and away from signal:

| ref | cutout | keep-out | note |
|---|---|---|---|
| `9V_DC` | Ø11.5 | 17.5 | DC-099; listing says Ø11 hole, +0.5 so it cannot rattle before the nut bites |
| `POWER` | Ø16 | 22 | shutdown button — the Pi still needs a clean stop |
| `FUSE` | Ø12 | 18 | |
| `MIDI_IN` / `MIDI_OUT` | Ø15.1 + 2 × Ø3.2 @ 22 | 28.4 | REAN NYS325; **IN needs opto-isolation on the board**, not here |
| `CTRL_1` / `CTRL_2` | **Ø24**, fixings **not cut** | 30.4 | **D-series** punch, not a threaded bushing |
| `USB3_1` / `USB3_2` | 22.5 square, **R8.84** | 28.5 | flange Ø28.5 is the keep-out, not the hole |

The keep-out column is the **nut, bezel or flange a spanner has to clear**, not
the hole — for the USB coupler that is 6.4 mm wider than its own cutout, and
spacing on cutouts alone would have the two flanges fouling. `rear_io_layout()`
spreads the nine across `REAR_IO_SPAN` = 360, left-justified against `EDGE`, with
**equal clear gaps** of 15.99 mm.

> **The TRS is D-series.** The chosen jack (MEIRIYFA, "fits standard D Series
> panel mount designs") takes the Neutrik D punch — Ø24 with an M3 pair — not the
> Ø10 round hole a threaded-bushing jack wants. Neutrik's own datasheet calls it a
> "standardized D sized 24 mm panel cutout". This was wrong in the first cut of
> the panel and is the reason `REAR_IO_KEEPOUT_CONTAINS` exists (below).

That swap took the TRS keep-out from 16 to 30.4 and squeezed the old 290 mm strip
to 7.2 mm gaps, so the cluster was widened to 360. That was only possible because
`REAR_IO_U` used to do **two** jobs — placing the window *and* anchoring the
board, Pi and buck. They are now split: `BOARD_ANCHOR_U` (175) keeps the internal
layout exactly where it was, so a rear-panel change cannot move anything inside.
The width comes out of the vent block, which drops 70 → 63 slots and still runs at
14 880 mm² against a 4 000 minimum.

**22.1 / 24.1 are the coupler's BODY, not the hole it wants**, so the cutout is
body + `USB3_FIT` = **0.2 per side → 22.5 across flats, 24.5 across corners**.
That is deliberately the tight end of a panel fit, because the errors are not
symmetric: too tight is one hole eased with a file in a minute, while too loose
either rattles under the Ø28.5 flange or — if the coupler turns out to be a
snap-in — never grips, and that cannot be undone on a cut blank.

The corner radius is **derived, not typed**: `_rr_from_corner_circle()` solves the
across-flats / across-corners pair, giving **R8.836** and only 4.83 mm of straight
edge — that cutout is much closer to a circle than to a square, which is worth
knowing before someone "fixes" it.

**The D-series fixings are deliberately NOT cut.** Its two M3 sit on *diagonally
opposite* corners of the flange, not on a horizontal pair, and no sourced
coordinates were found. The widely-repeated "24 mm" is provably wrong here: on a
Ø24 bore it puts the screw centres exactly on the bore edge — the land gate
reports **−1.60 mm**, i.e. the screw breaks straight into the hole. So the bore
(sourced) gets cut and the fixings wait for the part in hand; `D_TRS_KEEPOUT`
already reserves their room so nothing has to move later. Drilling two M3 in an
assembled chassis is easy; a wrong pair in an 850 mm laser-cut blank is scrap.

### Gates

Seven, all negative-controlled. The important one is **containment**: each station's
own cutouts must fit inside the keep-out it reserved. Without it a station can
reserve less than it cuts and the overlap check passes *on a lie* — which is
exactly what a Ø24 bore behind a Ø10 keep-out did. Next most useful is **land**:
a fixing hole must leave ≥1.5 mm of metal against its own bore, which is what
disproved the 24 mm D-series pitch. The rest: no two keep-outs overlap, none
crosses `EDGE`, the cluster centre really is `EDGE + span/2`, the gap to the first
vent column still fits the earth stud plus a spanner, and the widest keep-out
leaves 4 mm of wall above and below.

### Provenance — every dimension says where it came from

`REAR_IO_PROVENANCE` tags each number `measured` (user's calipers), `datasheet`
(with the source named) or `UNCONFIRMED`. `rear_io_unconfirmed()` returns the
unsourced ones and the build prints them as a **`DO NOT CUT`** line; a gate
refuses any rear-I/O dimension with no entry at all, so a new connector cannot be
added without declaring where its numbers came from. Currently unconfirmed:
**`D_TRS_SCREW_PITCH`** and **`MIDI_SCREW_PITCH`** — the bores are sourced, the
fixing pitches are not.

> **Fallout to settle separately:** the `nopi` build (external host, HDMI ×2 +
> USB touch ×2) had no home but that window, so it is **retired** — an
> external-host variant would now need its own rear-wall DXF. And `PI_RISER_H`
> (35.30) existed only to centre the Pi's port stack in the window; it is kept
> unchanged so this change does not move the internal stack, but it is now
> vestigial.

**Ventilation** (Pi 5 ≤ 12 W; Active Cooler ramps 60/67.5/75 °C): a rear exhaust
vent block + a bottom-plate intake array give ≈ 17 000 mm² open area (`>` the
4 000 mm² floor the `VENT_FREE_AREA` assertion checks). The Pi mounts on **M3
standoffs ≥ 10 mm** off the bottom plate for under-board airflow and Active-Cooler
intake.

**Grounding:** the shell is FOLDED, so walls and bottom plate are literally the
same piece of metal — continuous by construction, no joint to bond across. The
joints that *do* exist are the four riveted corner brackets, and those are
mechanical: powder coat is an insulator, so a rivet through two coated faces is
not a reliable bond. Corner-bracket **faying surfaces must be masked** along with
the bottom-plate perimeter pads, and the rear earth stud is the bond point.
(Previously this paragraph argued from "welded joints are continuous" — true of a
welded shell, and not the shell that gets built.)

---

## 5. Internal mounting & the bottom plate

The pedal platforms hang from the walls at the front + CLEAR/BANK rows, so the
**rear strip of the bottom plate is the clear floor** for the electronics — and the
16" screen above it is shallow (mounts to the faceplate, ~18 mm deep), leaving head
height. The **Raspberry Pi and the `segno_pedal_main` board mount there on
standoffs** (≥ `STANDOFF_H` for under-board airflow), linked over USB (they sit
side-by-side). The **EC11 ring board** mounts to the
faceplate underside behind the encoder cutout; the **screens** clamp to the
faceplate from behind (`screen_bracket`).

The **bottom plate** (`board_mounts()` drives the patterns) is the CENTRE of the
folded blank — the wall bottom edges are its own fold lines, not a joint — and carries: the **Pi** (58 × 49) and
**`segno_pedal_main` board** (85 × 87 M3, measured from its KiCad)
standoff holes in the rear; an **intake-vent block** in the clear gap between the
two platform rows (air crosses the boards to the rear-wall exhaust); and 4 rubber
feet. The electronics are reached from the **open top** once the lid is lifted.

**Rubber feet (#743).** Screw-on, not adhesive — glue lets go eventually on a
thing that gets kicked. The part is a **uxcell buffer foot, Ø18 (chassis face) ×
Ø15 (floor) × 5 mm tall**, rubber with a **metal washer insert** so the screw
pulls against metal rather than rubber. The screw is **not supplied** — an M4 ×
~12 self-tapping pan head. The plate gets a plain **Ø4.5 clearance hole** and the
screw is driven **downward from inside** the case, so its head lands on the
plate's *top* face. That head is the whole reason the
stations sit where they do: at `FOOT_INSET_X` = 14.3 they are **outboard of the
pedestal tubs** (which start at x 24.6), so no ring floor and no sled needs
relieving to clear a screw head. `foot_relief_xy()` reports any fixing that lands
under a pedestal and the gate asserts it comes back **empty**. A second gate pins
`FOOT_INSET_X` inside the 8.2…20.4 window between the bend relief (`RI + T`) and
the tub edge. Stance is 817 × 329.

---

## 6. Sheet-metal notes

- Folded edges (wall bottom flanges): 90°, inside R = `t` = 2.0, **K 0.33** → bend
  allowance 4.18 mm. The vertical corner seams are open butt joints (relief hole
  each) closed by riveted L-brackets, so they take no allowance.
- **PEM:** clinch hole Ø6.3 (distinct from M4 Ø4.3 clearance), ≥ 8 mm edge distance
  — the **18 mm side skirt flanges** host them, so the lid threads straight onto the
  side screws; the **wall webs** get Ø4.3 clearance, and the shallow **9 mm front lip**
  is a clearance hole + nut (too short for a clinch nut).
- DXF layers: `CUT` (thru) · `BEND` (score) · `VENT` · `ENGRAVE` · `NOTE`.
  There is no `WELD` layer: it was declared in all seven DXFs and **empty in every
  one** — a vestige of the original welded-shell plan — so it was removed.
- Finish: deburr → powder coat (mask bond pads).

---

## 7. Material & weight

| material | thickness | mass |
|----------|-----------|------|
| **5052-H32 aluminium** *(default)* | 2.0 mm | **≈ 5.3 kg** |
| Mild steel (CRS) | 2.0 mm | ≈ 15.4 kg |

---

## 8. Generating the package & the assertion gate

```bash
cd hardware/enclosure
python3.12 -m venv .venv && .venv/bin/pip install ezdxf cadquery matplotlib  # one-time
.venv/bin/python segno_enclosure.py            # check + STEP + DXF + PDF -> out/
.venv/bin/python segno_enclosure.py --report   # report + assertions only
.venv/bin/python segno_enclosure.py --no-step   # DXF + PDF only
.venv/bin/python _pedal_base_fit_test.py       # base-hole fit-test jig -> out/
.venv/bin/python _print_check.py out/segno_pedal_base_fit_test.stl   # FDM check
```

**Base-hole fit-test jig** (`_pedal_base_fit_test.py`, issue #716) — a
throwaway print that carries *only* four locating pins on the `PEDAL_BASE_*`
pattern plus the two side columns that capture the horizontal screw bosses
(same `SKIRT_BOSS_CH_*` idiom as the tray tubs). Print it, drop a pedal on it:
all four pins in, both bosses in their channels, case sitting flat = the
pattern is right and the pedestal decks can be bored for heat-set inserts. Its
`SEAT` assertion intersects the jig with a seated pedal stand-in, so a jig that
cannot accept the pedal fails in CAD instead of on the bed. Pins engage only
3.0 mm past the pad — the hole *depth* is unmeasured, and a pin that bottoms
out would hold the pedal proud and read exactly like a placement error.

Before any output the generator runs `_check()` — **the real acceptance gate**.
It raises (build fails) unless every geometry rule holds:

| assertion | guards |
|-----------|--------|
| `WIDTH_BUDGET` | the 10-pedal row + gaps fit across the faceplate |
| `NO_OVERLAP` / `BOUNDS` | no two cutouts intersect; all inside the usable area |
| `PLATFORM_HEADROOM` | foot-plate flush+proud, body fits under the sloped lid |
| `SCREEN_DEPTH` | each module + cable clears the interior; pedal row clears the 16" |
| `VENT_FREE_AREA` | open vent area ≥ target; standoff gap adequate |
| `SCREEN_RETENTION` | aperture < bezel (mount from behind) |
| `PEM` | flange wide enough for the clinch nut |

Outputs in `enclosure/out/` (mm): **STEP** (`segno_assembly` + per-part incl.
`segno_platform_*_ring`, `segno_platform_sled`, `segno_bottom`), **DXF** flat patterns, **PDF** drawing sheets
(the platform parts are print-only). Verification renders
(`out/_hero.png`, `out/_fp_top.png`) confirm 7" left / 16" right.

Everything is parameterised at the top of the script — change a value, re-run, and
the assertions re-validate before re-cutting every panel.

---

## 9. Bill of materials (enclosure only)

| item | qty | note |
|------|-----|------|
| 2.0 mm 5052-H32 sheet | ~1.1 m² | shell + bottom + platforms + brackets |
| PEM M4 clinch nuts | ~6 | lid side-skirt fixings |
| M4 screws (+ ~6 nuts) | ~12 | lid skirt: 6 side (into PEM) + 6 front/rear (screw + nut) |
| M3 standoffs (≥10 mm) | ~6 | Pi / board, airflow gap |
| M6 earth stud + hardware | 1 | chassis bond |
| Rubber feet (uxcell Ø18×15×5, screw-on) | 4 | bottom, `FOOT_INSET_X/Y`; screws not supplied |
| M4 × 12 self-tapping pan head | 4 | foot fixings, driven from inside |
| Screen-retention brackets | 4 + 4 | from `segno_screen_bracket` |
| Diffuser disc (ring) + 12 THT LEDs | 1 | encoder ring |

Pedals, screens, encoder, LEDs, Pi, board and the (external) audio interface are in
the electronics BOMs / `segno_pedal_shopping_list.md`.

---

## 10. Confirm before cutting

The pedal figures (`PEDAL_*`) are now caliper-measured (2026-07-28); the one
family still to confirm from physical parts is the exact **`BIG_*`/`SMALL_*`**
touch modules (one-line param changes, then re-run — the assertions
re-validate).
