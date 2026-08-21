"""Extract the segno mark (Bravura U+E047) + JetBrains Mono glyph outlines and
compose the two silkscreen art blocks for the console board, emitting
hardware/kicad/silk_art.py with placed contours in board-relative mm.

Conventions of the output:
- Coordinates are (x, y) in mm, y DOWN (KiCad's convention), relative to the
  board origin (100, 60) so the generator can place them absolutely.
- Each poly is (outer, [holes]) with points as (x, y) tuples.
"""
import math

from fontTools.ttLib import TTFont
from fontTools.pens.recordingPen import RecordingPen
import pathops

import os
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BRAVURA = "/Users/Tomas/Library/Fonts/Bravura.otf"
MONO = os.path.join(REPO, "assets/fonts/JetBrainsMono-Regular.ttf")


def glyph_path(font_path, char=None, uni=None):
    font = TTFont(font_path)
    cmap = font.getBestCmap()
    code = uni if uni is not None else ord(char)
    if code not in cmap:
        raise KeyError(f"U+{code:04X} not in {font_path}")
    gname = cmap[code]
    glyphset = font.getGlyphSet()
    glyph = glyphset[gname]
    pen = RecordingPen()
    glyph.draw(pen)
    path = pathops.Path()
    pp = path.getPen()
    pen.replay(pp)
    path.simplify(fix_winding=True)
    upem = font["head"].unitsPerEm
    return path, glyph.width, upem


def flatten(path, tol=0.7):
    """pathops path -> list of contours (lists of (x,y)), font units, y UP."""
    out = []
    cur = []
    start = None
    def flat_curve(pts, segs):
        # de Casteljau sampling for quads/cubics already handled by pathops
        return pts
    for verb, pts in path:
        if verb == pathops.PathVerb.MOVE:
            if cur:
                out.append(cur)
            cur = [pts[0]]
            start = pts[0]
        elif verb == pathops.PathVerb.LINE:
            cur.append(pts[0])
        elif verb == pathops.PathVerb.QUAD:
            p0 = cur[-1]
            n = 8
            for i in range(1, n + 1):
                t = i / n
                x = (1-t)**2*p0[0] + 2*(1-t)*t*pts[0][0] + t*t*pts[1][0]
                y = (1-t)**2*p0[1] + 2*(1-t)*t*pts[0][1] + t*t*pts[1][1]
                cur.append((x, y))
        elif verb == pathops.PathVerb.CUBIC:
            p0 = cur[-1]
            n = 10
            for i in range(1, n + 1):
                t = i / n
                mt = 1 - t
                x = mt**3*p0[0] + 3*mt*mt*t*pts[0][0] + 3*mt*t*t*pts[1][0] + t**3*pts[2][0]
                y = mt**3*p0[1] + 3*mt*mt*t*pts[0][1] + 3*mt*t*t*pts[1][1] + t**3*pts[2][1]
                cur.append((x, y))
        elif verb == pathops.PathVerb.CLOSE:
            if cur:
                out.append(cur)
                cur = []
    if cur:
        out.append(cur)
    return out


def signed_area(c):
    a = 0.0
    for i in range(len(c)):
        x1, y1 = c[i]
        x2, y2 = c[(i + 1) % len(c)]
        a += x1 * y2 - x2 * y1
    return a / 2.0


def inside(pt, c):
    x, y = pt
    n = len(c)
    hit = False
    for i in range(n):
        x1, y1 = c[i]
        x2, y2 = c[(i + 1) % n]
        if (y1 > y) != (y2 > y) and x < (x2 - x1) * (y - y1) / (y2 - y1) + x1:
            hit = not hit
    return hit


def group_holes(contours):
    """Return [(outer, [holes])]; classification by containment depth."""
    groups = []
    outers = []
    holes = []
    for c in contours:
        depth = sum(1 for o in contours if o is not c and inside(c[0], o))
        (outers if depth % 2 == 0 else holes).append(c)
    for o in outers:
        my = [h for h in holes if inside(h[0], o)]
        groups.append((o, my))
    return groups


