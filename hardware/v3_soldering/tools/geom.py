# Run with KiCad's Python: dumps footprint geometry for the instruction images.
import json, sys
import pcbnew

board = pcbnew.LoadBoard(sys.argv[1])
mm = pcbnew.ToMM
edge = board.GetBoardEdgesBoundingBox()
out = {
    "board": [mm(edge.GetLeft()), mm(edge.GetTop()), mm(edge.GetRight()), mm(edge.GetBottom())],
    "parts": [],
}


def box_of(items):
    xs, ys = [], []
    for b in items:
        xs += [mm(b.GetLeft()), mm(b.GetRight())]
        ys += [mm(b.GetTop()), mm(b.GetBottom())]
    return [min(xs), min(ys), max(xs), max(ys)] if xs else None


for f in board.GetFootprints():
    flipped = f.IsFlipped()
    fab = pcbnew.B_Fab if flipped else pcbnew.F_Fab
    crt = pcbnew.B_CrtYd if flipped else pcbnew.F_CrtYd
    fab_items = [g.GetBoundingBox() for g in f.GraphicalItems() if g.GetLayer() == fab and g.GetClass() != "PCB_TEXT"]
    crt_items = [g.GetBoundingBox() for g in f.GraphicalItems() if g.GetLayer() == crt]
    pads = []
    for p in f.Pads():
        q, s = p.GetPosition(), p.GetBoundingBox()
        pads.append({
            "n": p.GetNumber(), "x": mm(q.x), "y": mm(q.y),
            "w": mm(s.GetWidth()), "h": mm(s.GetHeight()),
            "smd": p.GetAttribute() == pcbnew.PAD_ATTRIB_SMD,
        })
    pad_box = box_of([p.GetBoundingBox() for p in f.Pads()])
    out["parts"].append({
        "ref": f.GetReference(), "value": f.GetValue(), "back": flipped,
        "fab": box_of(fab_items), "crt": box_of(crt_items), "pads_box": pad_box,
        "pads": pads, "rot": f.GetOrientationDegrees(),
    })

json.dump(out, open(sys.argv[2], "w"), indent=1)
