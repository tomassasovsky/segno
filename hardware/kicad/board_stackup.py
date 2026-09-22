"""Give a 2-layer board an explicit stackup: the solder mask and silk colours.

The boards are ordered PURPLE with white silk (owner call, #1062). KiCad keeps the
colour in the board's stackup, and a board with no stackup renders green -- in
the 3D viewer, in `kicad-cli pcb render`, and in the STEP that goes to Fusion.

KiCad's Python bindings do not expose BOARD_STACKUP (GetStackupDescriptor comes
back as an unwrapped SWIG pointer), so the block is written into the file
instead. KiCad reads it back into the design settings, so every later pcbnew
load/save -- route_console_board.sh, route_ring_board.sh -- carries it along.

The colour is for the model and the renders. The fab takes its colour from the
order form, not from these files; the gerber job file does record it.

    python3 board_stackup.py <board.kicad_pcb> [...]
"""
import re
import sys

MASK, SILK = "Purple", "White"
BLOCK = """\t\t(stackup
\t\t\t(layer "F.SilkS"
\t\t\t\t(type "Top Silk Screen")
\t\t\t\t(color "{silk}")
\t\t\t)
\t\t\t(layer "F.Paste"
\t\t\t\t(type "Top Solder Paste")
\t\t\t)
\t\t\t(layer "F.Mask"
\t\t\t\t(type "Top Solder Mask")
\t\t\t\t(color "{mask}")
\t\t\t\t(thickness 0.01)
\t\t\t)
\t\t\t(layer "F.Cu"
\t\t\t\t(type "copper")
\t\t\t\t(thickness 0.035)
\t\t\t)
\t\t\t(layer "dielectric 1"
\t\t\t\t(type "core")
\t\t\t\t(thickness 1.51)
\t\t\t\t(material "FR4")
\t\t\t\t(epsilon_r 4.5)
\t\t\t\t(loss_tangent 0.02)
\t\t\t)
\t\t\t(layer "B.Cu"
\t\t\t\t(type "copper")
\t\t\t\t(thickness 0.035)
\t\t\t)
\t\t\t(layer "B.Mask"
\t\t\t\t(type "Bottom Solder Mask")
\t\t\t\t(color "{mask}")
\t\t\t\t(thickness 0.01)
\t\t\t)
\t\t\t(layer "B.Paste"
\t\t\t\t(type "Bottom Solder Paste")
\t\t\t)
\t\t\t(layer "B.SilkS"
\t\t\t\t(type "Bottom Silk Screen")
\t\t\t\t(color "{silk}")
\t\t\t)
\t\t\t(copper_finish "None")
\t\t\t(dielectric_constraints no)
\t\t)
""".format(mask=MASK, silk=SILK)


def apply(path):
    s = open(path).read()
    if "(stackup" in s:
        s = re.sub(r'\t\t\(stackup\n.*?\n\t\t\)\n', lambda m: BLOCK, s, count=1, flags=re.S)
    else:
        i = s.index("\t(setup\n") + len("\t(setup\n")
        s = s[:i] + BLOCK + s[i:]
    open(path, "w").write(s)


if __name__ == "__main__":
    for p in sys.argv[1:]:
        apply(p)