def place(groups, scale, dx, dy):
    """scale font units -> mm, y-flip (font y up -> board y down), translate."""
    out = []
    for outer, hs in groups:
        po = [(round(x * scale + dx, 3), round(-y * scale + dy, 3)) for x, y in outer]
        ph = [[(round(x * scale + dx, 3), round(-y * scale + dy, 3)) for x, y in h] for h in hs]
        out.append((po, ph))
    return out


def text_polys(font_path, text, cap_mm, dx, dy, tracking=0.0):
    """Compose a string; returns (polys, advance_mm). dy = BASELINE y (board mm)."""
    font = TTFont(font_path)
    upem = font["head"].unitsPerEm
    cap = font["OS/2"].sCapHeight or int(upem * 0.7)
    scale = cap_mm / cap
    x = dx
    polys = []
    for ch in text:
        if ch == " ":
            x += 0.6 * cap_mm
            continue
        path, adv, _ = glyph_path(font_path, char=ch)
        groups = group_holes(flatten(path))
        polys += place(groups, scale, x, dy)
        x += adv * scale + tracking
    return polys, x - dx


def mark_polys(height_mm, cx, cy):
    """The Bravura segno mark, centred at (cx, cy), height_mm tall."""
    path, adv, upem = glyph_path(BRAVURA, uni=0xE047)
    cont = flatten(path)
    xs = [p[0] for c in cont for p in c]
    ys = [p[1] for c in cont for p in c]
    w, h = max(xs) - min(xs), max(ys) - min(ys)
    scale = height_mm / h
    dx = cx - (min(xs) + w / 2) * scale
    dy = cy + (min(ys) + h / 2) * scale          # y-flip: centre maps to centre
    return place(group_holes(cont), scale, dx, dy)


def fmt(polys):
    return repr(polys)


def main():
    # FRONT strip: board-rel x 24..63, y 42..51 (9 tall). Mark 8mm at left,
    # wordmark 5mm caps, baseline sits 1.5 above strip bottom.
    # left-edge pocket (below C30, left of the 5V header): mark over wordmark
    front = []
    front += mark_polys(7.0, 7.5, 44.2)
    wm, adv = text_polys(MONO, "segno", 2.2, 7.5 - 4.55, 49.6, tracking=0.12)
    front += wm
    # BACK strip: x 10..89, y 90..99. Mirrored in X for the back side (so it
    # reads correctly when the board is flipped over): compose normally, the
    # applier mirrors. Mark + long legend, 4.5mm caps.
    back = []
    back += mark_polys(8.0, 10 + 4.5, 94.5)
    leg, adv = text_polys(MONO, "segno console board v2", 3.2, 10 + 10.5, 96.9, tracking=0.15)
    back += leg
    yr, _ = text_polys(MONO, "MMXXVI", 1.8, 10 + 10.7, 91.6, tracking=0.3)
    back += yr
    with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "silk_art.py"), "w") as f:
        f.write('"""Silkscreen artwork for the console board -- GENERATED by\n')
        f.write("scratchpad extract_silk_art.py from Bravura (the segno mark, SMuFL U+E047)\n")
        f.write("and JetBrains Mono (the project's mono face). Coordinates are board-relative\n")
        f.write("mm, y down; each entry is (outer, [holes]). Regenerate rather than hand-edit.\n")
        f.write('"""\n\n')
        f.write("# fmt: off\n")
        f.write("FRONT_ART = " + fmt(front) + "\n\n")
        f.write("BACK_ART = " + fmt(back) + "\n")
        f.write("# fmt: on\n")
    print("front polys:", len(front), "back polys:", len(back))
    xs = [p[0] for pl, _ in front for p in pl]
    ys = [p[1] for pl, _ in front for p in pl]
    print("front extent:", round(min(xs), 1), round(min(ys), 1), round(max(xs), 1), round(max(ys), 1))
    xs = [p[0] for pl, _ in back for p in pl]
    ys = [p[1] for pl, _ in back for p in pl]
    print("back extent:", round(min(xs), 1), round(min(ys), 1), round(max(xs), 1), round(max(ys), 1))


main()
