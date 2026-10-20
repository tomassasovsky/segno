"""Transfer-cut vinyl decals for the Segno console (#1090). Units mm, 1:1.

Two decals, both one colour (white cast vinyl on the black powder coat):

  logo   the segno glyph and wordmark on the lid, where the Fusion clone has
         them. The outlines are the TYPE's own curves (the brand glyph SVG,
         Apple Chancery for the wordmark), each part scaled and placed onto the
         matching segno_logo body measured in Fusion
         (reference/segno_logo_lid.json), and checked against it;
  rear   the connector names on the rear wall, one row above the connectors,
         and the protective-earth symbol over the earth stud.

Every outline is kept as curves (cubic Beziers) from the font to the files:
SVG and PDF carry curves, the DXF carries splines. Overlaps (the segno's
slash crosses its S) are resolved with skia-pathops so the cutter never cuts
inside a filled shape. Cut vinyl has to be weedable: every stroke and gap is
checked against MIN_FEATURE on a finely flattened copy.

Outputs (out/): per decal a .dxf (layer CUT), .svg and .pdf at 1:1; a cut
sheet with both decals for the vinyl shop (plus a compact PDF for email); and
a 1:1 placement template per decal (paper, red = holes and edges to align to).
Run with the enclosure venv: python hardware/decals/decals.py
"""

import json
import math
import sys
from pathlib import Path

import ezdxf
import ezdxf.path as dxpath
import pathops
from fontTools.pens.basePen import BasePen
from fontTools.pens.transformPen import TransformPen
from fontTools.svgLib.path import parse_path
from fontTools.ttLib import TTCollection, TTFont
from shapely.geometry import Polygon, box, Point
from shapely.ops import unary_union

HERE = Path(__file__).resolve().parent
OUT = HERE / "out"
REPO = HERE.parent.parent
sys.path.insert(0, str(HERE.parent / "enclosure"))
import segno_enclosure as se  # noqa: E402

# --- cut-vinyl limits ------------------------------------------------------
MIN_FEATURE = 0.6      # narrowest stroke and narrowest gap a plotter cuts and weeds
CORNER_LOSS = 0.25     # mm2 a sharp corner may lose to the erosion test without flagging
FLAT_STEP = 0.05       # mm of curve per segment when flattening for the checks

# --- logo --------------------------------------------------------------------
GLYPH_SVG = REPO / "tool" / "brand_assets" / "segno-glyph-black.svg"
WORD_FONT = "/System/Library/Fonts/Supplemental/Apple Chancery.ttf"
LOGO_PLACE = 0.10      # mm: each placed part's ink-box centre vs its Fusion body's
LOGO_SHAPE = 0.60      # mm: outline distance allowed. The type is the reference: Fusion's
                       # baked letters were fitted splines through sampled points and bulge
                       # up to 0.57 mm at two stroke ends (s, n); the glyph matches to 0.04
# Fusion body per logo part (reference/segno_logo_lid.json)
LOGO_PARTS = {"glyph": ("segno_glyph", "segno_glyph (1)", "segno_glyph (2)"),
              "s": ("segno_word (3)",), "e": ("segno_word (2)",), "g": ("segno_word (1)",),
              "n": ("segno_word",), "o": ("segno_word (4)",)}

# --- rear labels -----------------------------------------------------------
LABEL_FONT = ("/System/Library/Fonts/HelveticaNeue.ttc", "Helvetica Neue Bold")
CAP_H = 4.5            # cap height. Bold, not the tiles' Light (Light strokes would be
                       # ~0.3 mm); at 3.5 Bold's horizontals and at 4.0 the opening
                       # of the 5 fall under MIN_FEATURE
TRACKING = 0.06        # extra letter spacing, em, so letter gaps stay weedable
LABEL_BASE_Z = 63.0    # baseline above the floor TOP, one row for every label:
                       # the D-flange plates reach z 60.5 (31 tall about z 45)
