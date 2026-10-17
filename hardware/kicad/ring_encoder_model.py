"""Build the nominal Same Sky ACZ11BR1E-20FD1-20C clearance envelope.

Source: ACZ11 rev 1.08 (2026-05-07), pp. 1, 2, 4; see RING_ENCODER.md.
Run with the enclosure CadQuery environment. This is a drawing-derived envelope,
not manufacturer CAD. Threads, internal contacts and undimensioned shell details
are omitted. Tail thickness is illustrative; hole fit uses the recommended PCB
openings independently. Coordinates are KiCad model X/right, Y/up, Z/outward.
"""
from pathlib import Path
import cadquery as cq

NAME = "RotaryEncoder_SameSky_ACZ11BR1E-20FD1-20C"


def encoder():
    model = cq.Assembly(name=NAME)
    body = (cq.Workplane("XY").box(11.7, 13.75, 6.5,
                                 centered=(True, True, False))
            .translate((0, 0.375, 0)))
    bush = cq.Workplane("XY").circle(3.5).extrude(5).translate((0, 0, 6.5))
    shaft = cq.Workplane("XY").circle(3).extrude(20).translate((0, 0, 6.5))
    # Top 10 mm of shaft is flat: across-flat dimension 4.5 mm.
    cutter = (cq.Workplane("XY").box(10, 5, 10, centered=(True, False, False))
              .translate((0, 1.5, 16.5)))
    shaft = shaft.cut(cutter)
    model.add(body, name="body_envelope", color=cq.Color(0.28, 0.29, 0.31))
    model.add(bush, name="M7_bushing_envelope", color=cq.Color(0.75, 0.75, 0.77))
    model.add(shaft, name="D_shaft", color=cq.Color(0.82, 0.82, 0.84))
    for name, x, y in (("A", -2.5, -7.5), ("C", 0, -7.5),
                       ("B", 2.5, -7.5), ("S1", -2.5, 7), ("S2", 2.5, 7)):
        pin = (cq.Workplane("XY").box(0.5, 0.5, 4, centered=(True, True, False))
               .translate((x, y, -4)))
        model.add(pin, name=name, color=cq.Color(0.8, 0.8, 0.8))
    for name, x in (("MP1", -4.7), ("MP2", 4.7)):
        tab = (cq.Workplane("XY").box(1, 2, 4, centered=(True, True, False))
               .translate((x, 0, -4)))
        model.add(tab, name=name, color=cq.Color(0.75, 0.75, 0.77))
    return model


if __name__ == "__main__":
    target = Path(__file__).parent / "segno.pretty" / (NAME + ".step")
    encoder().save(str(target))
    print(target)
