"""Read the two Segno boards' mechanical data out of their KiCad layouts (#1358).

Writes board_geometry.json next to this file. bench_base.py reads that file, so
the base is built from the same layouts that went to the fab, not from numbers
copied by hand. Re-run after either board's layout changes.

Run with KiCad's own Python, the one that has pcbnew (from the repo root):
    /Applications/KiCad/KiCad.app/Contents/Frameworks/Python.framework/Versions/Current/bin/python3 \
        hardware/bench_base/extract_boards.py [--rev REV]

The layouts are read out of git at REV, not from the working tree, because the
boards on the bench need not match this branch: the V3 boards were soldered
from codex/screen-power-board-1072. With no --rev it re-reads the revision the
current board_geometry.json records, so a plain re-run reproduces it; pass
--rev to move the base to another board revision.

Frame: board-local millimetres, origin at the top-left of the Edge.Cuts outline,
x right, y DOWN (KiCad's own). bench_base.py flips y.
"""
import argparse
import json
import os
import subprocess
import tempfile

import pcbnew

HERE = os.path.dirname(os.path.abspath(__file__))
# Paths relative to hardware/kicad at the revision being read.
BOARDS = {
    # The console board v3 deliverable (routed, DRC-clean), see console_board_pcb.py.
    "console": os.path.join("out_console", "segno_console_board.kicad_pcb"),
    # The ring carrier: XIAO RP2350, encoder, ring pads, see ring_board.py.
    "ring": "segno_pedal_ring.kicad_pcb",
}
T = pcbnew.ToMM


def _box(bb, ox, oy):
    return [round(T(bb.GetX()) - ox, 3), round(T(bb.GetY()) - oy, 3),
            round(T(bb.GetRight()) - ox, 3), round(T(bb.GetBottom()) - oy, 3)]


def extract(path, source):
    b = pcbnew.LoadBoard(path)
    # The edge bounding box includes half the Edge.Cuts line width on each side.
    edge_w = max((d.GetWidth() for d in b.GetDrawings()
                  if d.GetLayerName() == "Edge.Cuts"), default=0)
    bb = b.GetBoardEdgesBoundingBox()
    ox, oy = T(bb.GetX()) + T(edge_w) / 2, T(bb.GetY()) + T(edge_w) / 2
    w, h = T(bb.GetWidth()) - T(edge_w), T(bb.GetHeight()) - T(edge_w)
    shapes = [d.SHAPE_T_asString() for d in b.GetDrawings()
              if d.GetLayerName() == "Edge.Cuts"]
    out = {
        "source": source,
        "outline": {"kind": "circle" if shapes == ["S_CIRCLE"] else "rect",
                    "w": round(w, 3), "h": round(h, 3)},
        "thickness": round(T(b.GetDesignSettings().GetBoardThickness()), 3),
        "holes": [], "back_parts": [], "pth_pads": [],
    }
    for f in b.GetFootprints():
        ref = f.GetReference()
        if ref.startswith("H") and "MountingHole" in f.GetFPIDAsString():
            p = f.GetPosition()
            drill = max(T(pd.GetDrillSize().x) for pd in f.Pads())
            out["holes"].append({"ref": ref, "x": round(T(p.x) - ox, 3),
                                 "y": round(T(p.y) - oy, 3), "drill": round(drill, 3)})
        if f.IsFlipped():
            cy = f.GetCourtyard(pcbnew.B_CrtYd).BBox()
            p = f.GetPosition()
            out["back_parts"].append({"ref": ref, "value": f.GetValue(),
                                      "x": round(T(p.x) - ox, 3), "y": round(T(p.y) - oy, 3),
                                      "rot": round(f.GetOrientationDegrees(), 1),
                                      "courtyard": _box(cy, ox, oy)})
        for pd in f.Pads():
            if pd.GetAttribute() in (pcbnew.PAD_ATTRIB_PTH, pcbnew.PAD_ATTRIB_NPTH) \
                    or (f.IsFlipped() and pd.IsOnLayer(pcbnew.B_Cu)):
                out["pth_pads"].append({"ref": ref, "pad": pd.GetNumber(),
                                        "box": _box(pd.GetBoundingBox(), ox, oy)})
    out["holes"].sort(key=lambda h: h["ref"])
    out["back_parts"].sort(key=lambda p: p["ref"])
    out["pth_pads"].sort(key=lambda p: (p["ref"], p["pad"]))
    return out


def _git(*a):
    return subprocess.run(["git", "-C", HERE, *a], capture_output=True,
                          text=True, check=True).stdout


def main():
    dst = os.path.join(HERE, "board_geometry.json")
    ap = argparse.ArgumentParser(description="board_geometry.json from the KiCad layouts")
    ap.add_argument("--rev", help="git revision to read the layouts from (default: the "
                                  "one board_geometry.json already records)")
    rev = ap.parse_args().rev
    if rev is None:
        with open(dst) as fh:
            rev = json.load(fh)["revision"]
    sha = _git("rev-parse", "--short=9", f"{rev}^{{commit}}").strip()
    data = {"revision": sha}
    with tempfile.TemporaryDirectory() as tmp:
        for name, path in BOARDS.items():
            src = f"hardware/kicad/{path}"
            local = os.path.join(tmp, os.path.basename(path))
            with open(local, "w") as fh:
                fh.write(_git("show", f"{sha}:{src}"))
            data[name] = extract(local, src)
    with open(dst, "w") as fh:
        # One hole, part or pad per line, so a layout change reads as a short diff.
        fh.write("{\n")
        for i, (name, d) in enumerate(data.items()):
            if not isinstance(d, dict):
                fh.write(f' "{name}": {json.dumps(d)},\n')
                continue
            fh.write(f' "{name}": {{\n')
            keys = list(d)
            for k in keys:
                v = d[k]
                end = "," if k != keys[-1] else ""
                if isinstance(v, list):
                    rows = ",\n".join(f"   {json.dumps(r)}" for r in v)
                    fh.write(f'  "{k}": [\n{rows}\n  ]{end}\n')
                else:
                    fh.write(f'  "{k}": {json.dumps(v)}{end}\n')
            fh.write(" }" + ("," if i < len(data) - 1 else "") + "\n")
        fh.write("}")
        fh.write("\n")
    print(f"layouts at {data['revision']}")
    for name, d in data.items():
        if not isinstance(d, dict):
            continue
        print(f"{name}: {d['outline']['kind']} {d['outline']['w']} x {d['outline']['h']}, "
              f"{len(d['holes'])} holes, {len(d['back_parts'])} back-side parts, "
              f"{len(d['pth_pads'])} pads")
    print(f"wrote {dst}")


if __name__ == "__main__":
    main()