LABEL_CLEAR = 2.0      # labels to flanges, holes, vents and each other
FLANGE = {             # visible flange envelope (w, h) about each station centre
    "PD_IN": (26.0, 31.0), "CTRL_1": (26.0, 31.0), "CTRL_2": (26.0, 31.0),
    "MIDI_IN": (28.6, 26.0), "MIDI_OUT": (28.6, 26.0),
    "POWER": (25.2, 25.2), "FUSE": (18.0, 18.0),
    "USB3_1": (28.5, 28.5), "USB3_2": (28.5, 28.5),
}
LABELS = {             # one line each; FUSE carries the fuse to fit (T5A slow-blow)
    "PD_IN": "USB-C PD IN", "POWER": "POWER", "FUSE": "FUSE T5A",
    "MIDI_IN": "MIDI IN", "MIDI_OUT": "MIDI OUT",
    "CTRL_1": "CTRL 1", "CTRL_2": "CTRL 2", "USB3_1": "USB", "USB3_2": "USB",
}
EARTH_R = 5.0          # protective-earth symbol (IEC 60417-5019) ring, outer radius
EARTH_W = 0.7          # ring and stem stroke
EARTH_BAR = 0.7        # bar thickness; bars 0.7 apart, the last bar 0.65 inside the ring


# --- path plumbing (pathops paths are the master geometry) -------------------

def _draw(fn, t=(1, 0, 0, 1, 0, 0)):
    """A pathops.Path from a draw(pen) callable, through an affine (xx, xy, yx, yy, dx, dy)."""
    p = pathops.Path()
    fn(TransformPen(p.getPen(), t))
    return p


def xform(p, t):
    return _draw(p.draw, t)


def move(p, dx, dy, s=1.0):
    return xform(p, (s, 0, 0, s, dx, dy))


def merge(paths):
    """Union by nonzero winding, overlaps removed, curves kept."""
    out = pathops.Path()
    for p in paths:
        p.draw(out.getPen())
    return pathops.simplify(out, fix_winding=True)


class _Ops(BasePen):
    """Records contours as M/L/C/Z (quadratics come in as cubics via BasePen)."""

    def __init__(self):
        super().__init__(None)
        self.ops = []

    def _moveTo(self, p):
        self.ops.append(("M", p))

    def _lineTo(self, p):
        self.ops.append(("L", p))

    def _curveToOne(self, a, b, c):
        self.ops.append(("C", a, b, c))

    def _closePath(self):
        self.ops.append(("Z",))

    _endPath = _closePath


def ops(p):
    pen = _Ops()
    p.draw(pen)
    return pen.ops


def flatten(p):
    """Shapely geometry of a path (curves sampled every FLAT_STEP mm)."""
    rings, cur, last = [], [], None
    for op in ops(p):
        if op[0] == "M":
            cur, last = [op[1]], op[1]
        elif op[0] == "L":
            cur.append(op[1]); last = op[1]
        elif op[0] == "C":
            (x0, y0), (x1, y1), (x2, y2), (x3, y3) = last, op[1], op[2], op[3]
            ln = math.dist(last, op[1]) + math.dist(op[1], op[2]) + math.dist(op[2], op[3])
            n = max(4, int(ln / FLAT_STEP))
            for i in range(1, n + 1):
                t = i / n
                a, b, c, d = (1-t)**3, 3*(1-t)**2*t, 3*(1-t)*t**2, t**3
                cur.append((a*x0+b*x1+c*x2+d*x3, a*y0+b*y1+c*y2+d*y3))
            last = op[3]
        elif op[0] == "Z":
            if len(cur) > 2:
                rings.append(cur)
            cur = []
    geom = None
    for r in rings:
        poly = Polygon(r).buffer(0)
        geom = poly if geom is None else geom.symmetric_difference(poly)
    return geom if geom is not None else Polygon()


def bounds(p):
    return flatten(p).bounds


# --- shapes --------------------------------------------------------------------

def _label_font():
    path, name = LABEL_FONT
    for f in TTCollection(path).fonts:
        if f["name"].getDebugName(4) == name:
            return f
    raise SystemExit(f"{name} not found in {path}: the labels must not fall back to another face")


def text_path(txt, font, cap_h=CAP_H):
    """Outlined text as curves, left end of the baseline at the origin; returns (path, width)."""
    gs, cmap, hmtx = font.getGlyphSet(), font.getBestCmap(), font["hmtx"]
    k = cap_h / font["OS/2"].sCapHeight
    track = TRACKING * font["head"].unitsPerEm
    parts, x = [], 0.0
    for ch in txt:
        g = cmap[ord(ch)]
        parts.append(_draw(gs[g].draw, (k, 0, 0, k, x * k, 0)))
        x += hmtx[g][0] + (track if ch != " " else 0)
    return merge(parts), (x - track) * k


