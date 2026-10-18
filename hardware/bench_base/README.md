# Bench base for the console v3 electronics

A printed base that holds the console v3 electronics on the bench, off the
table, with the leads between them short (#1358). It is a bench part, not an
enclosure part.

![top view](out/segno_bench_base_top.svg)

Three tiles that join with dovetails. Assembled, they cover 198 x 272 mm; each
tile fits an Ender 3 V3 bed (220 x 220) with room to spare.

| tile | holds | size (mm) | PLA, 15 % infill |
|---|---|---|---|
| `console` | console board v3 (Pico 2) on four M3 standoffs, 10 mm up | 118 x 118 x 14 | ~18 g |
| `pi` | Raspberry Pi 5 on its GeeekPi N07 NVMe board, on four M2.5 risers 10 mm up; the screen power board on four M3 standoffs, 12 mm up | 118 x 161 x 16 | ~23 g |
| `power` | SparkFun STUSB4500 on four M3 standoffs, 8 mm up; both 20 V to 5 V bucks in corrals | 87 x 192 x 12 | ~21 g |

```
 back
 +-----------+
 | Pi 5      |------+    Plugs go in from the free edges:
 | screen    |      |    the Pi's HDMI and USB-C from the back,
 | power     |power |    its USB and Ethernet from the left,
 +-----------+      |    the Pico's USB from the left,
 |  console  |      |    the PD board's USB-C from the right.
 +-----------+------+
 front (you)
```

Files in `out/`: one `.stl` (print) and `.step` (CAD) per tile, already in print
pose, `segno_bench_base_assembly.step` with the boards as reference slabs, and the
top view above.

## Which boards it fits

The V3 boards as soldered: the layouts on `codex/screen-power-board-1072`
(PR #1080) at `c88389bf2`, the revision recorded in `board_geometry.json`. The
console board's outline and mounting holes are the same as on master; its
deepest lead is now a JST-VH power header. The screen power board is only on
that branch (#1072, revision P).

## Where the numbers come from

- **Console board and screen power board** (outlines, mounting holes, pads):
  `board_geometry.json`, written by `extract_boards.py` from
  `hardware/kicad/out_console/segno_console_board.kicad_pcb` and
  `hardware/kicad/screen_power/hand/screen_power_hand.kicad_pcb` of that
  revision. Re-run it after either layout changes. It reads the layouts out of
  git, at the revision the JSON already records unless `--rev` names another, so
  a plain re-run cannot quietly switch the base to whichever boards this branch
  happens to carry.
- **What hangs under them**: `kicad-cli pcb export step` of the same layouts.
  Neither board has a part on its back, only leads. On the console board the
  deepest is a JST-VH header at 2.11 mm (about 4 untrimmed). On the screen power
  board it is Q5's TO-220 leads, modelled untrimmed at 8.14 mm; the next is F1's
  holder at 2.38.
- **Raspberry Pi 5**: the official mechanical drawing, 85 x 56 with M2.5 holes
  on a 58 x 49 rectangle (`PI_HOLES` in `../enclosure/segno_enclosure.py`).
- **NVMe board**: the GeeekPi N07 (B0CWD266XR, 52Pi EP-0211) that the enclosure
  stacks under the Pi. It is a bottom board on the Pi's own four holes,
  HAT-sized. The enclosure's stack is riser, N07, 6 mm M2.5 male/female
  extender, Pi (`PI_N07_H` and the stack notes in `segno_enclosure.py`), with each
  extender's male end threading down through the N07 into the riser.
- **STUSB4500 board**: SparkFun's Eagle file
  (`sparkfun/Power_Delivery_Board-USB-C`, `Hardware/SparkFun_STUSB4500_USB-PD.brd`):
  35.56 x 33.02, four #4 holes (3.3 mm, take M3) 3.175 in from each corner.
- **Bucks**: `BUCK_BODY` in `../enclosure/segno_enclosure.py`, 63.8 x 57.7 x 22.1
  including the ears.

## How each board is held

- **Console board**: four M3 standoffs, 10 mm. Rear-panel loom (POWER, MIDI,
  CTRL) to the back, footswitch row to the front, Pico USB to the left; J2, the
  Pi ribbon, faces the Pi.
- **Screen power board**: four M3 standoffs, 12 mm, enough for Q5's leads even
  untrimmed. The bosses are 8 mm across, inside the board's 4.25 mm copper
  keepout round each hole. Its holes are symmetric, so it goes on either way
  round; all its cables leave upward.
- **Raspberry Pi 5 + N07**: the four bosses are the enclosure's risers, 10 mm
  tall, each with an M2.5 heat-set insert. The male ends of the pillars that
  join the N07 to the Pi go down through the N07 into them, as in the
  enclosure. The pilot runs on 4 mm below the insert, so a 6 mm male end (a 6+6
  extender) goes home as well as the N07 kit's 12+4 pillars. The Pi sits in the
  back-left corner, turned so the USB-C and both micro-HDMI ports face the back edge and
  the USB and Ethernet jacks face the left edge, each 3 mm in from it.
  `PI 5: HDMI TO THE BACK` is engraved under it.
- **STUSB4500**: four M3 standoffs, 8 mm, USB-C facing the right edge.
- **Bucks**: corrals open in the middle of every side for the leads and the ears.
  The ear spacing in the enclosure model is still provisional, so the base does
  not drill for them.

`bench_base.py` refuses to export a base where a standoff lands on a pad, a
board hangs off its tile or crowds another, the leads reach the floor, a Pi
port edge faces a seam, or a tile does not fit the bed.

## Print

- **PLA**, 0.2 mm layers, 3 walls, 15 % infill. **No supports**: every tile prints
  floor-down as exported.
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
| M3 heat-set insert, 5 long x 5 OD (the repo's standard, pilot 4.5) | 12 | console board, screen power board and PD board standoffs, 4 each |
| M3 x 6 screw (pan or button head) | 12 | down through each of those boards into its insert |
| M2.5 heat-set insert, 4 long x 3.5 OD (pilot 3.2) | 4 | the Pi risers |

The pillars between the N07 and the Pi are the ones already in your Pi stack
(6 mm M/F extenders, or the N07 kit's 12+4 pillars). Press the inserts in with
the iron before joining the tiles, while each tile still lies flat.

## Putting it together

1. Press the sixteen inserts. Join the tiles: lower `pi` and `power` onto
   `console` so the tabs drop into the sockets.
2. Screw the console board, the screen power board and the PD board to their
   standoffs.
3. Thread the N07-to-Pi pillars' male ends down through the N07 into the four
   Pi risers (USB-C and HDMI to the back), then put the Pi on top as usual.
4. Drop the bucks into their corrals (`BUCK PI` at the front, `BUCK AUX`
   behind).

## Regenerate

```bash
/Applications/KiCad/KiCad.app/Contents/Frameworks/Python.framework/Versions/Current/bin/python3 extract_boards.py --rev <commit>   # only for another board revision
../enclosure/.venv/bin/python bench_base.py
```

The CAD venv is not in git; build it with Python 3.12 as in `../enclosure`.
Every constant worth changing is at the top of `bench_base.py`. A rerun on
unchanged geometry leaves the STLs and the SVG byte-identical; the STEPs change
in their header timestamp, and the assembly also in the order of its colour
records.
