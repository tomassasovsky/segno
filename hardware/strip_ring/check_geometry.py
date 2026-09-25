"""Mechanical/mesh checks for the exported strip ring, not optical validation."""

from itertools import combinations
from math import cos, sin
import hashlib
import json
import numpy as np
import cadquery as cq
import strip_ring as m


def empty_intersection(a, b, name):
    volume = a.intersect(b).Volume()
    assert volume < 1e-6, (name, volume)


def check_emitter_clearance(board, leds):
    """The whole emitting-face height clears the populated inward-light zone.

    A centre ray alone is insufficient: the original layout passed that check
    while its LEDs shone directly into the PCB edge.
    """
    lowest = min(s.BoundingBox().zmin for s in leds)
    populated_zone = board.intersect(m.annulus(43.1, 26.65, -25, 2))
    component_top = populated_zone.BoundingBox().zmax
    assert lowest-component_top > 1.0, "emitter face below populated board clearance"
    pcb = max(board.Solids(), key=lambda s: s.Volume())
    assert lowest-pcb.BoundingBox().zmax > 3.0, "emitter face below PCB clearance"
    transport = m.annulus(43.1, 26.65, lowest-.01, m.FACE_Z-.81)
    empty_intersection(transport, board, "whole upward light volume/board")
    return lowest-pcb.BoundingBox().zmax, lowest-component_top


def check_cap_hold_down(cap, retainer, screws):
    """Seated heads resist lifting without a knob; posts provide thread material."""
    for (x,y),screw in zip(m.CAP_SCREWS, screws, strict=True):
        empty_intersection(cap, screw, "seated cap screw")
        assert cap.translate((0,0,.05)).intersect(screw).Volume() > .01, "cap lifts past screw head"
        thread_wall = m.annulus(1.49, 1.26, 1.41, m.CAP_SEAT_Z-.01).translate((x,y,0))
        assert thread_wall.cut(retainer).Volume() < 1e-7, "cap post lacks thread wall"
        bearing = m.annulus(4.9,1.8,m.CAP_SEAT_Z-.01,m.CAP_SEAT_Z).translate((x,y,0))
        assert bearing.cut(retainer).Volume() < 1e-7, "cap post lacks bearing"
        pad = bearing.translate((0,0,.01))
        assert pad.cut(cap).Volume() < 1e-7, "cap lacks screw pad"
        pilot = cq.Solid.makeCylinder(1.24, m.CAP_SEAT_Z-1+.02, cq.Vector(x,y,.99))
        empty_intersection(pilot, retainer, "cap pilot")
        # Flat-under-head bearing must sit on a full 1 mm web, not a countersink.
        web = m.annulus(3.49,1.71,m.CAP_HEAD_FLOOR_Z-1.0,m.CAP_HEAD_FLOOR_Z).translate((x,y,0))
        assert web.cut(cap).Volume() < 1e-7, "cap head lacks flat bearing web"
        pocket = cq.Solid.makeCylinder(3.69,2.6,cq.Vector(x,y,m.CAP_HEAD_FLOOR_Z))
        empty_intersection(pocket, cap, "cap head pocket")


def check_base_hold_down(base, shield, screws):
    """Flat SSD heads capture a solid web; blind pilots provide 4 mm engagement."""
    for (x,y),screw in zip(m.BASE_SCREWS,screws,strict=True):
        empty_intersection(base,screw,"seated base screw")
        assert base.translate((0,0,-.05)).intersect(screw).Volume()>.01, "base drops past head"
        web=m.annulus(3.49,1.71,m.BASE_TOP-1,m.BASE_TOP).translate((x,y,0))
        assert web.cut(base).Volume()<1e-7, "base lacks 1 mm flat bearing web"
        pocket=cq.Solid.makeCylinder(3.69,2.6,cq.Vector(x,y,m.BASE_BOTTOM))
        empty_intersection(pocket,base,"flat base head pocket")
        outside=m.annulus(4.69,3.71,m.BASE_BOTTOM+.01,m.BASE_HEAD_FLOOR_Z-.01).translate((x,y,0))
        assert outside.cut(base).Volume()<1e-7, "base head pocket lacks outer wall"
        thread=m.annulus(2.49,1.26,m.BASE_TOP,m.BASE_TOP+3.99).translate((x,y,0))
        assert thread.cut(shield).Volume()<1e-7, "base pilot lacks wall or engagement"
        pilot=cq.Solid.makeCylinder(1.24,4.39,cq.Vector(x,y,m.BASE_TOP))
        empty_intersection(pilot,shield,"base blind pilot")
        closure=cq.Solid.makeCylinder(1.24,.49,cq.Vector(x,y,m.BASE_TOP+4.41))
        assert closure.cut(shield).Volume()<1e-7, "base pilot lacks closed end at intended depth"
        bounds=screw.BoundingBox()
        assert bounds.zmin-m.BASE_BOTTOM>=.199, "base head protrudes beneath bench face"
        assert bounds.zmax-m.BASE_TOP>=3.999, "base thread engagement"
        assert m.BASE_TOP+4.4-bounds.zmax>=.399, "base screw bottoms in pilot"