def _circle(pen, r, cw=False):
    """A circle as four cubic arcs (kappa 0.5523), centred at the origin."""
    c = 0.5522847498 * r
    pts = [(r, 0), (0, r), (-r, 0), (0, -r)]
    if cw:
        pts = pts[::-1]
    pen.moveTo(pts[0])
    for i in range(4):
        a, b = pts[i], pts[(i + 1) % 4]
        ta = (-a[1], a[0]) if not cw else (a[1], -a[0])
        tb = (-b[1], b[0]) if not cw else (b[1], -b[0])
        pen.curveTo((a[0] + ta[0] / r * c, a[1] + ta[1] / r * c),
                    (b[0] - tb[0] / r * c, b[1] - tb[1] / r * c), b)
    pen.closePath()


def _rect(pen, x0, y0, x1, y1):
    pen.moveTo((x0, y0)); pen.lineTo((x1, y0)); pen.lineTo((x1, y1)); pen.lineTo((x0, y1)); pen.closePath()


def earth_path():
    """IEC 60417-5019 protective earth: earth sign inside a ring, centred at 0."""
    w, t = EARTH_W, EARTH_BAR

    def draw(pen):
        _circle(pen, EARTH_R)
        _circle(pen, EARTH_R - w, cw=True)
        _rect(pen, -w/2, -0.1, w/2, 2.6)
        _rect(pen, -2.2, -0.1 - t, 2.2, -0.1)
        _rect(pen, -1.4, -1.5 - t, 1.4, -1.5)
        _rect(pen, -0.6, -2.9 - t, 0.6, -2.9)
    return merge([_draw(draw)])


def _ref_parts():
    """Fusion's segno_logo bodies (lid u, v) as shapely, per logo part."""
    ref = json.loads((HERE / "reference" / "segno_logo_lid.json").read_text())
    out = {}
    for part, bodies in LOGO_PARTS.items():
        shapes = []
        for name in bodies:
            loops = ref["bodies"][name]
            outer = [l["pts"] for l in loops if l["outer"]]
            inner = [l["pts"] for l in loops if not l["outer"]]
            for o in outer:
                shapes.append(Polygon(o, [h for h in inner if Polygon(o).contains(Polygon(h))]).buffer(0))
        out[part] = unary_union(shapes)
    return out


def _fit(p, target, k=None):
    """Uniform scale k (default: from the heights) + move so p's ink box centre
    lands on target's."""
    x0, y0, x1, y1 = bounds(p)
    tx0, ty0, tx1, ty1 = target.bounds
    k = k or (ty1 - ty0) / (y1 - y0)
    return xform(p, (k, 0, 0, k, (tx0 + tx1) / 2 - k * (x0 + x1) / 2, (ty0 + ty1) / 2 - k * (y0 + y1) / 2))


