"""Transfer-cut vinyl decals for the Segno console (#1090). Units mm, 1:1.

Two decals, both one colour (white cast vinyl on the black powder coat):

  logo   the segno glyph and wordmark on the lid, exactly as placed in the
         Fusion clone (reference/segno_logo_lid.json, extracted from the
         segno_logo bodies' top faces);
  rear   the connector names on the rear wall, one row above the connectors,
         and the protective-earth symbol over the earth stud.

Cut vinyl has to be weedable: every stroke and every gap is checked against
MIN_FEATURE. Rear-wall positions come from segno_enclosure.rear_io_layout(),
so the labels follow the connectors if they move.

Outputs (out/): per decal a .dxf (layer CUT = cut paths), .svg and .pdf at
1:1; a cut sheet with both decals for the vinyl shop; and a 1:1 placement
template per decal (paper, layer GUIA = the holes and edges to align to).
Run with the enclosure venv: python hardware/decals/decals.py
"""

import json
import math
import os
import sys
from pathlib import Path

import ezdxf
from fontTools.pens.basePen import BasePen
from fontTools.ttLib import TTCollection
from shapely.geometry import Polygon, box, Point
from shapely.ops import unary_union
from shapely import affinity

HERE = Path(__file__).resolve().parent
OUT = HERE / "out"
sys.path.insert(0, str(HERE.parent / "enclosure"))
import segno_enclosure as se  # noqa: E402

# --- cut-vinyl limits ------------------------------------------------------
MIN_FEATURE = 0.6      # narrowest stroke and narrowest gap a plotter cuts and weeds
CORNER_LOSS = 0.25     # mm2 a sharp corner may lose to the erosion test without flagging

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
EARTH_BAR = 0.6        # bar thickness; bars 0.8 apart


class _FlatPen(BasePen):
    """Collects glyph contours as flattened point lists."""

    def __init__(self, glyphset, steps=12):
        super().__init__(glyphset)
        self.contours, self._cur, self.steps = [], [], steps

    def _moveTo(self, p):
        self._cur = [p]

    def _lineTo(self, p):
        self._cur.append(p)

    def _curveToOne(self, p1, p2, p3):
        p0 = self._cur[-1]
        for i in range(1, self.steps + 1):
            t = i / self.steps
            a, b, c_, d = (1-t)**3, 3*(1-t)**2*t, 3*(1-t)*t**2, t**3
            self._cur.append((a*p0[0]+b*p1[0]+c_*p2[0]+d*p3[0], a*p0[1]+b*p1[1]+c_*p2[1]+d*p3[1]))

    def _qCurveToOne(self, p1, p2):
        p0 = self._cur[-1]
        for i in range(1, self.steps + 1):
            t = i / self.steps
            self._cur.append(((1-t)**2*p0[0]+2*(1-t)*t*p1[0]+t*t*p2[0], (1-t)**2*p0[1]+2*(1-t)*t*p1[1]+t*t*p2[1]))

    def _closePath(self):
        if len(self._cur) > 2:
            self.contours.append(self._cur)
        self._cur = []

    _endPath = _closePath


def _font():
    path, name = LABEL_FONT
    for f in TTCollection(path).fonts:
        if f["name"].getDebugName(4) == name:
            return f
    raise SystemExit(f"{name} not found in {path}: the labels must not fall back to another face")


def text_geometry(txt, font, cap_h=CAP_H):
    """Outlined text, left end of the baseline at the origin, in mm."""
    gs, cmap, hmtx = font.getGlyphSet(), font.getBestCmap(), font["hmtx"]
    scale = cap_h / font["OS/2"].sCapHeight
    track = TRACKING * font["head"].unitsPerEm
    parts, x = [], 0.0
    for ch in txt:
        g = cmap[ord(ch)]
        pen = _FlatPen(gs)
        gs[g].draw(pen)
        shape = None
        for cont in pen.contours:
            poly = Polygon([(x + px, py) for px, py in cont]).buffer(0)
            shape = poly if shape is None else shape.symmetric_difference(poly)
        if shape is not None and not shape.is_empty:
            parts.append(shape)
        x += hmtx[g][0] + (track if ch != " " else 0)
    geom = unary_union(parts)
    return affinity.scale(geom, scale, scale, origin=(0, 0)), (x - track) * scale


def earth_symbol():
    """IEC 60417-5019 protective earth: earth sign inside a ring, centred at 0."""
    w = EARTH_W
    ring = Point(0, 0).buffer(EARTH_R).difference(Point(0, 0).buffer(EARTH_R - w))
    t = EARTH_BAR
    stem = box(-w/2, -0.1, w/2, 2.6)
    bars = [box(-2.2, -0.1 - t, 2.2, -0.1), box(-1.4, -1.5 - t, 1.4, -1.5), box(-0.6, -2.9 - t, 0.6, -2.9)]
    return unary_union([ring, stem] + bars)


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