def check_mesh(path, expected):
    # CadQuery writes binary STL. Weld identical coordinates, then require two
    # incident faces on every undirected edge. Signed volume catches orientation.
    data = path.read_bytes()
    count = int.from_bytes(data[80:84], "little")
    assert len(data) == 84 + count * 50, path.name
    records = np.frombuffer(data, dtype=np.dtype([
        ("normal", "<f4", (3,)), ("vertices", "<f4", (3, 3)), ("attr", "<u2")]), offset=84)
    triangles = records["vertices"].astype(np.float64)
    points, faces = np.unique(np.round(triangles.reshape(-1, 3), 6),
                              axis=0, return_inverse=True)
    faces = faces.reshape(-1, 3)
    edges = np.concatenate([faces[:, [0, 1]], faces[:, [1, 2]], faces[:, [2, 0]]])
    _, counts = np.unique(np.sort(edges, axis=1), axis=0, return_counts=True)
    assert np.all(counts == 2), (path.name, "open/nonmanifold mesh")
    area = np.linalg.norm(np.cross(triangles[:, 1] - triangles[:, 0],
                                   triangles[:, 2] - triangles[:, 0]), axis=1)
    assert np.all(area > 1e-10), (path.name, "degenerate face")
    vol = np.einsum("ij,ij->i", triangles[:, 0],
                    np.cross(triangles[:, 1], triangles[:, 2])).sum() / 6
    assert abs(vol / expected.Volume() - 1) < 0.005, (path.name, vol)
    assert abs(points[:, 2].min()) < 1e-5, (path.name, "not on bed")
    for i, size in enumerate((expected.BoundingBox().xlen,
                              expected.BoundingBox().ylen,
                              expected.BoundingBox().zlen)):
        assert abs(np.ptp(points[:, i]) - size) < 0.07, path.name
    print(f"  {path.name}: closed, positive volume, bed-oriented")


