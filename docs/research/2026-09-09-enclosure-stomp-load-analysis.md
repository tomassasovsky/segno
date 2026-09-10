# Can the folded shell take a stomp? — rated-load analysis (issue #1019)

**Date:** 2026-09-09 · **Scope:** `hardware/enclosure`, base plate + faceplate ·
**Model:** [`hardware/enclosure/_stomp_fea.py`](../../hardware/enclosure/_stomp_fea.py)

## Answer

No, not as drawn. The base plate takes a permanent set at roughly **360 N — 37 kg
— applied to one pedal**, which is about half an adult's body weight. It reaches
the floor 5 mm below at about 220 N. The faceplate dents at 7–11 kg of point load
anywhere the two steel posts do not reach.

One change fixes the base plate and it costs no new holes: put a rubber foot on
each of the four chassis screws that already come up through the plate under
every pedestal.

## What the certificate settled, and what it did not

Alcast lot 26E0269, 2.00 mm, **1100-H14** (the drawings all still say 1050):

| property | lot | ABNT NBR 7823 limit |
|---|---|---|
| Rp0.2 | 127 MPa | ≥ 95 |
| Rm | 145 MPa | 110–145 |
| A | 10 % | ≥ 4 |

Chemistry is inside ISO 209 for 1100. This is a real structural material and a
better one than the assumed 1050, whose yield sits near 95 MPa.

It changes nothing about stiffness. Young's modulus is ~69 GPa for 1050, 1100 and
5052 alike, so **every deflection below is alloy-independent**; only the load at
which the metal stops springing back moves. Design numbers here are quoted
against both the lot's 127 MPa and the alloy's 95 MPa spec minimum, because a
future coil will not be this coil unless each delivery carries a certificate.

## Load path

    stomp → pedal → sled → printed collar → 4× M3 → 2.0 mm BASE PLATE → rubber foot → floor

The 15 feet sit in the *gaps between* pedals (`base_foot_xy()`), never under one,
because the M4 foot screw head lands on the plate's top face and the pedestal has
to seat flat there. So the plate spans out to them. There is no rib, swage or
stiffener anywhere in the floor, and `segno_enclosure_design.md` §5 says as much:

> fifteen supports do not establish equal load sharing or a rated force

## Method

Kirchhoff plate-bending FE, 12-DOF ACM rectangle, shape functions derived from
the polynomial basis rather than transcribed. Feet are distributed elastic pads
over their Ø18 chassis contact (400 N/mm nominal), not point supports, so the
peak is a real bending stress and not a singularity. Mesh is feature-aligned and
converged: 8 mm vs 5 mm elements move the peak by 3 %.

Validation, run by `--selftest` and by an independent closed-form check:

| check | model | reference |
|---|---|---|
| simply supported square, w | 20.300 mm | 20.268 (Timoshenko 0.00406) |
| simply supported square, M | 0.0480 qL² | 0.0479 |
| clamped square, w | 6.329 mm | 6.290 (0.00126) |
| clamped square, M | 0.0230 qL² | 0.0231 |
| uncut 2 mm lid, 500 N over 50×50 | 24.9 mm | 25.2 mm thin-plate estimate |

## Base plate — results at a 1000 N reference stomp

Everything scales linearly with force.

| case | von Mises | deflection | first yield (127 / 95 MPa) |
|---|---|---|---|
| as designed, collar rim bearing | 283 MPa | 13.6 mm | 449 N / 336 N |
| as designed, uniform bearing | 287 MPa | 12.8 mm | 443 N / 331 N |
| **as designed, toe-loaded** | **353 MPa** | **23.0 mm** | **360 N / 269 N** |
| whole perimeter rigidly pinned | 139 MPa | 5.0 mm | 914 N / 683 N |
| foot on each chassis screw, rim | 40 MPa | 0.7 mm | 3203 N / 2396 N |
| foot on each chassis screw, toe | 89 MPa | 1.4 mm | 1425 N / 1066 N |

Read the toe-loaded row as the design case: a player's weight lands on the front
of the treadle, not on the middle of the pedestal.

Three things follow.

**Stiffening the shell cannot save it.** The perimeter-pinned row is an upper
bound on everything the walls and the screwed-down lid could ever contribute —
more than a 12 mm front wall can deliver — and it still only reaches 914 N.

**The plate hits the floor before it yields.** Feet are 5 mm tall; the toe-loaded
case passes 5 mm at about 220 N (22 kg). On a hard floor that caps the damage:
the plate dishes a few millimetres, finds the floor and stops, which is a feel
and vent-blocking problem rather than a collapse. On carpet, a riser or an uneven
stage there is no backstop.

**It is a fatigue joint as well as an overload one.** 1100-H14 has no endurance
limit worth counting on above ~41 MPa. Routine play at 300 N puts the plate at
~106 MPa, so the foot pads are being worked well into finite life; a gigging unit
would accumulate cracking rather than one dramatic failure.

## The fix, and the alternatives that are worse

The pedestal's four chassis screws (`platform_foot_xy()`, ±22.188 u / ±48.685 v)
already pass **up from below** through the base plate and thread into the sled, so
their heads are already on the underside. Putting a rubber foot on each one turns
the plate into a washer: the stomp goes straight to the floor.

