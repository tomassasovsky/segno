"""Check actual encoder geometry against Same Sky ACZ11 rev 1.08, pp. 1–4.

Run with KiCad Python; --self-test deliberately breaks geometry and net roles.
The manufacturer contract and finished-hole tolerance are in RING_ENCODER.md.
"""
import argparse
import math
from pathlib import Path

import pcbnew as pcb

HERE = Path(__file__).resolve().parent
NAME = "RotaryEncoder_SameSky_ACZ11BR1E-20FD1-20C"
PART = "ACZ11BR1E-20FD1-20C"
SHAFT = (35.9825, 35.7675)
# Top view; same A/C/B and switch D/E labels as the manufacturer's drawing.
PADS = {"A": (-2.5, 7.5), "C": (0, 7.5), "B": (2.5, 7.5),
        "S1": (-2.5, -7), "S2": (2.5, -7),
        "MP1": (-4.7, 0), "MP2": (4.7, 0)}
NETS = {"A": "ENC_A", "C": "GND", "B": "ENC_B", "S1": "ENC_SW",
        "S2": "GND", "MP1": "", "MP2": ""}
# PCB fab's finished PTH tolerance. Both ends matter: fit and remaining annulus.
DRILL_UNDERSIZE = 0.08
DRILL_OVERSIZE = 0.13


def mm(vector):
    return vector.x / 1e6, vector.y / 1e6


def require(condition, message):
    if not condition:
        raise AssertionError("RING_ENCODER: " + message)


def check_footprint(footprint, placed=False):
    pads = {pad.GetNumber(): pad for pad in footprint.Pads()}
    require(set(pads) == set(PADS), "pin set differs from the vertical switched part")
    require(footprint.GetFPID().GetLibItemName() == NAME, "wrong footprint")
    require(not footprint.IsFlipped(), "encoder must be on the front")
    require(abs(footprint.GetOrientationDegrees()) < 1e-6, "encoder rotated")
    origin = mm(footprint.GetPosition())
    if placed:
        require(math.dist(origin, SHAFT) < 1e-5, "shaft centre moved")
        require(footprint.GetValue() == PART, "BOM part differs from physical fit")
    for number, xy in PADS.items():
        pad = pads[number]
        local = tuple(v - o for v, o in zip(mm(pad.GetPosition()), origin))
        require(math.dist(local, xy) < 1e-5, number + " differs from drawing position")
        require(pad.GetAttribute() == pcb.PAD_ATTRIB_PTH, number + " must be plated THT")
        dx, dy = mm(pad.GetDrillSize())
        require(abs(dx-dy) < 1e-6 and pad.GetDrillShape() == pcb.PAD_DRILL_SHAPE_CIRCLE,
                number + " must use the validated circular drill")
        minimum = math.hypot(1.8, 2.1) if number.startswith("MP") else 1.2
        require(dx - DRILL_UNDERSIZE >= minimum,
                number + " finished hole cannot contain manufacturer's opening")
        sx, sy = mm(pad.GetSize())
        # Both specified pad/drill pairs leave 0.235 mm at maximum hole size.
        # Round that design bound down to 0.23; it is a concentric diameter
        # check, not the fabricator's nominal rule or a registration allowance.
        require(min(sx, sy) / 2 - (dx + DRILL_OVERSIZE) / 2 >= 0.23,
                number + " has insufficient concentric annulus at maximum hole size")
        if placed:
            require(pad.GetNetname() == NETS[number], number + " is assigned the wrong signal")
    models = list(footprint.Models())
    require(len(models) == 1 and models[0].m_Filename ==
            "${KIPRJMOD}/segno.pretty/" + NAME + ".step", "wrong model")
    model = models[0]
    require(all(abs(v) < 1e-6 for v in (model.m_Offset.x, model.m_Offset.y,
                                      model.m_Offset.z, model.m_Rotation.x,
                                      model.m_Rotation.y, model.m_Rotation.z)),
            "model no longer shares the shaft datum")
    require(all(abs(v-1) < 1e-6 for v in (model.m_Scale.x, model.m_Scale.y, model.m_Scale.z)),
            "model scale changed")
    require((HERE / "segno.pretty" / (NAME + ".step")).is_file(), "model missing")


def check(board):
    encoders = [fp for fp in board.GetFootprints() if fp.GetReference() == "ENC1"]
    require(len(encoders) == 1, "one ENC1 required")
    check_footprint(encoders[0], placed=True)
    library = pcb.FootprintLoad(str(HERE / "segno.pretty"), NAME)
    require(library is not None, "library footprint cannot load")
    check_footprint(library)


def self_test(path):
    def run(label, mutate, expected):
        board = pcb.LoadBoard(str(path))
        fp = next(f for f in board.GetFootprints() if f.GetReference() == "ENC1")
        pads = {p.GetNumber(): p for p in fp.Pads()}
        mutate(board, fp, pads)
        try:
            check(board)
        except AssertionError as error:
            require(expected in str(error), "wrong rejection for " + label + ": " + str(error))
            print("Rejected:", label)
        else:
            raise AssertionError("Fault escaped: " + label)

    def move(pad, dx, dy):
        pad.SetPosition(pad.GetPosition() + pcb.VECTOR2I(round(dx*1e6), round(dy*1e6)))

    run("MP1 shifted 0.8 mm outward", lambda b,f,p: move(p["MP1"], -.8, 0), "position")
    run("A-C spacing changed to 2.54 mm", lambda b,f,p: move(p["A"], -.04, 0), "position")
    run("wrong switch row", lambda b,f,p: move(p["S1"], 0, -.25), "position")
    run("2.8 mm support drill fails finished tolerance",
        lambda b,f,p: p["MP1"].SetDrillSize(pcb.VECTOR2I(2800000, 2800000)), "finished hole")
    run("undersized signal annulus",
        lambda b,f,p: p["A"].SetSize(pcb.VECTOR2I(1800000, 1800000)), "annulus")
    run("A assigned the B signal", lambda b,f,p: p["A"].SetNet(p["B"].GetNet()), "wrong signal")
    run("shaft moved", lambda b,f,p: f.SetPosition(f.GetPosition()+pcb.VECTOR2I(0,250000)),
        "shaft centre")
    run("generic part substitution", lambda b,f,p: f.SetValue("EC11E18244AU"), "BOM part")
    check(pcb.LoadBoard(str(path)))
    print("Eight negative controls passed; original board still passes.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("board", nargs="?", type=Path, default=HERE / "segno_pedal_ring.kicad_pcb")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    check(pcb.LoadBoard(str(args.board)))
    print("Same Sky encoder fit, finished-hole tolerance, pad roles and model datum: PASS")
    if args.self_test:
        self_test(args.board)