def run():
    parts = m.parts()
    for name, shape in parts.items():
        assert shape.isValid() and len(shape.Solids()) == 1, name
        step = cq.importers.importStep(str(m.OUT / f"strip_ring_{name}.step")).val()
        assert step.isValid() and len(step.Solids()) == 1, name
        assert abs(step.Volume() / shape.Volume() - 1) < 1e-7, name
        assert (step.Center() - shape.Center()).Length < 1e-6, (name, "STEP placement")
        for dim in ("xmin", "xmax", "ymin", "ymax", "zmin", "zmax"):
            assert abs(getattr(step.BoundingBox(),dim)-getattr(shape.BoundingBox(),dim)) < 1e-5, name
        check_mesh(m.OUT / f"strip_ring_{name}.stl", m.print_pose(name, shape))
    for (an, a), (bn, b) in combinations(parts.items(), 2):
        empty_intersection(a, b, an + "/" + bn)
    actual_board = m.controller()
    small_board = cq.importers.importStep(str(m.HERE/'reference/controller_60mm_without_ring.step')).val()
    provenance=json.loads((m.HERE/'reference/provenance.json').read_text())
    for key,model,diameter in (("68mm",actual_board,68),("60mm",small_board,60)):
        info=provenance['sources'][key]
        path=m.HERE/'reference'/info['reference_file']
        assert hashlib.sha256(path.read_bytes()).hexdigest()==info['reference_sha256'], "board reference drift"
        pcb=max(model.Solids(),key=lambda s:s.Volume()).BoundingBox()
        assert abs(pcb.xlen-diameter)<1e-5 and abs(pcb.ylen-diameter)<1e-5, "wrong smaller board"
        assert abs(model.BoundingBox().zmax-17.5)<1e-5, "changed encoder shaft height"
    # One enclosure must clear either documented smaller passive board. Keep
    # the larger 68 mm version as the assembly/preview reference only.
    board = cq.Compound.makeCompound([*actual_board.Solids(),*small_board.Solids()])
    fpc, leds = m.led_strip()
    pcb_gap, populated_gap = check_emitter_clearance(board, leds)
    # Regression control: the old emitter elevation must fail, even though a
    # single sloping ray from its centre can still reach the roof.
    try:
        check_emitter_clearance(board, [s.translate((0,0,-7)) for s in leds])
    except AssertionError:
        pass
    else:
        raise AssertionError("old obstructed emitter elevation was accepted")
    delivered = cq.importers.importStep(str(m.OUT / "strip_ring_assembly.step")).val()
    assert delivered.isValid(), "assembly STEP"
    expected = list(parts.values()) + [fpc] + leds + [actual_board, m.knob()] + m.cap_screws() + m.base_screws()
    expected = [solid for shape in expected for solid in shape.Solids()]
    remaining = list(delivered.Solids())
    assert len(remaining) == len(expected), "assembly body count"
    for solid in expected:
        candidate = min(remaining, key=lambda s: (s.Center()-solid.Center()).Length)
        assert (candidate.Center()-solid.Center()).Length < 1e-5, "assembly placement"
        assert abs(candidate.Volume()-solid.Volume()) < max(1e-5, solid.Volume()*1e-6), "assembly volume"
        assert abs(candidate.Area()-solid.Area()) < max(1e-4, solid.Area()*1e-6), "assembly area"
        remaining.remove(candidate)
    assert len(leds) == 40
    assert abs(fpc.Volume() / (m.CUT_LENGTH * m.FPC_T * m.STRIP_W) - 1) < 1e-7
    for name, shape in parts.items():
        for other_name, other in (("controller", board), ("knob", m.knob()),
                                  ("strip", fpc)):
            empty_intersection(shape, other, name + "/" + other_name)
        for led in leds:
            empty_intersection(shape, led, name + "/LED")
    min_led_gap = min(leds[i].distance(leds[(i + 1) % len(leds)]) for i in range(len(leds)))
    assert min_led_gap > 1.2, min_led_gap
    assert m.NEUTRAL_R - m.FPC_T / 2 - m.LED_H > 42.4
    assert m.SHIELD_R < 58.6 - 10, "screen envelope margin"
    assert abs(parts["diffuser"].BoundingBox().zmax - m.FACE_Z) < 1e-7
    assert abs(parts["centre_disc"].BoundingBox().zmax - m.FACE_Z) < 1e-7
    assert abs(parts["encoder_retainer"].BoundingBox().zmax - m.CAP_SEAT_Z) < 1e-7
    nut_land = m.annulus(8,4.3,1,2)
    assert nut_land.cut(parts["encoder_retainer"]).Volume() < 1e-7, "encoder clamp plane"
    # Roof thickness and continuous disc bearing, measured from actual material.
    roof_probe = m.box(.4, .4, .8, (29.6, 0, m.FACE_Z-.4))
    assert roof_probe.cut(parts["diffuser"]).Volume() < 1e-8
    below_roof = m.box(.4, .4, .1, (29.6, 0, m.FACE_Z-.86))
    empty_intersection(below_roof, parts["diffuser"], "open under roof")
    retainer_footprint = m.annulus(24.0, 9.3, .99, 1)
    assert retainer_footprint.cut(parts["diffuser"]).Volume() < 1e-7
    cap_bearing = m.annulus(25.5, 24.3, 1.99, 2)
    assert cap_bearing.intersect(parts["encoder_retainer"]).Volume()/.01 > 170
    # The cap is clamped by two screws independently of the knob. Once both
    # screws are removed, it lifts off to expose the original encoder nut.
    cap = parts["centre_disc"]
    screws = m.cap_screws()
    assert abs(cap.BoundingBox().zmin-2) < 1e-7
    check_cap_hold_down(cap, parts["encoder_retainer"], screws)
    # Regression control: a plate with no posts cannot satisfy the hold-down.
    try:
        check_cap_hold_down(cap, m.annulus(25.6,4.25,1,2), screws)
    except AssertionError:
        pass
    else:
        raise AssertionError("unfastened cap support accepted")
    cap_obstacles = cq.Compound.makeCompound([
        s for n,s in parts.items() if n != "centre_disc"] + [board])
    for lift in (.4, .8, 1.0, 20):
        empty_intersection(cap.translate((0,0,lift)), cap_obstacles, "cap removal")
    assert cap.rotate((0,0,0), (0,0,1), 2).intersect(cq.Compound.makeCompound(screws)).Volume() > .01
    nut_envelope = m.annulus(6, 3.6, 2, 5)
    empty_intersection(nut_envelope, cap, "nut/face cap")
    # Space for a 20 mm OD socket after cap removal; shaft passes inside it.
    nut_tool = m.annulus(10,4.25,2.01,24)
    empty_intersection(nut_tool, parts["encoder_retainer"], "nut tool/posts")
    for x,y in m.CAP_SCREWS:
        driver = cq.Solid.makeCylinder(2.8,20,cq.Vector(x,y,m.CAP_HEAD_FLOOR_Z+.01))
        empty_intersection(driver, cap_obstacles, "cap screw driver access")
        empty_intersection(driver, cap, "driver inside head pocket")
    for screw in screws:
        bounds = screw.BoundingBox()
        assert m.FACE_Z-bounds.zmax >= .199, "cap head lacks recess allowance"
        assert bounds.zmin-1 >= .399, "cap screw tip too close to diffuser floor"
        assert m.CAP_SEAT_Z-bounds.zmin >= 3.999, "cap screw thread engagement"
        for name, obstacle in parts.items():
            if name != "encoder_retainer":  # shank envelope overlaps pilot thread material
                empty_intersection(screw, obstacle, "cap screw/" + name)
        empty_intersection(screw, board, "cap screw/controller")
        empty_intersection(screw, fpc, "cap screw/strip")
    # Conservatively swept bounding boxes prove the disconnected controller can
    # move downward continuously after the disc, spacer and nut are removed.
    removal_obstacles = cq.Compound.makeCompound([
        shape for name, shape in parts.items()
        if name not in ("encoder_spacer", "encoder_retainer", "centre_disc", "bottom_cover")])
    for solid in board.Solids():
        b = solid.BoundingBox()
        swept = m.box(b.xlen, b.ylen, b.zlen + 35,
                      ((b.xmin+b.xmax)/2, (b.ymin+b.ymax)/2, (b.zmin+b.zmax)/2-17.5))
        # A rectangular PCB bounding box has corners outside its actual circle.
        if b.xlen > 50 and abs(b.xlen-b.ylen)<.01:
            swept = cq.Solid.makeCylinder(b.xlen/2+.04, b.zlen+35,
                                          cq.Vector((b.xmin+b.xmax)/2,(b.ymin+b.ymax)/2,b.zmin-35))
        empty_intersection(swept, removal_obstacles, "continuous board withdrawal")
    # Black material covers the complete white cup roof and the hidden lens
    # flange in plan view; only the intended 67 mm annulus remains exposed.
    roof_mask = m.annulus(m.CUP_R, 33.5, m.LIGHT_LIFT+.1, m.FACE_Z-.1)
    assert roof_mask.cut(parts["top_cover"]).Volume() < 1e-7
    closed_floor = cq.Solid.makeCylinder(40.1, .2, cq.Vector(0,0,m.BASE_TOP-.4))
    assert closed_floor.cut(parts["bottom_cover"]).Volume() < 1e-7
    assert parts["bottom_cover"].distance(board) > 2.0
    bottom_screws=m.base_screws()
    check_base_hold_down(parts["bottom_cover"],parts["shield"],bottom_screws)
    # A thinned web must not pass solely because there is still some bearing.
    x,y=m.BASE_SCREWS[0]
    thinned=parts["bottom_cover"].cut(cq.Solid.makeCylinder(3.6,.2,cq.Vector(x,y,m.BASE_HEAD_FLOOR_Z)))
    try:
        check_base_hold_down(thinned,parts["shield"],bottom_screws)
    except AssertionError:
        pass
    else:
        raise AssertionError("thin base bearing web accepted")
    through=parts["shield"].cut(cq.Solid.makeCylinder(1.25,35,cq.Vector(x,y,m.BASE_TOP)))
    try:
        check_base_hold_down(parts["bottom_cover"],through,bottom_screws)
    except AssertionError:
        pass
    else:
        raise AssertionError("through base pilot accepted as blind")
    for (x,y),screw in zip(m.BASE_SCREWS,bottom_screws,strict=True):
        assert m.STRIP_BOTTOM-screw.BoundingBox().zmax>7, "screw near strip"
        clearance=cq.Solid.makeCylinder(1.69,m.BASE_THICKNESS+.01,cq.Vector(x,y,m.BASE_BOTTOM))
        empty_intersection(clearance,parts["bottom_cover"],"base screw clearance")
        driver=cq.Solid.makeCylinder(2.8,20,cq.Vector(x,y,m.BASE_HEAD_FLOOR_Z-20))
        empty_intersection(driver,parts["bottom_cover"],"base driver access")
        for name,obstacle in parts.items():
            if name!="shield":
                empty_intersection(screw,obstacle,"base screw/"+name)
        empty_intersection(screw, board, "screw/controller")
        empty_intersection(screw, fpc, "screw/strip")
    port = m.box(7.8, 15, 2.8, (0,46,m.BASE_TOP+1.5))
    empty_intersection(port, parts["shield"], "rear outlet")
    empty_intersection(port, parts["bottom_cover"], "rear outlet/base")
    # The old outward-facing strip seam is now masked by an unbroken black wall.
    seam_mask = m.box(.8, 2, 4, (m.SHIELD_R-.5,0,m.SHIELD_BOTTOM+2.5))
    assert seam_mask.cut(parts["shield"]).Volume() < 1e-6
    printed = cq.Compound.makeCompound(list(parts.values()))
    # Entire purchased knob is above the coplanar face. This checks its outside
    # envelope only; actual D-bore depth and push-on retention need a physical fit.
    knob_sweep = cq.Solid.makeCylinder(25, 18.4, cq.Vector(0,0,m.KNOB_BOTTOM-.4))
    empty_intersection(knob_sweep, printed, "knob rotation and 0.4 mm push envelope")
    empty_intersection(knob_sweep, cq.Compound.makeCompound(screws), "knob/cap fasteners")
    assert abs(m.knob().BoundingBox().zmin-m.FACE_Z-.5) < 1e-7, "knob buried or too high"
    assert abs(m.knob().BoundingBox().zlen-18) < 1e-7, "purchased knob height"
    empty_intersection(m.knob(), board, "reference knob cavity/shaft")
    empty_intersection(m.knob().translate((0,0,-.4)), board, "reference cavity/pressed shaft")
    shaft_top = board.BoundingBox().zmax
    assert 7.9 < shaft_top-m.KNOB_BOTTOM < 8.1, "nominal shaft insertion"
    # Regression: the rejected recessed knob must collide with the level cap.
    assert m.knob().translate((0,0,-7)).intersect(cap).Volume() > 100
    # One line of sight to the annular roof from each emitting-face centre.
    # The radius is a narrow probe, not a photometric ray-tracing model.
    for i in range(m.COUNT):
        a = (m.SEAM/2 + (i+.5)*m.PITCH) / m.NEUTRAL_R
        r0 = m.NEUTRAL_R - m.FPC_T/2 - m.LED_H - .04
        p = cq.Vector(r0*cos(a), r0*sin(a), (m.STRIP_TOP+m.STRIP_BOTTOM)/2)
        q = cq.Vector(29.6*cos(a), 29.6*sin(a), m.FACE_Z-.84)
        direction = q-p
        ray = cq.Solid.makeCylinder(.01, direction.Length, p, direction.normalized())
        empty_intersection(ray, printed, "light path to roof")
        empty_intersection(ray, board, "light path past controller")
    print(f"PASS: {len(parts)} parts; 40 LEDs; {m.CUT_LENGTH:.2f} mm strip; "
          f"minimum LED gap {min_led_gap:.2f} mm; OD {2*m.SHIELD_R:.2f} mm")
    print("PASS: coplanar face and supported cap/retainer, controller/strip clearance, "
          "removable base, opaque roof coverage, screw/cable paths, "
          "continuous board withdrawal, delivered assembly and 40 open light paths")
    print(f"PASS: entire LED face {pcb_gap:.3f} mm above PCB and {populated_gap:.3f} mm "
          "above highest board material in optical annulus; old elevation rejected; whole knob above face")
    print(f"PASS: knob running gap 0.5 mm; nominal gross shaft insertion {shaft_top-m.KNOB_BOTTOM:.2f} mm; "
          "independent screw hold-down, nut access and cap removal checked; recessed knob rejected")
    print("PASS: cap M3 x 5 / Ø7 head envelopes; 1 mm flat bearing webs, 4 mm thread engagement, "
          "0.4 mm tip-to-floor clearance, 0.2 mm head recess at maximum 2.4 mm head height")
    print("PASS: all five screws use M3 x 5 / Ø7 heads; three blind base pilots have 0.4 mm tip reserve; "
          "both Ø60 and Ø68 passive PCB references clear the enclosure and removal path")
    print("NOT VERIFIED: actual strip dimensions/bend rating, print fit, adhesion, "
          "solder/wires, actual D-bore depth/grip/travel, installed enclosure, thermal/electrical load, optical output")


if __name__ == "__main__":
    run()
