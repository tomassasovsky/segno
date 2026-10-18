# Bench base for the console v3 electronics

A printed base that holds the console v3 boards on the bench, off the table, with
the leads between them short (#1358). It is a bench part, not an enclosure part.

![top view](out/segno_bench_base_top.svg)

Three tiles that join with dovetails. Assembled, they cover 198 x 218 mm; each
tile fits an Ender 3 V3 bed (220 x 220) with room to spare.

| tile | holds | size (mm) | PLA, 15 % infill |
|---|---|---|---|
| `console` | console board v3 (Pico 2) on four M3 standoffs, 10 mm up | 118 x 118 x 14 | ~18 g |
| `ring` | ring carrier (XIAO RP2350) with the 34-LED cup, 22 mm up | 118 x 107 x 29 | ~18 g |
| `power` | SparkFun STUSB4500 on four M3 standoffs, 8 mm up; both 20 V to 5 V bucks in corrals | 87 x 192 x 12 | ~21 g |

```
 back
 +-----------+------+
 |   ring    |      |   USB access is on the free edges:
 +-----------+ power|   the Pico's and the XIAO's on the left,
 |  console  |      |   the PD board's USB-C on the right.
 |           |      |
 +-----------+------+
 front (you)
```

Files in `out/`: one `.stl` (print) and `.step` (CAD) per tile, already in print
pose, `segno_bench_base_assembly.step` with the boards as reference slabs, and the
top view above.

## Which boards it fits

The V3 boards as soldered: the layouts on `codex/screen-power-board-1072`
(PR #1080) at `c88389bf2`, the revision recorded in `board_geometry.json`. Against
the layouts on master, the outlines and mounting holes of both boards are the
same. Underneath, the ring carrier gains R5 (100k, r 15 to 26.5) and the ACZ11
encoder's pads reach r 8.92 instead of the EC11's 8.87; the console board's
deepest lead is now a JST-VH power header. The base clears both revisions.

## Where the numbers come from

- **Board outlines, mounting holes, back-side parts and pads**:
  `board_geometry.json`, written by `extract_boards.py` from
  `hardware/kicad/out_console/segno_console_board.kicad_pcb` and
  `hardware/kicad/segno_pedal_ring.kicad_pcb` of that revision. Re-run it after
  either layout changes; `--kicad` points it at another checkout's
  `hardware/kicad`.
- **Heights under the boards**: a `kicad-cli pcb export step` of the same two
  layouts (ring carrier: C1 8.09, J1 7.09, C2-C5 5.19, XIAO 4.36, U2 3.77, D1 3.29,
  R1-R5 2.59; console board: leads only, the JST-VH headers' 2.11 deepest, about 4
  for an untrimmed pin), plus the owner's calipers: 8.5 under the ring carrier with
  C1 bent over and lying down.
- **STUSB4500 board**: SparkFun's Eagle file
  (`sparkfun/Power_Delivery_Board-USB-C`, `Hardware/SparkFun_STUSB4500_USB-PD.brd`):
  35.56 x 33.02, four #4 holes (3.3 mm, take M3) 3.175 in from each corner.
- **Bucks**: `BUCK_BODY` in `../enclosure/segno_enclosure.py`, 63.8 x 57.7 x 22.1
  including the ears.
- **The cup's snap arms**: `strip_ring/console_ring.py` on the enclosure branches
  (#1090): three arms 120 degrees apart. Two versions exist, 6 mm wide and 8 mm
  wide (the snap-relief rework on `claude/console-ring-snap-reliefs-1075`); the
  crown takes either.

## How the ring carrier is held

The ring carrier has no mounting holes, and the cup's three snap arms wrap its
edge at whatever angle the cup was turned to. So the cradle supports the board in
two places that are clear at every angle:

- **A tube under the encoder**, r 9.32 to 10.85: the ring of free board between
  the encoder's pads (out to r 8.92) and the nearest other part (R2's courtyard at
  r 10.85). It takes the push when the encoder switch is pressed.
- **A crown of teeth round the rim.** Each tooth is a ledge under the board's edge
  (r 39.3 to 40) and a post beside it (from r 40.6, so 0.6 mm of play round the
  board). The deepest part near the rim is D1, out to r 38.3, so no part reaches a
  ledge at any angle. The cup's arms drop into the 11.3 mm gaps between the teeth,
  which stops the board turning when the knob is twisted (about 1.6 mm of play
  each way with the 8 mm arms). The teeth are on a 20-degree pitch and the arms are
  120 degrees apart, so when one arm finds a gap all three do.

Two teeth are left out on the left for the XIAO's USB-C. The opening is 56
degrees wide against a 20-degree plug, so the plug fits at every position where
the arms can seat. J1's lead goes out through any gap; there is 22 mm under the
board for the plugged housing (about 11 mm) and the bend.

`bench_base.py` refuses to export if any of this stops holding. It sweeps every
part under the ring carrier round the centre and checks that the tile does not
touch any of them.

## Print

- **PLA**, 0.2 mm layers, 3 walls, 15 % infill. **No supports**: every tile prints
  floor-down as exported, and the ledge undersides are 45 degrees.
- No brim needed; each tile sits flat on the bed (the repo's
  `../enclosure/_print_check.py` passes all three with nothing flagged).
- The dovetails have 0.15 mm of clearance per side and a 0.3 mm relief at the
  bottom of each socket for the first-layer squash. If they are still tight, take
  the tab's bottom edge off with a knife rather than forcing it.
- The bucks are potted bricks that run warm under load. PLA softens around
  55 to 60 C. Bench loads are light, but if you run the LEDs bright for a long
  time, print the `power` tile in PETG.

## Hardware

| what | qty | where |
|---|---|---|
| M3 heat-set insert, 5 long x 5 OD (the repo's standard, pilot 4.5) | 8 | the console board's 4 standoffs and the PD board's 4 |
| M3 x 6 screw (pan or button head) | 8 | down through each board into its insert |

Nothing else. The ring carrier and the bucks are not screwed down: the ring sits
in its crown, and each buck sits in a corral open in the middle of every side for
its leads and ears. The bucks' ear spacing in the enclosure model is still
provisional, so the base does not drill for them.

Press the inserts in with the iron before joining the tiles, while each tile
still lies flat.

## Putting it together

1. Press the eight inserts. Join the tiles: lower `ring` and `power` onto
   `console` so the tabs drop into the sockets.
2. Screw the console board to its standoffs: rear-panel loom (POWER, MIDI, CTRL)
   to the back, the footswitch row to the front, the Pico's USB to the left.
3. Screw the PD board to its standoffs with its USB-C facing the right edge.
4. Drop the bucks into their corrals (`BUCK PI` at the front, `BUCK AUX` behind).
5. Plug J1 into the ring carrier, then lower the carrier, cup up, into the crown
   with the XIAO's USB-C pointing at the left opening (`XIAO USB` is engraved
   there). Turn it a few degrees either way until the cup's arms drop between the
   teeth and the board sits flat on the ledges. Route J1's lead out through the
   nearest gap toward the console board's J6.

## Things to check on the real parts

- **C1's direction.** The check allows for C1 lying straight outward, reaching
  r 39.0. If yours sticks out past the board's edge, it will meet a tooth: turn
  the carrier by one tooth so C1 sits in a gap.
- **Without the cup**, nothing stops the ring carrier turning. It still sits on
  the tube and the ledges and the posts keep it from sliding off.
- **The console board's leads.** 10 mm of air is plenty for untrimmed leads. If
  you want to probe the back, the board comes off with four screws.

## Regenerate

```bash
/Applications/KiCad/KiCad.app/Contents/Frameworks/Python.framework/Versions/Current/bin/python3 extract_boards.py   # only after a layout change
../enclosure/.venv/bin/python bench_base.py
```

The CAD venv is not in git; build it with Python 3.12 as in `../enclosure`.
Every constant worth changing is at the top of `bench_base.py`. A rerun on
unchanged geometry leaves the STLs and the SVG byte-identical; the STEPs change
in their header timestamp, and the assembly also in the order of its colour
records.