| option | vM at 1000 N (toe) | deflection | cost |
|---|---|---|---|
| foot on each of the 4 chassis screws | 89 MPa | 1.4 mm | 40 feet, **no new holes**, no DXF change |
| 2 feet, diagonal pair | ~130 MPa | 3.6 mm | 20 feet |
| 25×25×2 Al angle riveted under the pedal row | ~140 MPa | 3.6 mm | new part, rivets, assembly |
| 40×40×2 angle | ~118 MPa | 2.6 mm | ditto, plus headroom |
| 3.0 mm sheet, feet unchanged | ~157 MPa | 4.0 mm | +50 % shell mass, non-stock |
| 5052-H32 instead of 1100-H14 | unchanged | unchanged | only moves yield to 193 MPa |

Robustness of the recommended option: with any one of a pedal's four feet not
touching, the worst case is 86 MPa — still 1.5× under the lot yield. That matters,
because 55 feet on a 2 mm plate will not be coplanar. Choose feet soft or tall
enough that a 0.5 mm height error does not unload one; at 400 N/mm that error is
worth 200 N.

Two open practicalities for the owner: the chassis screws get longer by the foot's
height, and every foot must end up in the same plane as the 15 existing ones.

## Faceplate — 300 N point load

| spot | von Mises | dents at |
|---|---|---|
| band before the screens, over a post | 23 MPa | 1666 N (170 kg) |
| field left of the 7 in | 161 MPa | 236 N (24 kg) |
| band before the screens, away from a post | 351 MPa | 109 N (11 kg) |
| rib between two pedal slots | 388 MPa | 98 N (10 kg) |
| ligament left of CLEAR | 568 MPa | 67 N (7 kg) |

The posts do their job — 170 kg over one, 7–11 kg beside one. Issue #292 sized
the problem correctly and then covered only 100 mm of an 850 mm panel.

The narrow ribs between adjacent pedal slots are the exception: the printed collar
rims stand 0.18–0.3 mm under them, so they bottom out onto PETG almost at once and
are backed in practice. The exposure is the open bands and ligaments.

A post per pedal gap on the v ≈ 165 band, plus two in the mid field, moves the
unbacked spots from 7 kg to 24–400 kg. The pad width is already derived
(`POST_PW` = 30.14) to sit between two LED pill shoulders, so the pattern repeats
at every `FRONT_SCREW_U` station without touching the pill geometry.

## What was checked and found adequate

- **Static and transport.** 15 kg of shell and contents: 8.9 MPa, 0.7 mm. A 3 g
  set-down: 26.6 MPa. Fine either way.
- **Foot bearing.** Worst single foot carries 827 N as designed → 4.7 MPa on the
  Ø15 floor contact. High for rubber but not a metal problem; with the fix the
  busiest foot drops to a few hundred newtons.
- **M3 bearing in the plate.** 250 N per screw over 3 × 2 mm = 42 MPa. Fine.

## What landed

All three recommendations are in the package as of this branch.

| change | where | effect |
|---|---|---|
| Five printed floor rails on a neoprene strip | `floor_rail_lines()`, 14 segments in 3 parts | 353 → 49 MPa, 23.0 → 0.22 mm |
| `POST_U` spread to the seven interior pedal gaps | 5 more steel posts, +10 M4 floor bores | band before the screens 7-11 kg → 49-398 kg |
| `segno_lid_prop`, printed | the one clear lane beside BANK, +2 M4 bores | strip beside BANK 8 kg → 131 kg |
| 1050 → 1100-H14 on every callout | generator, drawings, shop message | design value 95 MPa, not the lot's 127 |

The 60 feet were an intermediate answer: they carried the load (89 MPa) and
looked like a rash. Five continuous rails do it better on every count and the
support is a 25.4 × 3.2 mm self-adhesive **solid neoprene** strip in a printed
PETG channel — smooth, because every adhesive tape stocked locally is mineral
grit that would score a floor, and 3.2 mm, because at the 0.5–1 mm of a grip tape
a bonded rubber layer is stiff in compression and buys friction but no compliance.

Both Fusion documents were synced to match, and the native formed export
re-verified all four sheet-metal parts against the current cut files.

**Where the rear rail's screws can go, and why it is not obvious.** The rear rail
is the only one that adds bores, and a bore is cheap under the floor and
expensive above it: the head stands up inside the console. The two buck
converters are 22 mm bricks bolted flat to the floor across u 340–480, a segment
boundary falls at u 423, and every segment of a rail is the same printed part —
so an offset ruled out in one segment is ruled out in all four. That leaves
61.5–114.8 mm from a segment's near end. The anchors sit at 65 and 111: not a
symmetric pair, and only 46 mm apart on a 202 mm segment. Neither matters, since
a rail works in compression between the plate and the floor and two screws
already fix a segment against turning. An even 45 mm inset — the placement that
looked right in plan and passed every gate then written — put four of the eight
heads inside a converter body. `_check()` now gates it.

**One residual, recorded rather than fixed.** The ligament left of CLEAR still
dents at 11 kg. The 7 in tower's right leg ends at u 213.6 and the CLEAR
pedestal starts at 226.9; 13.3 mm is not a column, and closing it means moving
the tower or the pedestal.

## Limits of this model

- Plate bending only. Membrane stiffening at large deflection is ignored, which
  makes the 13–23 mm as-designed deflections pessimistic; it does not rescue
  them, and stresses near the feet are bending-dominated either way.
- The intake vent field sits in the band the plate would have to carry a stomp
  through, and is not modelled, so the as-designed numbers are if anything
  optimistic.
- The faceplate is modelled simply supported on its skirt ledge with the two
  posts as props; collar and LED-insert backing are ignored except where noted.
- Foot stiffness is nominal. Sweeping 150–1200 N/mm moves the peak by ±5 %.