# --- the two decals -----------------------------------------------------------

def logo_decal():
    """The logo in lid coordinates (u, v): x = u to the player's right, y = v up
    the slope -- the decal as it reads from the playing position."""
    ref = json.loads((HERE / "reference" / "segno_logo_lid.json").read_text())
    shapes = []
    for loops in ref["bodies"].values():
        outer = [l["pts"] for l in loops if l["outer"]]
        inner = [l["pts"] for l in loops if not l["outer"]]
        for o in outer:
            shapes.append(Polygon(o, [h for h in inner if Polygon(o).contains(Polygon(h))]).buffer(0))
    return unary_union(shapes)


def rear_decal():
    """Labels in rear-wall coordinates SEEN FROM BEHIND: x = -(u - U_REF), so
    the decal reads left to right from the outside; y = height above the floor
    TOP (the frame segno_enclosure uses for the rear cutouts)."""
    font = _font()
    lay = se.rear_io_layout()
    stud = next(c for c in se.rear_holes() if c["ref"] == "EARTH_STUD")
    pieces, boxes = {}, {}
    for ref, txt in LABELS.items():
        cu = lay[ref][0]
        g, w = text_geometry(txt, font)
        g = affinity.translate(g, -w / 2.0, LABEL_BASE_Z)
        pieces[ref] = (cu, g)
    earth = affinity.translate(earth_symbol(), 0, LABEL_BASE_Z + CAP_H / 2.0)
    pieces["EARTH_STUD"] = (stud["u"], earth)
    return pieces


def _wall(u):
    return -(u - U_REF)


U_REF = None


def place_rear(pieces):
    """Mirror each piece into the outside view and union them."""
    out = []
    for ref, (cu, g) in pieces.items():
        out.append(affinity.translate(g, _wall(cu), 0))
    return unary_union(out)


def rear_obstacles():
    """Holes, vents and connector flanges, outside view, grown by LABEL_CLEAR."""
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


# --- writers ------------------------------------------------------------------

def _rings(geom):
    for p in getattr(geom, "geoms", [geom]):
        yield list(p.exterior.coords)
        for i in p.interiors:
            yield list(i.coords)


def write_dxf(path, geom, guides=()):
    doc = ezdxf.new("R2010")
    doc.units = 4
    doc.layers.add("CUT", color=7)
    doc.layers.add("GUIA", color=1, linetype="DASHED")
    msp = doc.modelspace()
    for ring in _rings(geom):
        msp.add_lwpolyline(ring, close=True, dxfattribs={"layer": "CUT"})
    for g in guides:
        for ring in _rings(g):
            msp.add_lwpolyline(ring, close=True, dxfattribs={"layer": "GUIA"})
    doc.saveas(path)


def write_svg(path, geom, guides=(), margin=5.0):
    allg = unary_union([geom] + list(guides))
    x0, y0, x1, y1 = allg.bounds
    x0, y0, x1, y1 = x0 - margin, y0 - margin, x1 + margin, y1 + margin
    W, H = x1 - x0, y1 - y0

    def d(g):
        s = []
        for ring in _rings(g):
            s.append("M" + " L".join(f"{x - x0:.3f},{y1 - y:.3f}" for x, y in ring) + " Z")
        return " ".join(s)
    body = [f'<path d="{d(geom)}" fill="#000" fill-rule="evenodd" stroke="none"/>']
    for g in guides:
        body.append(f'<path d="{d(g)}" fill="none" stroke="#e11" stroke-width="0.2" stroke-dasharray="1.5,1"/>')
    Path(path).write_text(
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{W:.3f}mm" height="{H:.3f}mm" '
        f'viewBox="0 0 {W:.3f} {H:.3f}">\n' + "\n".join(body) + "\n</svg>\n")


