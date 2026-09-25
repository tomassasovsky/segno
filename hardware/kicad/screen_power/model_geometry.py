"""Dimensioned component envelopes for parts absent from KiCad's 3D library.

Run with CadQuery 2.8. Mechanical dimensions and limitations are in models/README.md.
Coordinates match the footprint origin; CAD +Y is the opposite of PCB +Y.
These are assembly models, not manufacturing drawings of the components.
"""
from pathlib import Path

import cadquery as cq

OUT = Path(__file__).resolve().parent / "models"
METAL = cq.Color(0.72, 0.74, 0.77)
BLACK = cq.Color(0.10, 0.11, 0.12)
IVORY = cq.Color(0.89, 0.87, 0.78)


def box(x, y, z, dx, dy, dz):
    return cq.Workplane("XY").box(dx, dy, dz).translate((x, y, z))


def add(assembly, shape, name, color=METAL):
    assembly.add(shape, name=name, color=color)


def save(assembly, name):
    OUT.mkdir(exist_ok=True)
    assembly.save(str(OUT / (name + ".step")))


def relay():
    a = cq.Assembly(name="Axicom_IMSeries")
    # TE drawing 1462037-4: 10 x 6 body, 5.65 seated height,
    # 0.25 standoff, eight 0.4 x 0.2 leads, 3.2 mm below seat.
    add(a, box(2.54, -3.8, 2.95, 6, 10, 5.4), "body", BLACK)
    add(a, box(2.54, .8, 5.655, 5.5, .3, .01), "direction_mark", IVORY)
    for i,x in enumerate((0,5.08)):
        for j,y in enumerate((0,-3.2,-5.4,-7.6)):
            add(a, box(x,y,-1.35,.4,.2,3.7),f"pin_{i}_{j}")
    save(a, "Relay_DPDT_AXICOM_IMSeries_Pitch5.08mm")


def fuse():
    a = cq.Assembly(name="Littelfuse_251")
    # Maximum 7.11 x diameter 2.80 body, nominal 0.64 wire.
    # Formed onto the board's 12.7 mm pitch with the body 0.4 mm above PCB.
    body = cq.Workplane("YZ").circle(1.4).extrude(7.11).translate((2.795, 0, 1.8))
    add(a, body, "body", cq.Color(0.17, 0.36, 0.22))
    for i, (x, end) in enumerate(((0, 2.795), (9.905, 12.7))):
        add(a, cq.Workplane("YZ").circle(.32).extrude(end-x).translate((x, 0, 1.8)), f"wire_{i}")
    for i, x in enumerate((0, 12.7)):
        add(a, cq.Workplane("XY").circle(.32).extrude(4.8).translate((x, 0, -3)), f"leg_{i}")
    save(a, "Fuse_Littelfuse_251_P12.70mm")


def vh():
    a = cq.Assembly(name="JST_B2P_VH")
    # JST standard header (not mating housing): 7.86 x 8.5, 10.9 high.
    add(a, box(1.98, -1.4, 1.05, 7.86, 6.8, 2.1), "base", IVORY)
    add(a, box(1.98, 3.15, 5.45, 5.46, 1.1, 10.9), "latch", IVORY)
    add(a, box(1.98, 2.8, 9.9, 5.46, 1.8, 1), "latch_lip", IVORY)
    for i, x in enumerate((0, 3.96)):
        add(a, box(x, 0, 3.1, 1.14, 1.14, 13.6), f"pin_{i}")
    save(a, "JST_VH_B2P-VH_1x02_P3.96mm_Vertical")


if __name__ == "__main__":
    relay()
    fuse()
    vh()
