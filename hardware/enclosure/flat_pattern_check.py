"""Validate laser contours and compare final native flats with cut/deferred drills."""
from collections import Counter
import math

import cadquery as cq
import ezdxf
from ezdxf.math import Matrix44


AREA_TOLERANCE_MM2 = 0.01


def _face(entity):
    """Build exact planar curves, respecting DXF object-coordinate systems."""
    edges = []
    point = lambda p: cq.Vector(p.x, p.y, 0)
    curves = entity.virtual_entities() if entity.dxftype() == "LWPOLYLINE" else [entity]
    for curve in curves:
        data = curve.dxf
        if curve.dxftype() == "LINE":
            edges.append(cq.Edge.makeLine(point(data.start), point(data.end)))
        elif curve.dxftype() == "CIRCLE":
            edges.append(cq.Edge.makeCircle(data.radius, point(curve.ocs().to_wcs(data.center))))
        elif curve.dxftype() == "ARC":
            def at(angle):
                offset = (math.cos(math.radians(angle))*data.radius,
                          math.sin(math.radians(angle))*data.radius, 0)
                return point(curve.ocs().to_wcs(data.center + offset))
            mid = data.start_angle + ((data.end_angle-data.start_angle) % 360)/2
            edges.append(cq.Edge.makeThreePointArc(at(data.start_angle), at(mid), at(data.end_angle)))
        else:
            raise ValueError(f"Unsupported flat-pattern curve: {curve.dxftype()}")
    wire = cq.Wire.assembleEdges(edges)
    assert wire.IsClosed(), "flat-pattern contour is open"
    face = cq.Face.makeFromWires(wire)
    assert face.isValid(), "invalid flat-pattern contour"
    # OpenCascade can heal an out-and-back spur into a valid face, discarding
    # the doubled slit that remains in the laser file. Require the face boundary
    # to preserve all input cutting length as well as a valid material region.
    assert abs(sum(edge.Length() for edge in edges)-face.outerWire().Length()) <= 1e-6, (
        "flat-pattern contour contains retraced or healed cutting segments")
    return face


def _profile(document, layers):
    faces = [_face(e) for e in document.modelspace() if e.dxf.layer in layers]
    assert faces, "flat pattern has no cutting contours"
    faces.sort(key=lambda face: face.Area(), reverse=True)
    outer, holes = faces[0], faces[1:]
    # Material subtraction alone silently accepts duplicate holes, holes in
    # scrap and relief circles crossing the perimeter. Validate the actual
    # paths before building the remaining material.
    for hole in holes:
        assert hole.cut(outer).Area() <= 1e-8, (
            "flat-pattern contour lies outside the sheet or crosses its perimeter")
        assert hole.distance(outer.outerWire()) > 1e-6, (
            "flat-pattern contour touches the sheet perimeter")
    bounds = [hole.BoundingBox() for hole in holes]
    for i, hole in enumerate(holes):
        a = bounds[i]
        for other, b in zip(holes[i+1:], bounds[i+1:]):
            if (a.xmin > b.xmax+1e-6 or b.xmin > a.xmax+1e-6
                    or a.ymin > b.ymax+1e-6 or b.ymin > a.ymax+1e-6):
                continue
            assert hole.distance(other) > 1e-6, (
                "flat-pattern contours overlap or touch (duplicate/nested cut)")
    result = outer.cut(*holes) if holes else outer
    assert result.isValid() and len(result.Faces()) == 1, "flat pattern must be one connected sheet"
    return result


def validate_cut_contours(path):
    """Require clean millimetre laser paths; annotation and deferred drills stay out."""
    document = ezdxf.readfile(path)
    assert document.units == 4, "cutting units must be millimetres"
    _profile(document, ("CUT", "VENT"))


def _circles(document, layers):
    return [(e.dxf.radius, e.ocs().to_wcs(e.dxf.center))
            for e in document.modelspace().query("CIRCLE") if e.dxf.layer in layers]


def compare_flat_pattern(source_path, native_path, *, opposite_face=False):
    """Check all material, including holes drilled after forming.

    Fusion can rotate/translate its flat-pattern export. Register using matching
    round holes, then compare every contour by planar Boolean subtraction. DRILL
    is included only in this verification; it remains excluded from laser CUT.
    An opposite-face view must be prescribed by the verified export setup;
    mirrored candidates are never searched for automatically.
    """
    source = ezdxf.readfile(source_path)
    native = ezdxf.readfile(native_path)
    assert source.units == native.units == 4, "flat-pattern units must be millimetres"
    if opposite_face:
        for entity in native.modelspace():
            entity.transform(Matrix44.scale(-1, 1, 1))
    source_layers = ("CUT", "VENT", "DRILL")
    native_layers = ("OUTER_PROFILES", "INTERIOR_PROFILES")
    expected = _circles(source, source_layers)
    actual = _circles(native, native_layers)
    # Four proper in-plane rotations; a mirror is not an acceptable match.
    best = None
    for a, b, c, d in [(1, 0, 0, 1), (0, -1, 1, 0), (-1, 0, 0, -1), (0, 1, -1, 0)]:
        offsets = [(p.x-a*q.x-b*q.y, p.y-c*q.x-d*q.y)
                   for radius, p in expected for other, q in actual if abs(radius-other) < 1e-5]
        assert offsets, "no matching flat-pattern reference holes"
        # Keep native drilling precision residues out of the rigid registration:
        # averaging a displaced hole row with sound datums moves the whole sheet.
        delta, count = Counter((round(x, 6), round(y, 6)) for x, y in offsets).most_common(1)[0]
        if best is None or count > best[0]:
            matches = [(x, y) for x, y in offsets
                       if abs(x-delta[0]) < 1e-5 and abs(y-delta[1]) < 1e-5]
            dx = sum(x for x, _ in matches)/len(matches)
            dy = sum(y for _, y in matches)/len(matches)
            best = count, (a, b, c, d, dx, dy)
    count, (a, b, c, d, dx, dy) = best
    assert count >= 3, "insufficient flat-pattern registration holes"
    matrix = Matrix44((a, c, 0, 0, b, d, 0, 0, 0, 0, 1, 0, dx, dy, 0, 1))
    for entity in native.modelspace():
        entity.transform(matrix)
    wanted = _profile(source, source_layers)
    found = _profile(native, native_layers)
    missing = wanted.cut(found).Area()
    extra = found.cut(wanted).Area()
    assert missing <= AREA_TOLERANCE_MM2 and extra <= AREA_TOLERANCE_MM2, (
        f"flat-pattern mismatch: missing {missing:.6f} mm2, extra {extra:.6f} mm2")
    return {"matched_reference_holes": count, "missing_area_mm2": missing,
            "extra_area_mm2": extra, "area_tolerance_mm2": AREA_TOLERANCE_MM2}