def write_pdf(path, geom, guides=(), title="", margin=8.0, notes=()):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.patches import PathPatch
    from matplotlib.path import Path as MPath
    allg = unary_union([geom] + list(guides))
    x0, y0, x1, y1 = allg.bounds
    x0, y0, x1, y1 = x0 - margin, y0 - margin - 14.0, x1 + margin, y1 + margin + 8.0
    W, H = x1 - x0, y1 - y0
    fig = plt.figure(figsize=(W / 25.4, H / 25.4))
    ax = fig.add_axes([0, 0, 1, 1])
    ax.set_xlim(x0, x1); ax.set_ylim(y0, y1); ax.set_aspect("equal"); ax.axis("off")

    def patch(g, **kw):
        verts, codes = [], []
        for ring in _rings(g):
            verts += ring
            codes += [MPath.MOVETO] + [MPath.LINETO] * (len(ring) - 2) + [MPath.CLOSEPOLY]
        ax.add_patch(PathPatch(MPath(verts, codes), **kw))
    patch(geom, facecolor="black", edgecolor="none")
    for g in guides:
        patch(g, facecolor="none", edgecolor="#d11", linewidth=0.4, linestyle=(0, (3, 2)))
    # 100 mm scale bar: measure it after printing
    ax.plot([x0 + 5, x0 + 105], [y0 + 5, y0 + 5], color="black", linewidth=0.8)
    ax.text(x0 + 5, y0 + 7, "100 mm: medir después de imprimir (escala 1:1)", fontsize=6)
    ax.text(x0 + 5, y1 - 5, title, fontsize=7, va="top")
    for i, t in enumerate(notes):
        ax.text(x0 + 5, y1 - 9 - 3.2 * i, t, fontsize=5.5, va="top")
    fig.savefig(path)
    plt.close(fig)


def main():
    global U_REF
    OUT.mkdir(exist_ok=True)
    errs = []
    # --- logo
    logo = logo_decal()
    errs += check_cuttable("logo", logo)
    # The guides are the openings right under the logo, so the template fits a
    # sheet of A4: both pill slots and the top 15 mm of the CLEAR/BANK openings.
    lid_guides = []
    for c in se.faceplate_holes():
        if c["kind"] == "rect" and c["ref"] in ("CLEAR", "BANK", "CLEAR_LEDSLOT", "BANK_LEDSLOT"):
            v0 = c["v"] if c["ref"].endswith("LEDSLOT") else c["v"] + c["h"] - 15.0
            lid_guides.append(box(c["u"], v0, c["u"] + c["w"], c["v"] + c["h"]).exterior.buffer(0.01))
    # --- rear labels
    lay = se.rear_io_layout()
    U_REF = (min(lay[r][0] for r in LABELS) + max(lay[r][0] for r in LABELS)) / 2.0
    pieces = rear_decal()
    errs += check_rear(pieces)
    rear = place_rear(pieces)
    errs += check_cuttable("rear", rear)
    rear_guides = []
    for c in se.rear_holes():
        if c["ref"] == "VENT":
            continue
        if c["kind"] == "circle":
            rear_guides.append(Point(_wall(c["u"]), c["v"]).buffer(c["d"] / 2.0).exterior.buffer(0.01))
        else:
            x0, x1 = sorted((_wall(c["u"]), _wall(c["u"] + c["w"])))
            rear_guides.append(box(x0, c["v"], x1, c["v"] + c["h"]).exterior.buffer(0.01))
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
    # placement templates: paper, print at 1:1, the decal plus what it lines up with
    write_pdf(OUT / "segno_decal_logo_placement.pdf", logo, guides=lid_guides,
              title="Plantilla de ubicación del logo (imprimir en papel a 1:1)",
              notes=["Rojo punteado = aberturas de la tapa: las luces de CLEAR y BANK y el borde superior de sus pedales. "
                     "Alinear la plantilla con esas aberturas, marcar y aplicar el vinilo encima."])
    write_pdf(OUT / "segno_decal_rear_placement.pdf", rear, guides=rear_guides,
              title="Plantilla de ubicación de los rótulos traseros (imprimir en papel a 1:1)",
              notes=["Rojo punteado = agujeros de la pared trasera vistos desde AFUERA. "
                     "Los conectores se pueden montar antes: los rótulos van por encima de sus bridas."])
    # one cut sheet for the vinyl shop: logo above the rear strip
    lx0, ly0, lx1, ly1 = logo.bounds
    rx0, ry0, rx1, ry1 = rear.bounds
    sheet = unary_union([affinity.translate(logo, -lx0, ry1 - ry0 + 15.0 - ly0),
                         affinity.translate(rear, -rx0, -ry0)])
    write_dxf(OUT / "segno_decals_cut_sheet.dxf", sheet)
    write_svg(OUT / "segno_decals_cut_sheet.svg", sheet)
    write_pdf(OUT / "segno_decals_cut_sheet.pdf", sheet, title="Segno: hoja de corte de calcomanías (logo + rótulos traseros), 1:1", notes=[vinyl])
    print(f"logo {lx1 - lx0:.1f} x {ly1 - ly0:.1f} mm at lid u {lx0:.1f}..{lx1:.1f}, v {ly0:.1f}..{ly1:.1f}")
    print(f"rear strip {rx1 - rx0:.1f} x {ry1 - ry0:.1f} mm, baseline z {LABEL_BASE_Z}")
    return {"logo": logo.bounds, "rear": rear.bounds}


if __name__ == "__main__":
    main()
