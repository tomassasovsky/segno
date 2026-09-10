# Segno — sheet-metal enclosure for the segno Pi loopstation

**Process update, 2026-09-07:** the shop delivers matched parts untapped and
unriveted. The owner rivets before painting, then cleans Ø2.5 body pilots and
cuts all 32 M3 body threads after painting: 18 for the lid and 14 for the screen
supports. This supersedes earlier instructions
to tap at the shop/protect existing body threads. Geometry is unchanged.

A wedge-shaped folded-aluminium console that houses this repo's standalone build
(a Raspberry Pi 5 + the [console board v2](kicad/console_board.py), #747)
and **integrates ten foot pedals
into the chassis** the way the real "Chewie II" / Sonnit reference does. Form
(850 ×423 ×100 mm, top sloping toward the player) and layout from the reference;
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

The fully coated revision has passed local source/export and native metal
verification; physical supplier and assembly acceptance remains open. Current fabrication/process requirements are in
[MANUFACTURING.md](MANUFACTURING.md). Dated historical notes below do not
override those dimensions or the separate metal-shop/painter sequence.

## 1. Overall geometry & construction

| dimension | value | note |
|-----------|-------|------|
| Width `W` | **850 mm** | reference footprint |
| Depth `D` | **423 mm** | 397 mm control-face run +22 mm rear transition +4 mm sheet allowance |
| Rear height | **100 mm** / front lip **12 mm** | low-raked wedge |
| Top slope | **12.5°** | sloped length 407 mm |
| Material | **2.0 mm 1100-H14 aluminium** (Alcast cert, lot 26E0269) | bend R 2.0, K 0.33 |

**Construction = folded lower body + removable lid. Nothing is welded.**
`segno_base` is one blank: floor, four walls and the rear transition shoulder.
Only the two rear corners use internal riveted brackets, one right and one
left with distinct upper profiles. Fit the straight rear seams to 0.00–0.10 mm
bare gap (0.05 nominal) before riveting; keep the required corner reliefs.

The lid has two folds: a front lip and a rear lap. It rests on the side-wall
top edges and rear transition, with nine M3 screws through each folded edge
into tapped body holes. It has no folded side skirts or side fixing screws.
The eighteen lid bores are Ø4.50(+0.10/−0) before coating and use M3 OD 7 head
washers. The front axes are 0.50 mm lower than the old pattern. Nine fitted
solid-metal shim packs support the painted front gap after coating.

The pedals and both screen-support assemblies are anchored to the floor.
Release their actual wiring/retention as needed for service; do not assume the
floor-mounted screens lift with the lid. The ring holder and pill lenses are
attached to the lid underside. The source and current saved Fusion placements
control the assembly sequence and service clearances.

---

## 2. Foot pedals on printed pedestals

Ten whole **Cherub WTB-006** footswitches stand inside on printed pedestals,
toe toward the player, protruding through the top slots — giving the
reference's piano-key look with no visible fasteners and the switch wiring
fully internal.

- **Slot:** `FSW_SLOT_W` 78.35 (u) × `FSW_SLOT_D` 115.61 (v) mm — the WTB-006
  envelope (76.35 ×109.87), with 2 mm total width clearance and 3 mm total
  depth clearance; the slot depth is divided by
  cos(slope) because the slot lives in the sloped faceplate while the pedal is
  horizontal. **No mounting holes** in the faceplate.
- **Pedestal = RING + SLED** since #719. The eight front pedals use
  `segno_platform_front_ring` and `segno_platform_sled`; the two CLEAR/BANK
  pedals use `segno_platform_mid_ring` and the dedicated
  `segno_platform_mid_sled`. The pedal bolts to its sled on the bench, then the
  closed pedal and sled seat in the ring. On the front row, four chassis screws
  pass up through the ring's floor into the sled, clamping ring, sled and base
  in one joint. The tall mid-row collars use separate base and sled joints,
  described below. Both arrangements preserve the existing metal-base holes;
  neither adds faceplate mounting holes.
  The console collars now have 2.4 mm front/rear light-baffle walls and an
  overall depth of 118.47 mm. They grow outward; the 113.67 ×79.15 mm bore,
  sled outer dimensions, chassis screw pattern and pedal height stay fixed.
  `SKIRT_OUT_D` retains the original 115.37 mm mounting datum; `CONSOLE_PLATFORM_D` is the
  larger physical depth used by enclosure-clearance checks.
  The ring's seat sits `CONSOLE_SLED_T − 1.0` below the old deck line, so once
  the sled is on it the pedal's CASE TOP still lands **flush with the slot's
  upper (rear) rim** as set by `platform_h(v)`. The current seats are 2.043 mm
  above the base top at the front and 38.345 mm at CLEAR/BANK. Issue #373's rule
  is untouched, and an assertion holds the metal base to the same z to 1e-9
  rather than trusting the arithmetic. Perimeter strips
  outside the opening are relief-shaved to ~0.3 under the real plate
  (drift-calibrated); side-screw bosses keep ~1 mm under the faceplate. The
  bottom anti-slip pad now comes **off** (the base holes are under it), so the
  1.2 mm pad pocket is gone and the joint clamps metal-to-plastic. The
  `PLATFORM_HEADROOM` assertion still enforces headroom against the local lid
  height.
- **Layout (two rows, per the reference):** a front row of **8 evenly-spaced**
  pedals (REC/PLAY · STOP · UNDO · MODE · TRACK 1–4) and an upper pair **CLEAR /
  BANK aligned in `u` over UNDO and MODE**, placed so the **front edge of their
  slot sits ON the 16" aperture's front edge** — the two pedals and the big
  screen share one hard bottom line (issue #796, owner call; this replaced
  #366's label-top anchoring, a soft glyph edge that lined up with nothing). **An LED pill indicator sits
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
> tub as one unit. The mini uses **two M3 retention screws per sled**, driven up
> through the tray at local depth positions **−30/+30 mm on the centre-line**
> (60 mm pitch). Four top inserts attach the pedal; two bottom inserts retain
> the sled. The nearest opposing insert centres are 28.45 mm apart, leaving
> 23.45 mm between Ø5 insert envelopes. Its 6 mm blind pilots leave 1 mm of
> material at the opposite face. The former central retention hole is removed.
> It is a
> `SLED_CLR` 0.2 mm/side slip fit with a 0.6 mm bottom lead-in chamfer — 0.5/side
> printed and seated but wiggled. The separated fixings resist twisting and
> rocking; their clearance holes are not locating dowels, so the tub still
> sets the pedal's position. The clearance lives on the
> SLED (it derives from `SKIRT_IN_*`), so re-tuning it reprints a 19 g part
> rather than the tray. The tub
> deck drops by `SLED_DECK_DROP` = 6.0 so the pedal's metal base lands exactly
> where the pad-on design put it — **nothing above the base moves**, so the
> faceplate, the slot and the flush-at-rim rule are untouched. The bottom
> anti-slip pad comes off (it has to; the base holes are under it), which also
> means the joint clamps metal-to-plastic instead of through 2.2 mm of rubber.
> The tray has matching Ø3.5 passages and Ø8.5 underside head/driver pockets.
> The nominal head seat to sled underside is 6.176 mm; M3×10 gives 3.824 mm
> insertion without an extra washer. Confirm the real screw, insert, printed
> seating and retention before ordering lengths. Remove both screws before
> lifting the closed pedal/sled unit; do not drive a rod into a blind insert.
> The mini assembly STEP now includes both seated sleds as well as tray/lid.
> Its toe edge is relieved below the sloping lid, preserving the four pedal
> holes and both underside insert roofs. A full-height rectangular sled
> intersects the lid and must not be substituted.
>
> The current mini lid also clears the shared pill diffusers: its two rear
> registration tabs sit in the centre gap at `CX±8 mm`; the rear insert bosses
> are 8.5 mm wide with their original screw axes. This leaves 1.75 mm of material
> on either side of a Ø5 insert and 0.325 mm nominal clearance to the diffuser
> flange. The front boss remains 10 mm wide. The relocated tabs clear the
> modeled Pro Micro pocket and USB window; actual electronics still need a fit
> check. Source tests include both zero and 0.20 mm normal glue gaps beneath
> the diffuser flange. Use the matching current lid, tray, sled and diffuser.
>
> On the **10-pedal console**, all rings are secured to the bottom base rather
> than retained by the faceplate. The eight front rings keep the single joint:
> four chassis screws pass through the pedestal foot, 2 mm metal and the
> 2.043 mm printed floor into the front sled's lower inserts. The foot adds its
> uncounterbored 2.5 mm to the stack, so the nominal M3×8 becomes **M3×12**. Front rings have clearance
> holes and no inserts of their own.
>
> The two **CLEAR/BANK rings use two independent joints**. Their four column
> feet have bottom-facing Ø4.5 ×6 mm blind pockets for M3 Ø5 ×5 mm inserts, on
> the unchanged `platform_foot_xy()` pattern, local X = ±48.685 mm and
> Y = ±22.1875 mm. These screws also pick up a pedestal foot, so the nominal M3×6
> becomes **M3×10** through the foot and the 2 mm metal base into these inserts. Four separate Ø3.7 mm holes cross the 8 mm deck at local
> X = ±30 mm, Y = ±18 mm; nominal M3×12 screws enter the dedicated mid sled's
> bottom inserts from the open underside cavity. Each joint has 4 mm nominal
> bare insertion before any washer or insert recess; coating also reduces the
> base joint's engagement. Check actual insert fit, screw heads, coated stack
> and blind screw-tip clearance on the first PETG prints.
>
> Both console sled variants retain `CONSOLE_SLED_T` 12.633 mm, the same upper
> pedal insert pattern, outer fit and toe relief. Each sled has eight M3 Ø5 ×5 mm
> inserts: four from above and four from below. Only the lower pattern differs.
> The mid collars add eight inserts and eight deck screws across CLEAR/BANK;
> there are 88 inserts across the console's platforms and sleds. No long
> through-screws or metal-hole changes are required. The mini keeps its 7 mm
> sled with two retention inserts on the depth centre-line.
>
> Assemble each CLEAR/BANK module on the bench: install inserts, bolt the pedal
> to its sled and close the case, thread the cable through the closed stadium
> hole, seat the sled, then drive the four deck screws from the collar's open
> underside. Attach the complete module to the bottom base last. For servicing,
> remove the module from the base before accessing those deck screws. CAD fit
> and tool clearance do not qualify the printed joint or enclosure for stomps.
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

`u` =0…846 mm across the control schedule, `v` =0…406.636 mm along the
slope. The full lid blank is 849.8 mm wide; do not confuse these schedule axes
with its outer-edge dimensions.

| Feature | Qty | Current bare opening / interface (mm) | Position / retention |
|---|---|---|---|
| WTB-006 pedal slot | 10 | 78.35×115.610 | Eight front, CLEAR/BANK above UNDO/MODE |
| Indicator pill aperture | 10 | 60.4×6.4, R3.2; +0.10/−0 before coating | One per pedal, unchanged printed insert |
| Seven-inch screen aperture | 1 | 153.75×85.5 | Left, current APROTII module and printed tower |
| Large-screen aperture | 1 | 341.8×191.1 | Right, measured 354×209×14.7 monitor and two stands |
| Ring aperture | 1 | Ø67.4, +0.10/−0 before coating | At frozen `ENC_V`229.159821 mm, left column |
| Encoder centre disc | 1 | BareOD51.20±0.05, straight bore Ø8.50±0.05, no chamfer | Separate metal disc; EC11 nut and purchased knob |

Both screens are supported from the base floor. The fully coated revision
adds 0.20 mm normal screen setback while retaining floor-fixing positions;
the seven-inch module's prior 0.50 mm forward correction remains. Current console
collar hard rims and the sled outer rim receive 0.15 mm normal relief for the
coated floor/lid fit. These allowances do not change the separate mini-console.

The indicators use eight-LED segments of 144 LEDs/m strip in the printed pill
lenses. The selected ring uses the Ring 24/header/Ø80 PCB assembly documented in
`enclosure/FUSION_MODELS.md`; the old 12-THT-LED description is superseded.
There are no separate power/mode lamps beside the encoder. Labels are carried
on the individual pedal tiles; no full-face overlay or logo cutout is required.

---

## 4. Rear I/O & ventilation

The rear connectors mount in a removable **1.2 mm aluminium panel** whose alloy
and temper the shop still has to confirm (the certificate covers the 2.00 mm
sheet only), from
inside the base's rear-wall window. The panel centre follows the main screen;
`rear_io_layout()` spreads nine stations over 360 mm with equal keep-out gaps.
The generated source and `MANUFACTURING.md` define the current revision.

| Ref | Pre-coating opening / finished requirement | Purchased interface |
|---|---|---|
| PD_IN | Raw Ø24.40(+0.10/−0), M3Ø3.60(+0.10/−0), diagonal 19×24 mm | QIANRENON D-series USB-C PD coupler |
| POWER | Raw Ø19.80 ±0.10 | APIELE M19 high-round momentary switch; retaining nut |
| FUSE | Raw Ø12.30 ±0.10 | 5×20 screw-cap holder; retaining nut |
| MIDI_IN / MIDI_OUT | Raw Ø15.50 (+0.10/−0), M3 Ø3.60 (+0.10/−0), pitch 22.2 mm | REAN NYS325 |
| CTRL_1 / CTRL_2 | Raw Ø12.30 ±0.10; final Ø12.00–12.28; finished panel 1.20–1.50 mm | Neutrik NJ6FD-V and snap caps, owner-selected September 4 |
| USB3_1 / USB3_2 | Raw four flats 22.80 ×22.80 clipped by concentric Ø24.80, both ±0.10 | PENGLIN nut-mounted bulkhead, flange Ø28.5 |

The [owner-supplied USB drawing](enclosure/reference/usb3_dimensions.png)
shows **four** flats, 22.1 ×22.1 mm, intersecting a concentric Ø24.1 mm circle.
After coating the opening retains at least 0.2 mm nominal clearance per flat
and radial boundary; verify the actual barrel and retaining nut on a coated coupon. The former tangent rounded rectangle interfered with this profile at
the flat/arc transitions despite matching overall dimensions. A two-flat barrel
description and the former derived R8.836 fillets were incorrect.

The metal shop completes cutting, forming, drilling, deburring and bare fitting,
then delivers the parts untapped and unriveted. The owner installs the corner
rivets before taking the parts to the separate painter.
Paint all enclosure surfaces, including hidden seats and clearance bores.
Only identified electrical ground contacts are protected; the M3 pilots remain untapped.
Coating allowances are included in the raw cutting dimensions; the physical
pattern and coated coupon still require acceptance with actual purchased parts.
After coating, fit nine metal shim packs to the painted front gaps, add the
18 M3 Ø7 washers, and fit felt/light seals during assembly. The owner cleans any
paint-narrowed Ø2.5 pilots and manually taps all 32 M3 body holes: 18 for the lid
and 14 for the screen supports. No other post-paint machining is planned.
Labels are on individual pedals; the
full-face overlay and its export package are retired. Operation instructions
are plain text in [MANUFACTURING.md](MANUFACTURING.md).

**The D-series fixings ARE cut, on the sourced diagonal.** The two M3 sit on
*diagonally opposite* corners of the flange, not on a horizontal pair. The
pattern was sourced 2026-08-18 from the QIANRENON PD coupler's own listing —
"D-type panel mounting dimensions (19 mm × 24 mm)": hole centres at (±9.5, ∓12)
about the bore, one per diagonal. Each screw centre is 15.305 mm from the
bore centre. With the compensated bore and fixing sizes, inspect a minimum
**1.20 mm actual bare web** between holes; this local requirement overrides
general size/position tolerances. Have the shop qualify the actual 1.2 mm stock,
cutting process and complete coupler pattern on a coupon. Diameter compensation
alone does not guarantee the two-screw pattern or local web.

A 180° turn preserves a diagonal pair; it cannot adapt to the opposite diagonal.
The pattern serves only `PD_IN`. CTRL jacks use the separate round hole and
snap cap, with no fixing pair.

### Gates

Source checks cover station containment, spacing, edge/window clearance and
nominal bore-to-fixing material. The fixed hardware station schedule must not
move when raw cut sizes gain coating allowance. Actual local-web and complete
finished-pattern checks still control fabrication acceptance; they are not
replaced by the nominal source assertions. `MANUFACTURING.md` lists the current
raw/finished ranges and physical checks.

### Provenance — every dimension says where it came from

`REAR_IO_PROVENANCE` tags each number `measured` (user's calipers), `datasheet`
(with the source named) or `UNCONFIRMED`. `rear_io_unconfirmed()` returns the
unsourced ones and the build prints them as a **`DO NOT CUT`** line; a gate
refuses any rear-I/O dimension with no entry at all, so a new connector cannot be
added without declaring where its numbers came from.

The current source records the diagonal PD pitch and 22.2 mm MIDI pitch with
their provenance. The removed `D_TRS_SCREW_PITCH` is not an open parameter.
Supplier nominal dimensions still require actual-part checks; generic power
and fuse envelopes do not establish a selected SKU's complete tolerance.

### Power button and fuse

Both were the last stations with no component behind them (they predate #743 and
were briefly mis-recorded as "datasheet: generic …" — "generic" is not a datasheet,
and that was exactly the false authority this table exists to catch). Resolved:

**Button — [APIELE 19 mm high-round momentary](https://www.amazon.com/dp/B079HTQ7XD),
$8.99/2 = $4.50 each.** Stainless, IP65, M19×1, screw terminals, 1,000,000
mechanical cycles, 3-year replacement warranty, **4.7★ over 1,039 reviews**. It
ships a full dimensioned drawing: hole 19 (M19×1), hex bezel **21.9 across flats /
25.0 across corners**, Ø14.1 dome face, 6 mm of dome proud of a 3.5 mm bezel,
24.4 behind the panel.

Chosen over the [UL+CE ZJWZJH](https://www.amazon.com/dp/B09CCPDC1C) at **half the
price**. That part is nicer on paper — UL + CE listed, IP67/IK10, 316 head — but
none of it earns its keep here: this switch is a **dry contact to the Pi's own
3.3 V power-button pads**, not a mains switch on a wet deck, so the certification is
irrelevant to
safety and IP67-vs-IP65 is moot on an indoor rear panel. Against that, APIELE has
1,039 reviews at 4.7 versus 9 at 3.9, and a *taller* head — more dome, more feel.

> **The two constants deliberately bracket both candidates**, so the choice never
> re-cuts the panel. `D_PWRBTN` = **19.5**: an M19×1 thread needs more than 19.0 to
> pass, APIELE's drawing says "19" and ZJWZJH's says Ø19.5, and a Ø25 bezel covers
> the slop either way — cutting 19.0 would jam the ZJWZJH. `PWRBTN_HEAD_D` =
> **25.2**: across hex *corners*, ZJWZJH 25.2 / APIELE 25.0.

**Fuse — a generic 5×20 screw-cap panel holder**, e.g.
[NeoLum, 4 pcs $7.69](https://www.amazon.com/dp/B0GF33P9FF). Generic **by
decision**: it is a small black cap on a rear panel, the one station where generic
costs nothing to look at. Plastic body with a metal cap, which is also the right
way round — an insulating body around a live fuse inside an earthed metal chassis
beats a metal one. 10 A / 250 V AC, far above this job.

`D_FUSE` = **12.0**, from two independent listings ("12 mm diameter aperture";
"Installation Hole 12 mm").

> **That 0.5 mm is the whole point of naming the part.** The
> [SCI R3-11](https://www.amazon.com/dp/B0752BGGRY) — the bayonet-cap holder used
> on guitar amps, nickel hex bezel, solder lugs — wants **Ø12.5**, and the panel
> was briefly cut for it. The error is not symmetric: a 12.5 hole around a 12.0
> thread sits loose and lets the holder **spin when the cap is turned**. So the
> hole follows the holder, never the other way round. If the SCI is ever wanted
> back, `D_FUSE` goes to 12.5 and the panel must be re-cut.
>
> **"Generic" is a class, not a part.** 12.0 holds across the screw-cap holders
> checked, but if a different one is bought, read its stated aperture before the
> panel is cut — this is the cheapest station on the wall and the only one whose
> exact part is not pinned.

> **Rating.** The input is **20 V USB-C PD** (#754): the 59 W worst case is
> ~2.95 A on the 20 V side (~3.3 A with buck efficiency), and these holders are
> **10 A / 250 V AC** — no rating problem. (An earlier 9 V-era note here worked
> the same conclusion from the dead architecture's numbers.)
>
> Fuse: **T5A slow-blow** (T5AL250V). Above the ~3.3 A coincident peak, at the
> 5 A PD contract ceiling, well under the holder's 10 A. **Slow-blow is not optional** —
> two bucks charging their bulk caps draw a large inrush, and a fast-blow fuse
> will nuisance-blow at switch-on. A
> [12-value T assortment](https://www.amazon.com/dp/B08779766V) is worth it over a
> single value: start at T5A and step up only if real measured draw says so.
>
> **Nothing on this unit hard-breaks power.** The button is a momentary contact on
> the Pi's own PWR pads — *not* a GPIO input, which on a Pi 5 could not do this job
> at all (RP1 and the SoC are unpowered until the PMIC brings them up); pulling
> the USB-C PD inlet is the only true off (the 9 V barrel died with the 9 V
> architecture — see `PD_IN` above). Deliberate, but worth knowing.

The external-host `nopi` variant is retired; a future external-host enclosure
would require its own rear-wall design.

### Current rear bay and electronics supports

The older #743 positions, 35.3/15 mm Pi risers and 44.2 mm stack estimates are
superseded. The current Pi hole-pattern centre is `(u,v)=(698.5,281.75)` mm,
with 49 mm across u and 58 mm along v. Its 56×85 mm PCB envelope is
u=670.5–726.5, v=249.25–334.25. These values come from `pi_mount()` and
`pi_pcb_extent()`; use the generated mounting pattern, not an earlier drawing.

The N07 stack uses four 12 mm M2.5 lower standoffs and four 6 mm M2.5 extenders.
The source height budget is 12+7.6+1.6+16=37.2 mm above the bare base floor.
The console board uses separate 15 mm M3 standoffs. Actual kit thread lengths,
board thicknesses, cable routes and the cooler/SSD fit still require the
hardware checks in [MANUFACTURING.md](MANUFACTURING.md).

The two buck converters mount by their ears directly to the floor, with
53.9 mm hole spacing and the supplier's asymmetric 31.3/26.3 mm transverse
hole datum. The source checks the 45 mm rear connector/wiring envelope,
Pi/board overlap, headroom and ventilation area. Those modeled envelopes do
not establish real plug, lug or cable-bend clearance; dry-fit the bought parts.

**Grounding:** the folded body is one continuous metal part. Rivet the two
rear corner brackets before coating. Protect the specified earth-stud and
rear-panel bonding contacts; paint the remaining
surfaces. The rear panel's marked bonding land must contact its matching body
land. Verify the assembled electrical bond; paint is not a conductive contact.

---

## 5. Internal mounting & the bottom plate

Printed pedal collars and sleds attach to the base floor. The rear floor
carries the console board, N07/Pi stack, two converters and the floor-mounted
screen tower/stands. The console board and Pi sit side by side and connect by
the keyed ribbon. Use each assembly's distinct support height from the hardware
schedule. The EC11 ring holder attaches to the lid underside; both displays
remain supported from the floor when the lid is removed. Retired sheet-metal
`screen_bracket` parts and wall-hung pedal platforms are not part of this set.

The **bottom plate** (`board_mounts()` drives the patterns) is the CENTRE of the
folded blank — the wall bottom edges are its own fold lines, not a joint — and carries: the **Pi** (58 × 49) and
**console board v2** (89.5 × 89.5 M3 — the number comes over the
`console_board_mount.json` seam, gated by `BOARD_MOUNT`, not copied by hand)
standoff holes in the rear; an **intake-vent block** in the clear gap between the
two platform rows (air crosses the boards to the rear-wall exhaust); and 15 rubber
feet. The electronics are reached from the **open top** once the lid is lifted.

**Floor rails (issue #1019) — the supports that carry the playing.** There are no
rubber feet any more. Twenty of them sat in the gaps *between* pedals, so a stomp
reached them only by bending the 2.0 mm floor: 353 MPa and 23 mm of travel under
1 kN on one pedal, first yield at about 360 N. Even a rigidly pinned perimeter,
more than a 12 mm front wall and a screwed-down lid can deliver, tops out at
914 N, so no amount of shell stiffening fixes it. `_stomp_fea.py` and
[the rated-load analysis](../docs/research/2026-09-09-enclosure-stomp-load-analysis.md)
have the model and its validation.

Forty more feet on the pedestals' own chassis screws did fix the load path
(89 MPa, 1.4 mm) and looked like a rash — sixty parts on the underside, none of
them lining up with anything, and sixty heights to keep coplanar. Five
**continuous rails** do the same job better on every count:

| | 60 feet | 5 rails |
|---|---|---|
| peak stress at 1 kN | 89 MPa | **52 MPa** |
| deflection | 1.39 mm | **0.23 mm** |
| first yield | 1428 N | **2465 N** |
| parts on the floor | 60 | 5, in 17 printed segments |
| rubber on the ground | 15,268 mm² | 58,360 mm² |

`floor_rail_lines()` puts **three full-width rails** on the two front pedestal
screw rows and the rear anchor row. The front pair ride screws the floor already
had, so between them the rails add eight bores and no more.

Each rail is a printed PETG body, **21 mm wide** and 6 mm thick, with an
18.85 × 1.5 mm channel in its floor face holding a **19.05 × 3.2 mm self-adhesive
solid neoprene strip** (3/4" × 1/8"). Two things about that strip are not
negotiable. It is **smooth**: every adhesive tape stocked locally is mineral grit,
which grips beautifully and would score a stage floor. And it is **3.2 mm**: at
the 0.5–1 mm of a grip tape a bonded rubber layer is stiff in compression and
contributes nothing but friction. The channel is 0.2 mm under the strip and
shallower than it, so the rubber is captured between two walls and still stands
1.7 mm proud to reach the floor. Adhesive holds it during handling; it is not in
the load path. Ride height is 7.7 mm.

**Width is set by the floor, not by the strip.** `dxf_base_bores()` used to list
82 of the plate's 114 bores — it never knew about `board_mounts()` — so every
clearance figure derived from it was wrong, and a middle row was once proposed
straight over the console board's rear standoffs on the strength of it. With the
real list the rear row clears its nearest screen-stand bore by 3.5 mm at 21 mm
wide, 2.0 at 24 and 0.5 at 27. The strip drops from 1" to 3/4" to suit.

**There are three rows because there is no room for a fourth.** The middle of the
plate is occupied at v = 181.28, 205, 206.22, 229.25, 236, 246.10 and 252.75 —
pedestal screws, screen-stand anchors, the lid prop's bolts and the board's
standoffs. Two lanes survive, at v 162.3–167.9 and v 259.5–265.3, both about 5 mm
wide, and both would need new bores whose heads have to clear whatever stands on
the floor above them. A row at v 262.4 measures 91 MPa and 1.43 mm against three
rows' 96 MPa and 3.28 mm, so it is available if the deflection ever matters.

What three rows costs is worth stating plainly: CLEAR and BANK span 228 mm
between the rear front rail and the rear rail, and the plate deflects **3.28 mm**
under a 1 kN stomp there. Peak stress is 96 MPa. For scale, a Boss RC-600's top
panel measures 401 MPa and 1.77 mm in the same model, so this is half an RC-600's
stress and about twice its deflection.

**Every segment of a rail is the same printed part.** Two parts in all: the front
one ×8 and the rear ×4. That falls out of taking the rail span from the pedal
pitch rather than the plate edges — each segment is exactly two pedals wide, so
the screw pattern repeats instead of drifting 5.2 mm a segment as it did across an
830 mm span. Ends are **square** with a 1 mm corner break, and segments **butt**:
`RAIL_JOINT` is 0.5 mm of print tolerance, not a visible gap. Both reverse earlier
calls — full-round stadium ends and a 3 mm gap made each row read as sixteen
lozenges rather than three lines. Square ends also let the strip be a plain
scissors cut that fills the channel corner to corner; the stadium left a 12.6 mm
radius unfilled at every end. The set needs 2,385 mm of strip.

Sameness is measured on the **printed** part, not the span it occupies. Taking the
joint off only the ends a segment shares with a neighbour reads as the obvious way
to leave a gap, and it makes the first and last segment of each rail longer than
the middle two. Every segment loses half a joint at both ends.

The rear rail's anchors are ours to place, and there are only 53 mm of segment
where they may go. Two of the eight are the whole story: the buck converters are
22 mm bricks bolted flat to the floor across u 340–480, a segment boundary falls
at u 423, and a screw's **head** stands up inside the console. So the left brick
rules out the far end of segment 2 and the right brick rules out the near end of
segment 3 — and because all four segments are one part, an offset ruled out in one
is ruled out in all. What survives is 61.5–114.8 mm from a segment's near end; the
anchors sit at 65 and 111, 3.5 mm inside each edge of that window.

The pair is therefore not symmetric about the segment centre, and the two screws
are 46 mm apart on a 202 mm segment. Neither costs anything: a rail works in
compression between the plate and the floor, so an unscrewed tail still carries
its load, and two screws already fix a segment against turning.

**The rear rail sits at v 343.25, not where the feet were.** The buck converters
bolt through v 367.5 with a **floor-side washer and nut**, so hardware protrudes
there and the rail would perch on it. At 21 mm wide it clears the screen-stand
rows at 327 and 359.5 by 3.5 mm, where the 27 mm version cleared by 0.95.

`_check()` gates what was learned the hard way here: that every segment of a rail
is one printed shape; that **nothing but a rail's own screws sits under it**; that
no anchor's head lands inside a converter body; and that the bottom plate carries
no vents. The bore-list bug is why the second of those was not enough on its own —
a gate is only as good as the list it checks against.

**The bottom plate has no vents.** It carried 24 slots, 3,840 mm², at v 134–162,
and they are gone (owner call). That field sat 112 mm forward of the console board
and 200 mm forward of the converters, and it breathed through the 7.7 mm gap the
rails leave under the plate — a gap entered only at the two side edges, and worth
nothing on the carpet this thing spends its life on. The openings that matter are
already beside the electronics: the side-wall band at v 250–372 and the rear wall,
11,529 mm² of free area between them against a 4,000 mm² floor. Deleting it also
freed the underside, which is what it was really costing: the field dictated the
rail layout twice.

An earlier note in this file about the posts shadowing 21 of 32 intake slots is
kept for the record in git history only; the field it described no longer exists.

**Lid support (issue #1019).** Away from a support pad the 2.0 mm faceplate
dents at 7-11 kg of point load; over one it takes 170 kg. #292 sized that
correctly and then covered 100 mm of an 850 mm panel with two posts. Seven posts
covered 211 of 850 — a quarter — and the band between them still failed at 47 kg.

On 2026-09-10 the seven became **one folded steel beam that runs wall to wall**
(owner call: "a whole support beam in that line that is also supported, that also
attaches to the sides, the walls of the base"). Same C section, same 1.6 mm
cold-rolled steel, same fourteen M4 into the floor at the same stations; what
changed is that the pad is continuous, so the weakest point on the band goes from
47 kg to 475 kg.

The beam costs the **bottom plate** margin, because fourteen bolts concentrate
in-plane restraint the plate used to spread. At a 1 kN stomp the floor reads:

| | peak | deflection | vs the 95 MPa spec minimum |
|---|---|---|---|
| three rails, no beam | 96 MPa | 3.28 mm | 1.01 |
| beam on slotted holes | 135 MPa | 2.95 mm | 1.42 |
| beam on plain holes | 147 MPa | 2.83 mm | 1.54 |

Both stay inside the RC-600 calibration point (util 2.00 against yield, on a
shipping product), so the trade is roughly 0.4 units of floor margin for a
tenfold gain on the faceplate. **The fixing holes are slotted in depth** for that
reason — the slot is what buys back the 12 MPa between the last two rows.

Three things the posts never had to answer:

- **The pad cannot dodge the LED pill shoulders in u any more.** `BEAM_PAD` is
  set from that clearance instead: the shoulders end at v 148.61, the pad starts
  at 150.70. Measure it where the two actually come closest, not in plan — the
  pad bears 1.2 mm below the faceplate where the shoulder's perpendicular rear
  face has already leaned back, and the pad's square-cut end reaches `T·tan`
  further forward than its mould line. Together those eat 0.62 mm. The plan
  figure said 1.39 where the assembled model measured 0.78; `BEAM_LEAN` states
  the correction once and the gate applies it.
- **A continuous web is a wall**, and every cable in the front half used to walk
  through the 71 mm gaps between posts. It carries a 24 × 12 window on each
  front-row pedal centreline plus one per side for the LED strip feed, ten in
  all, with 15.4 mm of web left above and below.
- **Each end folds a rearward ear onto its side wall**, one M4 through the wall,
  slotted vertically. The tie braces the two walls against each other; it is not
  asked to carry the beam. The C section is stiff enough that the 109 mm of
  overhang past the outermost bolts deflects 0.06 mm at 1 kN and sees 58 MPa.

The old "post must be under the 16in aperture" assertion encoded #292's scope
rather than the requirement, and is replaced by one proving the whole pad band
bears on metal that has not been cut away.

Two ligaments deeper in the panel stay bare, and only one of them can be fixed.
`segno_lid_prop` is a **printed** PETG column — a pure compression member, so a
shop part number would be waste — in the single clear lane between BANK's
pedestal (ends u 416.8) and the 16in **module body**, which is wider than its
aperture and starts at u 448.3. That 31.5 mm lane takes a 24 mm column at
u 432.5 with 3.7 mm each side, and lifts the strip beside BANK from 8 kg to
131 kg. Two M4 into the floor; the height derives from `lid_under_z(PROP_V)`
with the same bare-gap-then-felt rule as the beam.

**The ligament left of CLEAR has no lane and remains at 11 kg.** The 7in tower's
right leg ends at u 213.6 and the CLEAR pedestal starts at 226.9; 13.3 mm is not
a column. Closing it means moving the tower or the pedestal, which reopens the
layout, so it is recorded here rather than fixed.

---

### The slope convention — `v` is along the plate, so height is `v·sin` (#742)

`v` on the faceplate is measured **along the slope**, not in plan: `FP_V == L_SLOPE`
(406.64), the plate's own length, not `FACE_RUN` (397). Moving `v` along a plane
inclined at `SLOPE_ANGLE` lifts you by **`v·sin`**.

`lid_top_z` used to interpolate over `FACE_RUN` — i.e. treat an along-slope `v` as a
horizontal run — overstating the plate by `v·(tan − sin)` = **0.00525·v**: 0.36 mm at
the front row, 1.42 mm at the mid row, **1.95 mm** at the back of the 16" aperture.

**It was masked, not missed.** `face_drift`'s own docstring named it ("*lid_top_z uses
the tan-slope shortcut, the real plate follows sin*"), and a two-point fit
`face_drift(v) = 1.96 − 0.00533·v` was calibrated in the Fusion doc to cancel it. That
slope was never the plate: **−0.00533 is the tan/sin error (0.005253) to within 1.5 %.**
The fit was measuring the bug.

Re-reduce the same three measurements against a **sin** slope and they land on
**+1.955 / +1.942 / +1.939** — a constant, to within 0.016 mm. Three independent points
agreeing that closely is the evidence. So `FACE_SEAT = 1.95` is the real, physical
seating offset, and `SKIRT_DRIFT_ROW1/ROW2` (1.6 / 0.5 — the same fit, duplicated)
collapse into it.

> **Nothing already made is invalidated.** Correcting both together moves `platform_h`
> by **−0.0003 mm** at the front row and **+0.015 mm** at the mid row, and **every DXF
> is byte-identical apart from timestamps and GUIDs**. The printed rings and sleds stay
> valid.
>
> What it *does* fix is the **uncompensated** call sites — `lid_under_z` for screen
> depth and Pi headroom never had drift added, so the interior was overstated by up to
> 1.95 mm, in the direction that makes you think there is more room than there is.

Gated at the **top** of `_check()`, before anything derived from it: `FP_V == L_SLOPE`,
`lid_top_z` is exactly `H_FRONT + v·sin`, the top of the slope is `H_REAR`, and
`face_drift` is **constant** — the moment it grows a `v` term again it is almost
certainly re-absorbing a unit error, which is exactly how this hid. All four
negative-controlled.

## 6. Sheet-metal notes

- Aluminium folds use R2 andK0.33; the steel support beam uses 1.6 mm stock andR1.6.
  Confirm actual temper/gauge, tools and trial-bend development before the set.
- Use only the two handed rear brackets, five Ø3.2 rivets each, with Ø3.3 holes.
  Qualify the actual 4 mm grip and setting-tool access. The rivets sit 7.0 mm
  from the bracket leg's free edge and 8.0 mm from its bend, both over 2x the
  rivet diameter; the leg went 12 -> 15 mm on 2026-09-10 to get there, and no
  hole in the base moved.
- The eighteen M3 lid joints use Ø2.5 body pilots, precoat Ø4.5 lid clearance
  bores and OD 7 head washers; no clinch nuts. The owner cleans and taps the
  18 lid pilots and 14 screen-support pilots after coating. All other drilling
  and deburring are completed before coating. Plain-text stations/datums are
  in `MANUFACTURING.md`.
- `CUT` and `VENT` both cut through. `DRILL` is deferred drilling before paint.
  `BEND` is a fold reference only: **never score, cut or engrave it**. `MASK`
  marks identified electrical-bond contacts; M3 pilots remain untapped during coating.
  Individual pedal tiles use `ENGRAVE` for their filled lettering/glyphs.
- Paint all other faces, seats, edges and clearance bores smooth matte black
  RAL 9005, without texture,60–100 µm locally. Fit purchased shim packs, felt and
  seals after cure. Qualify the painted assembly after the owner cleans and taps
  the specified pilots; no other post-paint machining is planned.

---

## 7. Material & weight

Current materials are 2.0 mm aluminium **1100-H14** for the base, lid, two rear
brackets and encoder disc; 1.2 mm aluminium of unconfirmed alloy for the I/O
panel; and 1.6 mm cold-rolled steel for the **one** full-width support beam.

The 2.0 mm stock was ordered as 1050 and is not. Alcast's certificate for lot
26E0269 (2026-04-01) reports 1100-H14 at Rp0.2 127 MPa, Rm 145 MPa and 10%
elongation, all inside the ABNT NBR 7823 limits, whose **minimum proof stress is
95 MPa**. Design to the 95: 127 belongs to that coil, and a later coil will not
be it unless each delivery carries its own certificate. Stiffness is unaffected
either way -- E is about 69 GPa for 1050, 1100 and 5052 alike, so no alloy call
moves a deflection. The powder cure is a separate unknown: 1100 draws its
strength from cold work, and a 180-200 degC bake can recover some of it. No
validated residual-strength curve was found for this cycle, so do not assume a
deduction and do not assume there is none. The former all-5052 /all-steel mass estimates
are historical and are not the current order. Use current solid volumes and
actual stock densities for a mass estimate, then weigh the assembled prototype.

---

## 8. Generating the package & the assertion gate

```bash
cd hardware/enclosure
.venv/bin/python segno_enclosure.py            # check + STEP + DXF + PDF -> out/
.venv/bin/python segno_enclosure.py --report   # report + assertions only
.venv/bin/python segno_enclosure.py --no-step   # intermediate flats/handoff; no metal/paint release
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

The configured CAD Python environment supplies the generator dependencies.
`_check()` is the source-geometry gate, followed by native-flat, drawing and
package gates; physical supplier acceptance remains separate. Source assertions
cover the following rules:

| assertion | guards |
|-----------|--------|
| `WIDTH_BUDGET` | the 10-pedal row + gaps fit across the faceplate |
| `NO_OVERLAP` / `BOUNDS` | no two cutouts intersect; all inside the usable area |
| `PLATFORM_HEADROOM` | foot-plate flush+proud, body fits under the sloped lid |
| `SCREEN_DEPTH` | each module + cable clears the interior; pedal row clears the 16" |
| `VENT_FREE_AREA` | open vent area ≥ target; standoff gap adequate |
| `SCREEN_RETENTION` | aperture < bezel (mount from behind) |
| `PEM` | bottom-flange edge distance ≥ `PEM_EDGE`+2 — a frozen guard named for the **retired** clinch scheme; there are no clinch nuts now, but the land width stays pinned |

Outputs in `enclosure/out/` (mm): **STEP** (`segno_assembly` + per-part incl.
`segno_platform_*_ring`, `segno_platform_sled` and `segno_platform_mid_sled`),
**DXF** flat patterns, **PDF** drawing sheets
(the platform parts are print-only). Verification renders
(`out/_hero.png`, `out/_fp_top.png`) confirm 7" left / 16" right.

After changing geometry, synchronize both Fusion documents and export fresh
verified formed caches before the full generator can publish metal packages.
The reference assembly contains eight made pieces, nine purchased shim packs
and eighteen purchased head washers: 35 solids. Only seven unique fabricated
part stems belong in the per-part metal package. See the native workflow in
`enclosure/FUSION_MODELS.md`; no parameter edit alone authorizes cutting.

---

## 9. Bill of materials and physical release checks

Use the current [manufacturing part table and hardware schedule](MANUFACTURING.md)
for quantities, materials and qualified screw lengths. It lists the seven
fabricated stems/eight made pieces, 18 lid screws and OD7 washers, nine fitted
shim packs, printed parts, ten rear-bracket rivets, feet and the actual electronics
support stacks. The old approximate BOM, all-5052 stock, generic standoff counts,
self-tapping foot screws and 12-THT-LED ring are superseded.

Use the separate mini-console order for its tray/lid/two sleds and hardware.
The console first-print pack `segno_first_prints_STL.zip` contains one STL for
each of the front collar, mid collar, front sled and mid sled. Print one of
each for fitting before making the full eight-front/two-mid set. The PETG
starting profile is 0.20 mm layers, six perimeters with a 0.4 mm nozzle, 40%
gyroid and six top/bottom layers. Print collars base-down and sleds flat-bottom
down, supporting the tall collar's hollow underside deck. Keep blind insert
pockets clear of unnecessary supports and verify the actual inserts, cable,
screws and assembly before batching; no physical strength qualification is
implied by this profile.

The console's Ring24 procurement must match the selected Ø80 PCB/header assembly;
its older Ø68 Gerber package is not released by this sheet-metal work.

Before cutting the full set, close the [release review](enclosure/RELEASE_REVIEW.md):
trial forming and tool access, the selected rivet, actual purchased connector
and fastener stacks, PD local web, complete mating patterns, the coating coupon
and finished assembled fit. Screen body and pedal dimensions are measured
references; caps, adapters, thread depths, print tolerance, torque, coating and
structural behavior still need the stated physical checks. The user receives
short plain-text handoffs for the metal shop and separate painter, with no
large review PDF or additional machining drawing page.

## Console rear cable opening — September 9

Console cable-slot update, September 9: the measured cable feature is
7.6 mm wide ×11.45 mm high. The rear opening is centred and 8.6 mm wide,
with 0.5 mm clearance on each side. Its lower edge sits 6.95 mm above the
bare pedal underside (the sled top). The approximate 6 mm top and 8.5 mm
bottom measurements imply positions 1.05 mm apart on the 24.9 mm case;
the hole clears both with at least 0.5 mm around an assumed stadium-shaped
fitting. The opening is a closed vertical stadium, 8.6 ×13.5 mm overall,
with R4.3 mm ends and 4.9 mm straight sides. Thread the cable end through
before lowering the pedal/sled. Square fitting corners are not qualified by
this profile; check the actual cable/strain relief in the first print before
batching. The mini retains its existing cable notch.
