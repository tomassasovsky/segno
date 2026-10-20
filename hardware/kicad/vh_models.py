"""STEP models for the JST VH top-entry headers (B2P-VH, B3P-VH).

KiCad 10 ships the JST VH footprints but no 3D model for them: its
Connector_JST.3dshapes has XH, EH, PH and the rest and not one VH, so a board
render shows those headers as bare pads. These are drawn from JST's VH catalogue
(eVH.pdf, standard top-entry header): length B = 7.86 / 11.82 mm for 2 / 3
circuits at 3.96 mm pitch, 8.5 mm deep, posts 10.9 mm above the board and 3.7 mm
below. The body outline and the latch wall's side follow the KiCad footprint's F.Fab
layer; base and wall heights are scaled off the catalogue's side view (~3.2 and
~9.6 mm), so read them as a render and a clearance look, not a tight fit check.

Frame matches the footprint: pin 1 at the origin, pins along +x, z up from the
board top.

    ../enclosure/.venv/bin/python vh_models.py     (cadquery)
"""
import os
import cadquery as cq

HERE = os.path.dirname(os.path.abspath(__file__))
PITCH, POST, POST_UP, POST_DOWN = 3.96, 1.14, 10.9, 3.7
# From the catalogue's top-entry side view: a LOW base, and on ONE side of the
# post row a thin latch wall rising above it with a hook at the top that leans
# toward the posts. The housing's latch catches that hook. The other three sides
# are open. The wall is on the side the footprint's F.Fab lock strip marks: its
# outer face 3.7 mm from the pin row, at -y.
BASE_H = 3.2
BODY_Y0, BODY_Y1 = -2.0, 4.8          # base, per the F.Fab body rectangle
WALL_Y0, WALL_T, WALL_H = -3.7, 1.5, 9.6
HOOK_REACH, HOOK_H = 1.2, 1.2
WALL_INSET = 1.2                      # the wall is shorter than the base at each end


def header(n):
    length = {2: 7.86, 3: 11.82}[n]
    x0 = -(length - PITCH * (n - 1)) / 2.0
    base = (cq.Workplane("XY").box(length, BODY_Y1 - WALL_Y0, BASE_H, centered=False)
            .translate((x0, WALL_Y0, 0)))
    wx0, wl = x0 + WALL_INSET, length - 2 * WALL_INSET
    wall = (cq.Workplane("XY").box(wl, WALL_T, WALL_H, centered=False)
            .translate((wx0, WALL_Y0, 0)))
    hook = (cq.Workplane("XY").box(wl, HOOK_REACH, HOOK_H, centered=False)
            .translate((wx0, WALL_Y0 + WALL_T, WALL_H - HOOK_H)))
    shell = base.union(wall).union(hook)
    posts = None
    for i in range(n):
        p = (cq.Workplane("XY").box(POST, POST, POST_UP + POST_DOWN, centered=(True, True, False))
             .translate((i * PITCH, 0, -POST_DOWN)))
        posts = p if posts is None else posts.union(p)
    asm = cq.Assembly(name=f"JST_VH_B{n}P-VH")
    asm.add(shell, name="housing", color=cq.Color(0.95, 0.95, 0.92))
    asm.add(posts, name="posts", color=cq.Color(0.78, 0.78, 0.8))
    return asm


if __name__ == "__main__":
    for n in (2, 3):
        name = f"JST_VH_B{n}P-VH_1x{n:02d}_P3.96mm_Vertical.step"
        path = os.path.join(HERE, "segno.pretty", name)
        header(n).save(path)
        print("wrote", os.path.relpath(path, HERE))