def logo_parts():
    """{part: path} in lid coordinates (x = u to the player's right, y = v up the slope)."""
    import re
    ref = _ref_parts()
    svg = GLYPH_SVG.read_text()
    m = re.search(r'transform="matrix\(([^)]*)\)"\s+d="([^"]+)"', svg)
    a, b, c, d, e, f = map(float, m.group(1).split())
    glyph = _draw(lambda pen: parse_path(m.group(2), TransformPen(pen, (a, b, c, d, e, f))))
    glyph = xform(glyph, (1, 0, 0, -1, 0, 0))             # SVG y is down
    parts = {"glyph": _fit(merge([glyph]), ref["glyph"])}
    font = TTFont(WORD_FONT)
    gs, cmap = font.getGlyphSet(), font.getBestCmap()
    letters = {ch: merge([_draw(gs[cmap[ord(ch)]].draw)]) for ch in "segno"}
    # one scale for the whole word (the font's own proportions): the median of
    # the letters' width and height ratios to their Fusion bodies
    ratios = []
    for ch, p in letters.items():
        x0, y0, x1, y1 = bounds(p)
        tx0, ty0, tx1, ty1 = ref[ch].bounds
        ratios += [(tx1 - tx0) / (x1 - x0), (ty1 - ty0) / (y1 - y0)]
    k = sorted(ratios)[len(ratios) // 2]
    for ch, p in letters.items():
        parts[ch] = _fit(p, ref[ch], k)
    return parts


def logo_match():
    """{part: (ink-box centre offset, outline distance)} in mm, placed type vs
    Fusion body. Box centres, not centroids: a bulge in a Fusion letter moves
    its centroid without the letter being anywhere else."""
    ref = _ref_parts()
    out = {}
    for k, p in logo_parts().items():
        g = flatten(p)
        shape = max(g.boundary.hausdorff_distance(ref[k].boundary),
                    ref[k].boundary.hausdorff_distance(g.boundary))
        a, b = g.bounds, ref[k].bounds
        out[k] = (math.hypot((a[0] + a[2] - b[0] - b[2]) / 2, (a[1] + a[3] - b[1] - b[3]) / 2), shape)
    return out


def logo_path():
    return merge(list(logo_parts().values()))


def logo_decal():
    """The logo as shapely (for checks and placement tests)."""
    return flatten(logo_path())


U_REF = None


def _wall(u):
    """Rear-wall u -> x in the outside view (u runs right to left from behind)."""
    return -(u - U_REF)


def rear_pieces():
    """{ref: (station u, path at the origin's u)}: labels at their row height."""
    font = _label_font()
    lay = se.rear_io_layout()
    stud = next(c for c in se.rear_holes() if c["ref"] == "EARTH_STUD")
    pieces = {}
    for ref, txt in LABELS.items():
        p, w = text_path(txt, font)
        pieces[ref] = (lay[ref][0], move(p, -w / 2.0, LABEL_BASE_Z))
    pieces["EARTH_STUD"] = (stud["u"], move(earth_path(), 0, LABEL_BASE_Z + CAP_H / 2.0))
    return pieces


def rear_decal():
    """{ref: (station u, shapely)} -- the shapely view the checks and tests use."""
    _set_uref()
    return {r: (cu, flatten(p)) for r, (cu, p) in rear_pieces().items()}


def rear_path():
    _set_uref()
    return merge([move(p, _wall(cu), 0) for cu, p in rear_pieces().values()])


def _set_uref():
    global U_REF
    lay = se.rear_io_layout()
    U_REF = (min(lay[r][0] for r in LABELS) + max(lay[r][0] for r in LABELS)) / 2.0


# --- checks ------------------------------------------------------------------------

def check_cuttable(name, geom):
    """Every stroke and gap at least MIN_FEATURE: erode/dilate by half of it and
    look for anything bigger than a corner that disappears or fills in."""
    r = MIN_FEATURE / 2.0
    opened = geom.buffer(-r, join_style=2).buffer(r, join_style=2)
    thin = geom.difference(opened.buffer(1e-3))
    closed = geom.buffer(r, join_style=2).buffer(-r, join_style=2)
    narrow = closed.difference(geom.buffer(1e-3))
    bad = []
    for label, g in (("stroke", thin), ("gap", narrow)):
        pieces = getattr(g, "geoms", [g])
        big = [p for p in pieces if p.area > CORNER_LOSS]
        if big:
            worst = max(big, key=lambda p: p.area)
            c = worst.centroid
            bad.append(f"{name}: {label} under {MIN_FEATURE} mm near ({c.x:.1f}, {c.y:.1f}), {worst.area:.2f} mm2")
    return bad


def lid_cut_shape(c):
    """One lid opening as the laser cuts it (segno_enclosure.faceplate_metal_cuts):
    rectangles with their corner radius, so the pill slots are stadiums."""
    if c["kind"] == "rect":
        r = min(c.get("r", 0.0) or 0.0, c["w"] / 2.0, c["h"] / 2.0)
        if r <= 0:
            return box(c["u"], c["v"], c["u"] + c["w"], c["v"] + c["h"])
        return box(c["u"] + r, c["v"] + r, c["u"] + c["w"] - r, c["v"] + c["h"] - r).buffer(r, quad_segs=32)
    d = c.get("od") or c.get("d")
    return Point(c["u"], c["v"]).buffer(d / 2.0, quad_segs=64)


def rear_obstacles():
    """Holes, vents and connector flanges, outside view, grown by LABEL_CLEAR."""
    _set_uref()
    obs = []
    for c in se.rear_holes():
        if c["kind"] == "circle":
            obs.append(Point(_wall(c["u"]), c["v"]).buffer(c["d"] / 2.0))
        else:
            x0, x1 = sorted((_wall(c["u"]), _wall(c["u"] + c["w"])))
            obs.append(box(x0, c["v"], x1, c["v"] + c["h"]))
    lay = se.rear_io_layout()
    io_z = {c["ref"]: c["v"] + (c.get("h", 0) / 2.0 if c["kind"] == "rect" else 0)
            for c in se.rear_holes() if c["ref"] in lay}
    for ref, (w, h) in FLANGE.items():
        x = _wall(lay[ref][0])
        obs.append(box(x - w / 2.0, io_z[ref] - h / 2.0, x + w / 2.0, io_z[ref] + h / 2.0))
    return unary_union(obs).buffer(LABEL_CLEAR)


def check_rear(pieces):
    from shapely import affinity
    errs = []
    obstacles = rear_obstacles()
    placed = {ref: affinity.translate(g, _wall(cu), 0) for ref, (cu, g) in pieces.items()}
    for ref, g in placed.items():
        if g.intersects(obstacles):
            errs.append(f"rear: {ref} label overlaps a hole, vent or flange (+{LABEL_CLEAR} mm)")
        if g.bounds[3] > se.REAR_WALL_H - 5.0:
            errs.append(f"rear: {ref} label runs into the top fold")
    refs = sorted(placed, key=lambda r: placed[r].bounds[0])
    for a, b in zip(refs, refs[1:]):
        if placed[a].distance(placed[b]) < LABEL_CLEAR:
            errs.append(f"rear: {a} and {b} labels closer than {LABEL_CLEAR} mm")
    return errs


# --- writers (curves end to end) ---------------------------------------------------------

def _guide_rings(g):
    for p in getattr(g, "geoms", [g]):
        if hasattr(p, "exterior"):
            yield list(p.exterior.coords)
            for i in p.interiors:
                yield list(i.coords)
        else:
            yield list(p.coords)


def write_dxf(path, p, guides=()):
    doc = ezdxf.new("R2010")
    doc.units = 4
    doc.layers.add("CUT", color=7)
    doc.layers.add("GUIA", color=1)
    msp = doc.modelspace()
    paths, cur = [], None
    for op in ops(p):
        if op[0] == "M":
            cur = dxpath.Path(op[1])
        elif op[0] == "L":
            cur.line_to(op[1])
        elif op[0] == "C":
            cur.curve4_to(op[3], op[1], op[2])
        else:
            cur.close()
            paths.append(cur)
    dxpath.render_splines_and_polylines(msp, paths, dxfattribs={"layer": "CUT"})
    for g in guides:
        for ring in _guide_rings(g):
            msp.add_lwpolyline(ring, dxfattribs={"layer": "GUIA"})
    doc.saveas(path)


def _frame(p, guides, margin, extra_bottom=0.0, extra_top=0.0):
    x0, y0, x1, y1 = bounds(p)
    for g in guides:
        gx0, gy0, gx1, gy1 = g.bounds
        x0, y0, x1, y1 = min(x0, gx0), min(y0, gy0), max(x1, gx1), max(y1, gy1)
    return x0 - margin, y0 - margin - extra_bottom, x1 + margin, y1 + margin + extra_top


def write_svg(path, p, guides=(), margin=5.0):
    x0, y0, x1, y1 = _frame(p, guides, margin)
    W, H = x1 - x0, y1 - y0
    fx = lambda q: f"{q[0] - x0:.3f},{y1 - q[1]:.3f}"
    d = []
    for op in ops(p):
        d.append({"M": lambda o: "M" + fx(o[1]), "L": lambda o: "L" + fx(o[1]),
                  "C": lambda o: "C" + " ".join(fx(q) for q in o[1:]), "Z": lambda o: "Z"}[op[0]](op))
    body = [f'<path d="{" ".join(d)}" fill="#000" fill-rule="nonzero" stroke="none"/>']
    for g in guides:
        for ring in _guide_rings(g):
            body.append('<polyline points="' + " ".join(fx(q) for q in ring) +
                        '" fill="none" stroke="#e11" stroke-width="0.2" stroke-dasharray="1.5,1"/>')
    Path(path).write_text(
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{W:.3f}mm" height="{H:.3f}mm" '
        f'viewBox="0 0 {W:.3f} {H:.3f}">\n' + "\n".join(body) + "\n</svg>\n")


def write_pdf(path, p, guides=(), title="", margin=8.0, notes=()):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.patches import PathPatch
    from matplotlib.path import Path as MPath
    x0, y0, x1, y1 = _frame(p, guides, margin, 14.0, 8.0)
    W, H = x1 - x0, y1 - y0
    fig = plt.figure(figsize=(W / 25.4, H / 25.4))
    ax = fig.add_axes([0, 0, 1, 1])
    ax.set_xlim(x0, x1); ax.set_ylim(y0, y1); ax.set_aspect("equal"); ax.axis("off")
    verts, codes = [], []
    for op in ops(p):
        if op[0] == "M":
            verts.append(op[1]); codes.append(MPath.MOVETO)
        elif op[0] == "L":
            verts.append(op[1]); codes.append(MPath.LINETO)
        elif op[0] == "C":
            verts += [op[1], op[2], op[3]]; codes += [MPath.CURVE4] * 3
        else:
            verts.append((0, 0)); codes.append(MPath.CLOSEPOLY)
    ax.add_patch(PathPatch(MPath(verts, codes), facecolor="black", edgecolor="none"))
    for g in guides:
        for ring in _guide_rings(g):
            xs, ys = zip(*ring)
            ax.plot(xs, ys, color="#d11", linewidth=0.4, linestyle=(0, (3, 2)))
    ax.plot([x0 + 5, x0 + 105], [y0 + 5, y0 + 5], color="black", linewidth=0.8)
    ax.text(x0 + 5, y0 + 7, "100 mm: medir después de imprimir (escala 1:1)", fontsize=6)
    ax.text(x0 + 5, y1 - 5, title, fontsize=7, va="top")
    for i, t in enumerate(notes):
        ax.text(x0 + 5, y1 - 9 - 3.2 * i, t, fontsize=5.5, va="top")
    fig.savefig(path)
    plt.close(fig)


def write_pdf_compact(path, p, title):
    """The cut paths alone as a minimal PDF with true curves (nonzero fill,
    coordinates to 0.01 pt, base-14 Helvetica, nothing embedded): small enough
    to attach to an email."""
    import zlib
    K = 72 / 25.4
    x0, y0, x1, y1 = bounds(p)
    x0, y0, x1, y1 = x0 - 10, y0 - 22, x1 + 10, y1 + 16
    W, H = (x1 - x0) * K, (y1 - y0) * K
    f = lambda q: "%.2f %.2f" % ((q[0] - x0) * K, (q[1] - y0) * K)
    seg = []
    for op in ops(p):
        seg.append({"M": lambda o: f(o[1]) + " m", "L": lambda o: f(o[1]) + " l",
                    "C": lambda o: " ".join(f(q) for q in o[1:]) + " c", "Z": lambda o: "h"}[op[0]](op))
    bx = by = 5 * K
    body = ("0 g\n" + "\n".join(seg) + "\nf\n"
            + "0 G 0.8 w %.1f %.1f m %.1f %.1f l S\n" % (bx, by, bx + 100 * K, by)
            + "BT /F1 7 Tf %.1f %.1f Td (100 mm - escala 1:1) Tj ET\n" % (bx, by + 2 * K)
            + "BT /F1 8 Tf %.1f %.1f Td (%s) Tj ET\n" % (bx, H - 6 * K, title))
    data = zlib.compress(body.encode("latin-1"), 9)
    objs = ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 %.1f %.1f] /Contents 4 0 R "
            "/Resources << /Font << /F1 5 0 R >> >> >>" % (W, H),
            None, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"]
    out, offs = b"%PDF-1.4\n", []
    for i, o in enumerate(objs, 1):
        offs.append(len(out))
        if o is None:
            out += (b"%d 0 obj\n<< /Length %d /Filter /FlateDecode >>\nstream\n" % (i, len(data))
                    + data + b"\nendstream\nendobj\n")
        else:
            out += ("%d 0 obj\n%s\nendobj\n" % (i, o)).encode()
    xref = len(out)
    out += ("xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1)).encode()
    out += b"".join(b"%010d 00000 n \n" % o for o in offs)
    out += ("trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objs) + 1, xref)).encode()
    Path(path).write_bytes(out)


def main():
    OUT.mkdir(exist_ok=True)
    errs = []
    # --- logo: the type's curves, placed on Fusion's bodies
    match = logo_match()
    for k, (place, shape) in match.items():
        if place > LOGO_PLACE:
            errs.append(f"logo: '{k}' is placed {place:.2f} mm off the Fusion body (limit {LOGO_PLACE})")
        if shape > LOGO_SHAPE:
            errs.append(f"logo: '{k}' outline is {shape:.2f} mm off the Fusion body (limit {LOGO_SHAPE})")
    logo = logo_path()
    errs += check_cuttable("logo", flatten(logo))
    lid_guides = []
    for c in se.faceplate_metal_cuts():
        if c["ref"] in ("CLEAR_LEDSLOT", "BANK_LEDSLOT"):
            lid_guides.append(lid_cut_shape(c).exterior)
        elif c["ref"] in ("CLEAR", "BANK"):
            # only the real edges of the opening's top 15 mm, not a closed box
            clip = box(c["u"] - 1, c["v"] + c["h"] - 15.0, c["u"] + c["w"] + 1, c["v"] + c["h"] + 1)
            lid_guides.append(lid_cut_shape(c).exterior.intersection(clip))
    # --- rear labels
    _set_uref()
    errs += check_rear(rear_decal())
    rear = rear_path()
    errs += check_cuttable("rear", flatten(rear))
    rear_guides = []
    for c in se.rear_holes():
        if c["ref"] == "VENT":
            continue
        if c["kind"] == "circle":
            rear_guides.append(Point(_wall(c["u"]), c["v"]).buffer(c["d"] / 2.0, quad_segs=32).exterior)
        else:
            x0, x1 = sorted((_wall(c["u"]), _wall(c["u"] + c["w"])))
            rear_guides.append(box(x0, c["v"], x1, c["v"] + c["h"]).exterior)
    if errs:
        raise SystemExit("decal checks failed:\n  " + "\n  ".join(errs))

    vinyl = ("Vinilo de corte BLANCO MATE (cast, p. ej. Oracal 851/951), una sola tinta, sobre pintura negra RAL 9005. "
             "Cortar CUT a escala 1:1, pelar el sobrante y aplicar con film de transferencia transparente.")
    write_dxf(OUT / "segno_decal_logo.dxf", logo)
    write_svg(OUT / "segno_decal_logo.svg", logo)
    write_pdf(OUT / "segno_decal_logo.pdf", logo, title="segno_decal_logo: logo de la tapa, 1:1", notes=[vinyl])
    write_dxf(OUT / "segno_decal_rear.dxf", rear)
    write_svg(OUT / "segno_decal_rear.svg", rear)
    write_pdf(OUT / "segno_decal_rear.pdf", rear, title="segno_decal_rear: rótulos de la pared trasera (vista desde atrás), 1:1", notes=[vinyl])
    write_pdf(OUT / "segno_decal_logo_placement.pdf", logo, guides=lid_guides,
              title="Plantilla de ubicación del logo (imprimir en papel a 1:1)",
              notes=["Rojo punteado = aberturas de la tapa: las luces de CLEAR y BANK y el borde superior de sus pedales. "
                     "Alinear la plantilla con esas aberturas, marcar y aplicar el vinilo encima."])
    write_pdf(OUT / "segno_decal_rear_placement.pdf", rear, guides=rear_guides,
              title="Plantilla de ubicación de los rótulos traseros (imprimir en papel a 1:1)",
              notes=["Rojo punteado = agujeros de la pared trasera vistos desde AFUERA. "
                     "Los conectores se pueden montar antes: los rótulos van por encima de sus bridas."])
    lx0, ly0, lx1, ly1 = bounds(logo)
    rx0, ry0, rx1, ry1 = bounds(rear)
    sheet = merge([move(logo, -lx0, ry1 - ry0 + 15.0 - ly0), move(rear, -rx0, -ry0)])
    write_dxf(OUT / "segno_decals_cut_sheet.dxf", sheet)
    write_svg(OUT / "segno_decals_cut_sheet.svg", sheet)
    write_pdf(OUT / "segno_decals_cut_sheet.pdf", sheet,
              title="Segno: hoja de corte de calcomanías (logo + rótulos traseros), 1:1", notes=[vinyl])
    write_pdf_compact(OUT / "segno_decals_cut_sheet_compact.pdf", sheet,
                      "Segno - calcos en vinilo de corte blanco mate, escala 1:1")
    print(f"logo {lx1 - lx0:.1f} x {ly1 - ly0:.1f} mm at lid u {lx0:.1f}..{lx1:.1f}, v {ly0:.1f}..{ly1:.1f}")
    print("logo vs Fusion, box centre / outline mm: " + ", ".join(f"{k} {a:.3f}/{b:.2f}" for k, (a, b) in match.items()))
    print(f"rear strip {rx1 - rx0:.1f} x {ry1 - ry0:.1f} mm, baseline z {LABEL_BASE_Z}")
    return {"logo": (lx0, ly0, lx1, ly1), "rear": (rx0, ry0, rx1, ry1)}


if __name__ == "__main__":
    main()
