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


def fuse_cartridge(a, center_x, center_y, z, ceramic=False):
    # 5 x 20 mm replaceable cartridge; caps and body are distinct solids.
    color = IVORY if ceramic else cq.Color(.65, .78, .81, .45)
    body = cq.Workplane("YZ").circle(2.6).extrude(20).translate((center_x-10, center_y, z))
    add(a, body, "cartridge_body", color)
    for i, x in enumerate((center_x-10, center_x+5)):
        cap = cq.Workplane("YZ").circle(2.6).extrude(5).translate((x, center_y, z))
        add(a, cap, f"cartridge_cap_{i}")


def fuse_holders():
    a = cq.Assembly(name="Schurter_OGN_0031_8201")
    # The exact THT holder is 25 x 9.6 mm, with 10.8 mm installation width.
    # Contact springs/fuse rise to 11.5 mm; no optional protective cover.
    add(a, box(11.25, 0, 1.2, 25, 9.6, 2.4), "base", BLACK)
    for i, x in enumerate((0, 22.5)):
        add(a, box(x, 0, 5.6, 2.5, 9.6, 6.4), f"end_wall_{i}", BLACK)
        add(a, box(x, 0, 5, 1.1, 7, 8), f"contact_{i}")
        lead = cq.Workplane("XY").circle(.55).extrude(4).translate((x, 0, -4))
        add(a, lead, f"lead_{i}")
    fuse_cartridge(a, 11.25, 0, 8.9, ceramic=True)
    save(a, "Fuseholder_Schurter_OGN_0031.8201")


def radial_fuse():
    a = cq.Assembly(name="Bel_0697H")
    # Published maximum body and lead envelope; stock leads are trimmed in assembly.
    add(a, box(2.54, 0, 4.05, 8.65, 4.30, 8.10), "body", cq.Color(.75, .70, .22))
    for i, x in enumerate((0, 5.08)):
        leg = cq.Workplane("XY").circle(.35).extrude(3).translate((x, 0, -3))
        add(a, leg, f"lead_{i}")
    save(a, "Fuse_Bel_0697H_P5.08mm")


def power_relay():
    a = cq.Assembly(name="Omron_G6C_1117P_US")
    # Omron G6C-1117P-US, datasheet page 7: 20 x 15 x 10 mm maximum body on a
    # 0.3 mm standoff, terminals 0.9 x 0.5 mm projecting 3.5 mm below the
    # seating plane. The origin is pin 1; pins 3 and 4 run in -X and pin 8 in
    # +Y, matching the footprint's converted top view.
    add(a, box(-8.89, -5.06, 5.3, 20, 15, 10), "body", cq.Color(.13, .14, .16))
    # Orientation mark on the pin 1 / pin 8 end of the case top.
    add(a, box(0.11, -5.06, 10.305, 1.6, 1.6, .01), "orientation_mark", IVORY)
    for name, (x, y) in (("coil_minus_1", (0, 0)), ("coil_plus_8", (0, -10.16)),
                         ("contact_3", (-10.16, 0)), ("contact_4", (-17.78, 0))):
        add(a, box(x, y, -1.6, .9, .5, 3.8), "terminal_" + name)
    save(a, "Relay_Omron_G6C-1117P-US")




def vh():
    a = cq.Assembly(name="JST_B2P_VH")
    # JST standard header (not mating housing): 7.86 x 8.5, 10.9 high.
    add(a, box(1.98, -1.4, 1.05, 7.86, 6.8, 2.1), "base", IVORY)
    add(a, box(1.98, 3.15, 5.45, 5.46, 1.1, 10.9), "latch", IVORY)
    add(a, box(1.98, 2.8, 9.9, 5.46, 1.8, 1), "latch_lip", IVORY)
    for i, x in enumerate((0, 3.96)):
        add(a, box(x, 0, 3.1, 1.14, 1.14, 13.6), f"pin_{i}")
    save(a, "JST_VH_B2P-VH_1x02_P3.96mm_Vertical")


def electrolytic(name, diameter, height, pitch, lead):
    # Panasonic nominal body dimensions; the footprint origin is pin 1.
    # Worst-case body envelopes are documented separately for fit review.
    a = cq.Assembly(name=name)
    center = pitch / 2
    can = cq.Workplane("XY").circle(diameter / 2).extrude(height-.2).translate((center, 0, 0))
    # Split the sleeve surface so the polarity stripe is visible without
    # increasing the published body envelope or hiding it inside the can.
    stripe = can.intersect(box(center+diameter/2, 0, height/2, .2, .5, height-.4))
    add(a, can.cut(stripe), "sleeve", cq.Color(.08, .25, .48))
    add(a, stripe, "negative_stripe", IVORY)
    top = cq.Workplane("XY").circle(diameter / 2-.1).extrude(.2)
    add(a, top.translate((center, 0, height-.2)), "top")
    for i, x in enumerate((0, pitch)):
        leg = cq.Workplane("XY").circle(lead / 2).extrude(3)
        add(a, leg.translate((x, 0, -3)), f"lead_{i}")
    save(a, name)


def power_resistor():
    a = cq.Assembly(name="Vishay_PR01_P10_16mm")
    # Vishay 28729 p16: maximum 6.5mm main body, 8mm coating extent,
    # 2.5mm diameter and 0.63mm leads. The end coating deliberately uses
    # the full diameter as a conservative envelope, not a vendor shape.
    pitch, height = 10.16, 1.75
    start = (pitch - 8) / 2
    for name, x, length, color in (
            ("coating_left", start, .75, cq.Color(.48, .08, .06)),
            ("main_body", start+.75, 6.5, cq.Color(.65, .10, .07)),
            ("coating_right", start+7.25, .75, cq.Color(.48, .08, .06))):
        body = cq.Workplane("YZ").circle(1.25).extrude(length)
        add(a, body.translate((x, 0, height)), name, color)
    # Simplified formed leads: 0.5mm body standoff, trimmed at z=-3mm.
    for i, (x, end) in enumerate(((0, start), (start+8, pitch))):
        wire = cq.Workplane("YZ").circle(.315).extrude(end-x)
        add(a, wire.translate((x, 0, height)), f"wire_{i}")
    for i, x in enumerate((0, pitch)):
        leg = cq.Workplane("XY").circle(.315).extrude(height+3)
        add(a, leg.translate((x, 0, -3)), f"lead_{i}")
    save(a, "Vishay_PR01_P10.16mm")


if __name__ == "__main__":
    relay()
    power_relay()
    fuse_holders()
    radial_fuse()
    vh()
    electrolytic("Panasonic_EEUFR1A221", 6.3, 11.2, 2.5, .5)
    electrolytic("Panasonic_EEUFR1A151", 5, 11, 2, .5)
    power_resistor()
