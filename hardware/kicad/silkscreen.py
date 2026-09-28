"""Keep existing footprint legend strokes clear of soldermask openings.

KiCad's library strokes are often 0.12 mm wide. Widen them to the fabrication
minimum, then clip straight stroke centerlines against the pad opening plus
half the stroke and a 0.16 mm gap. This preserves constant stroke width and
round end caps; it does not modify pads, copper, component positions or text.
"""
import math
import pcbnew as p

MIN_STROKE = p.FromMM(.15)
MASK_GAP = p.FromMM(.16)


def _cross(a, b):
    return a[0] * b[1] - a[1] * b[0]


def _outside(start, end, polygon):
    """Safe intervals of a line outside an inflated native pad polygon."""
    dx, dy = end.x - start.x, end.y - start.y
    cuts = [0.0, 1.0]
    for i in range(polygon.OutlineCount()):
        ring = polygon.COutline(i)
        for j in range(ring.PointCount()):
            a, b = ring.CPoint(j), ring.CPoint((j + 1) % ring.PointCount())
            edge = (b.x - a.x, b.y - a.y)
            denom = _cross((dx, dy), edge)
            if abs(denom) < 1:
                continue
            delta = (a.x - start.x, a.y - start.y)
            t = _cross(delta, edge) / denom
            u = _cross(delta, (dx, dy)) / denom
            if 0 < t < 1 and 0 <= u <= 1:
                cuts.append(t)
    cuts = sorted(set(cuts))
    return [(a, b) for a, b in zip(cuts, cuts[1:])
            if not polygon.Contains(p.VECTOR2I(round(start.x + dx * (a + b) / 2),
                                              round(start.y + dy * (a + b) / 2)))]


def finish_footprint(fp):
    """Normalize the existing outline; retain text and all non-silk geometry."""
    changes = 0
    for graphic in list(fp.GraphicalItems()):
        if graphic.GetClass() != "PCB_SHAPE" or graphic.GetLayer() not in (p.F_SilkS, p.B_SilkS):
            continue
        if 0 < graphic.GetWidth() < MIN_STROKE:
            graphic.SetWidth(MIN_STROKE)
        if graphic.GetShape() != p.SHAPE_T_SEGMENT:
            continue
        start, end = p.VECTOR2I(graphic.GetStart()), p.VECTOR2I(graphic.GetEnd())
        dx, dy = end.x - start.x, end.y - start.y
        if dx == dy == 0:
            continue
        copper = p.F_Cu if graphic.GetLayer() == p.F_SilkS else p.B_Cu
        mask = p.F_Mask if copper == p.F_Cu else p.B_Mask
        intervals = [(0.0, 1.0)]
        for pad in fp.Pads():
            if not pad.IsOnLayer(mask):
                continue
            polygon = p.SHAPE_POLY_SET()
            clearance = pad.GetSolderMaskExpansion(copper) + MASK_GAP + (graphic.GetWidth() + 1) // 2
            pad.TransformShapeToPolygon(polygon, copper, clearance, 1000, p.ERROR_OUTSIDE)
            safe = _outside(start, end, polygon)
            intervals = [(max(a, c), min(b, d)) for a, b in intervals for c, d in safe
                         if min(b, d) > max(a, c)]
        if intervals == [(0.0, 1.0)]:
            continue
        # Do not leave a decorative fragment shorter than its printed width.
        intervals = [(a, b) for a, b in intervals
                     if (b - a) * math.hypot(dx, dy) >= graphic.GetWidth()]
        for i, (a, b) in enumerate(intervals):
            item = graphic if i == 0 else p.PCB_SHAPE(fp, p.SHAPE_T_SEGMENT)
            if i:
                item.SetLayer(graphic.GetLayer())
                item.SetWidth(graphic.GetWidth())
            item.SetStart(p.VECTOR2I(round(start.x + a * dx), round(start.y + a * dy)))
            item.SetEnd(p.VECTOR2I(round(start.x + b * dx), round(start.y + b * dy)))
            if i:
                fp.Add(item)
        if not intervals:
            fp.RemoveNative(graphic)
        changes += 1
    return changes


def mask_clearance_problems(board):
    """Check actual ink against pad mask openings independently of CLI DRC."""
    problems = []
    masks = {p.F_SilkS: [], p.B_SilkS: []}
    items = [("board", item) for item in board.GetDrawings()]
    for footprint in board.GetFootprints():
        items.extend((footprint.GetReference(), item) for item in
                     [*footprint.GetFields(), *footprint.GraphicalItems()])
        for pad in footprint.Pads():
            for copper, mask, silk in ((p.F_Cu, p.F_Mask, p.F_SilkS),
                                       (p.B_Cu, p.B_Mask, p.B_SilkS)):
                if not pad.IsOnLayer(mask):
                    continue
                opening = p.SHAPE_POLY_SET()
                # Resolve pad/footprint/board mask expansion. Outward polygons
                # use a 0.1 um error bound; they do not forgive a short gap.
                pad.TransformShapeToPolygon(opening, copper, pad.GetSolderMaskExpansion(copper),
                                            100, p.ERROR_OUTSIDE)
                masks[silk].append((f"{footprint.GetReference()}.{pad.GetNumber()}",
                                    opening, opening.BBox()))
    for owner, item in items:
        layer = item.GetLayer()
        if layer not in masks:
            continue
        ink = p.SHAPE_POLY_SET()
        if isinstance(item, (p.PCB_TEXT, p.PCB_FIELD)):
            if not item.IsVisible() or not item.GetShownText(False).strip():
                continue
            item.TransformTextToPolySet(ink, 0, 100, p.ERROR_OUTSIDE)
        elif isinstance(item, p.PCB_SHAPE):
            item.TransformShapeToPolygon(ink, layer, 0, 100, p.ERROR_OUTSIDE)
        else:
            continue
        box = ink.BBox()
        box.Inflate(p.FromMM(.15))
        for terminal, opening, opening_box in masks[layer]:
            if box.Intersects(opening_box) and ink.Collide(opening, p.FromMM(.15)):
                problems.append(f"{owner}: silkscreen is within 0.15 mm of {terminal}'s mask opening")

    return problems
