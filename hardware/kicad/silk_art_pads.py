"""Rewrite silk_art_pads.json: every pad that opens the BACK solder mask.

silk_art_compose.py composes the back art around these boxes, and its docstring
says to regenerate them "whenever a through-hole part moves" -- which had no
script until the Pico was socketed (#1062) and put 43 new through-holes in the
middle of the board, straight through the artwork.

Plated pads AND non-plated holes count: an NPTH with a mask ring opens the mask
just as well, and missing those once put the big segno on the module's anchors.

    <kicad python> silk_art_pads.py     # reads out_console/console.placed.kicad_pcb
"""
import json
import os
import sys

import pcbnew

HERE = os.path.dirname(os.path.abspath(__file__))
BOARD = os.path.join(HERE, "out_console", "console.placed.kicad_pcb")
OUT = os.path.join(HERE, "silk_art_pads.json")
ORIGIN = (100.0, 60.0)          # console_board_pcb.ORIGIN


def main():
    board = pcbnew.LoadBoard(BOARD)
    mm = pcbnew.ToMM
    boxes = []
    for fp in board.GetFootprints():
        for pad in fp.Pads():
            if not pad.IsOnLayer(pcbnew.B_Mask):
                continue
            b = pad.GetBoundingBox()
            boxes.append([round(mm(b.GetLeft()) - ORIGIN[0], 3),
                          round(mm(b.GetTop()) - ORIGIN[1], 3),
                          round(mm(b.GetRight()) - ORIGIN[0], 3),
                          round(mm(b.GetBottom()) - ORIGIN[1], 3)])
    boxes.sort()
    with open(OUT, "w") as fh:
        json.dump(boxes, fh)
        fh.write("\n")
    print("wrote %d pad boxes to %s" % (len(boxes), os.path.basename(OUT)))


if __name__ == "__main__":
    sys.exit(main())
