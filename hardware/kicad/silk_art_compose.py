import os
"""Compose the intricate back-side art: full-width musical staff, a large segno
centrepiece, a generative loop-waveform band, and the wordmark -- every element
clipped around the pad keep-outs. Appends BACK_ART into silk_art.py (front art
is composed by extract_silk_art.py's front block, reused here)."""
import json, math, sys
sys.path.insert(0, '.')
from silk_art_extract import mark_polys, text_polys, MONO

# silk_art_pads.json: the bounding box of EVERY pad that opens the back solder
# mask on the placed board -- plated pads AND non-plated holes with a mask ring
# (the Pico module's three anchors are NPTH and were missed once, and the big
# segno landed on them). Regenerate it from out_console/console.placed.kicad_pcb
# whenever a through-hole part moves; pcbnew: pads whose LayerSet has B.Mask.
PADS = json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'silk_art_pads.json')))
M = 0.8                                   # silk-to-pad clearance
BW, BH = 99.5, 99.5
# The art is composed in READING coords and the applier mirrors it (x -> BW-x)
# onto B.Silkscreen -- so the keep-outs must be mirrored INTO reading coords
# here, or every clearance test looks at the wrong side of the board.
KEEP = [(BW - x2 - M, y1 - M, BW - x1 + M, y2 + M) for x1, y1, x2, y2 in PADS]
EDGE = 3.0                                # stay off the board edge

def clear_spans(y0, y1, x_lo, x_hi):
    """x-intervals within [x_lo,x_hi] free of keepouts crossing band y0..y1."""
    cuts = sorted((k[0], k[2]) for k in KEEP if k[1] < y1 and k[3] > y0)
    spans, x = [], x_lo
    for a, b in cuts:
        if b < x: continue
        if a > x_hi: break
        if a > x: spans.append((x, min(a, x_hi)))
        x = max(x, b)
        if x >= x_hi: break
    if x < x_hi: spans.append((x, x_hi))
    return [(a, b) for a, b in spans if b - a > 1.2]

def rect(x1, y1, x2, y2):
    return ([(x1, y1), (x2, y1), (x2, y2), (x1, y2)], [])

def point_clear(x, y, extra=0.0):
    return all(not (k[0]-extra < x < k[2]+extra and k[1]-extra < y < k[3]+extra) for k in KEEP)

def box_clear(x1, y1, x2, y2):
    return all(not (k[0] < x2 and k[2] > x1 and k[1] < y2 and k[3] > y1) for k in KEEP)

art = []

# ---- 1. the staff: five lines, 0.3 thick, 2.2 apart, spanning the board ----
STAFF_Y = 14.0                             # top line; band 14..22.8
for i in range(5):
    y = STAFF_Y + i * 2.2
    for a, b in clear_spans(y - 0.15, y + 0.15, EDGE, BW - EDGE):
        art.append(rect(a, y - 0.15, b, y + 0.15))
# a repeat barline pair (thick+thin) at the right end of the staff, where clear
for bx, w in ((92.0, 0.9), (90.2, 0.3)):
    if box_clear(bx - w/2, STAFF_Y - 0.2, bx + w/2, STAFF_Y + 8.8 + 0.2):
        art.append(rect(bx - w/2, STAFF_Y, bx + w/2, STAFF_Y + 8.8))
# repeat dots (the :| pair) just left of the barlines
for dy in (3.3, 5.5):
    cx, cy, r = 88.6, STAFF_Y + dy, 0.55
    if box_clear(cx - r, cy - r, cx + r, cy + r):
        pts = [(cx + r * math.cos(t), cy + r * math.sin(t)) for t in
               [k * math.tau / 24 for k in range(24)]]
        art.append((pts, []))

# ---- 2. the big segno: the largest one that fits WHOLE ----
# It used to take the least-obstructed spot for a fixed 32 mm mark and let the
# carve below cut the pins out of it, which left a logo with holes punched
# through it. A mark is not a staff line: it either fits or it does not. So
# search sizes from large to small and, at each, every position on a 0.5 mm
# grid, and keep the first size at which the glyph's OWN outline (not its box)
# touches no keep-out at all. Among the fitting spots prefer the one nearest
# the board's middle, so it reads as the centrepiece rather than a corner mark.
import pathops as _po

def _poly_path(outer, holes):
    p = _po.Path()
    pen = p.getPen()
    for c in [outer] + holes:
        pen.moveTo(c[0])
        for pt in c[1:]:
            pen.lineTo(pt)
        pen.closePath()
    p.simplify(fix_winding=True)
    return p

def _rect_path(x1, y1, x2, y2):
    p = _po.Path()
    pen = p.getPen()
    pen.moveTo((x1, y1)); pen.lineTo((x2, y1)); pen.lineTo((x2, y2)); pen.lineTo((x1, y2))
    pen.closePath()
    return p

keep_path = _po.Path()
for k in KEEP:
    keep_path = _po.op(keep_path, _rect_path(*k), _po.PathOp.UNION)

def _touches_keepout(polys):
    for outer, holes in polys:
        hit = _po.op(_poly_path(outer, holes), keep_path, _po.PathOp.INTERSECTION)
        if any(True for _ in hit):          # any contour at all = an overlap
            return True
    return False

def _fits(size, cx, cy):
    half_w, half_h = size * 0.45, size / 2 + 1.0
    x1, x2, y1, y2 = cx - half_w, cx + half_w, cy - half_h, cy + half_h
    if x1 < EDGE or x2 > BW - EDGE or y1 < STAFF_Y + 10.5 or y2 > 84.0:
        return None
    polys = mark_polys(size, cx, cy)
    inside = [k for k in KEEP if k[0] < x2 and k[2] > x1 and k[1] < y2 and k[3] > y1]
    if inside and _touches_keepout(polys):
        return None
    return polys

BIG, best, mark = None, None, None
for size in range(32, 15, -2):
    cands = sorted((math.dist((cx, cy), (BW / 2, 50.0)), cx, cy)
                   for cx in [x * 0.5 for x in range(2 * 20, 2 * 80)]
                   for cy in [y * 0.5 for y in range(2 * 26, 2 * 74)])
    for _d, cx, cy in cands:
        polys = _fits(size, cx, cy)
        if polys is not None:
            BIG, best, mark = size, (cx, cy), polys
            break
    if mark is not None:
        break
assert mark is not None, 'no spot on the back holds even a 16 mm segno whole'
print('segno mark:', BIG, 'mm at', best, '(whole, no carving)')

# ---- 3. the loop waveform band along the bottom ----
WY0, WY1 = 86.0, 96.0                      # band
mid = (WY0 + WY1) / 2
bar_w, pitch = 0.7, 1.5
x = EDGE + 0.5
k = 0
while x + bar_w < BW - EDGE:
    # a loop-ish envelope: layered sines + a couple of decaying transients
    t = k / 62.0
    env = (0.42 + 0.3 * abs(math.sin(t * math.tau * 1.5)) +
           0.28 * abs(math.sin(t * math.tau * 4 + 1.1)))
    for tr in (0.12, 0.55, 0.83):
        d = t - tr
        if d > 0:
            env += 0.55 * math.exp(-d * 18) * abs(math.sin(d * 200))
    h = min(1.0, env) * (WY1 - WY0) / 2
    y1, y2 = mid - h, mid + h
    if box_clear(x, y1, x + bar_w, y2):
        art.append(rect(x, y1, x + bar_w, y2))
    else:
        # shorten toward the centre until it clears (keeps the band flowing)
        for f in (0.7, 0.45, 0.25):
            if box_clear(x, mid - h * f, x + bar_w, mid + h * f):
                art.append(rect(x, mid - h * f, x + bar_w, mid + h * f))
                break
    x += pitch
    k += 1


# ---- carve every keep-out OUT of the staff and the waveform (DRC-clean by
# construction). The mark is added AFTER this: it fits whole, and a carve that
# ever touched it would mean the fit search above is wrong, not the art.
from silk_art_extract import flatten as _flatten, group_holes as _group, signed_area as _area

carved = []
for outer, holes in art:
    p = _poly_path(outer, holes)
    p = _po.op(p, keep_path, _po.PathOp.DIFFERENCE)
    cont = _flatten(p)
    for o2, h2 in _group(cont):
        if abs(_area(o2)) < 0.35:          # unprintable specks
            continue
        carved.append((o2, h2))
art = carved
print('after carving:', len(art), 'polys')
art += mark

# ---- 4. wordmark + year on genuinely clear ground (text must never be carved) ----
ART_ZONES = [
    (EDGE, STAFF_Y - 1.5, BW - EDGE, STAFF_Y + 10.3),                  # staff band
    (best[0] - BIG * 0.45 - 1.0, best[1] - BIG / 2 - 2.0,
     best[0] + BIG * 0.45 + 1.0, best[1] + BIG / 2 + 2.0),               # big mark
    (EDGE, WY0 - 1.0, BW - EDGE, WY1 + 1.0),                           # waveform
]

def find_text_spot(w, h, prefer_y):
    cands = []
    for cy in [y * 0.5 for y in range(2 * 12, 2 * 82)]:
        for cx in [x * 0.5 for x in range(2 * int(EDGE + 1), 2 * int(BW - EDGE - w))]:
            x1, y1, x2, y2 = cx, cy - h, cx + w, cy + 0.6
            if not box_clear(x1, y1, x2, y2):
                continue
            if any(z[0] < x2 and z[2] > x1 and z[1] < y2 and z[3] > y1 for z in ART_ZONES):
                continue
            cands.append((abs(cy - prefer_y), cx, cy))
    cands.sort()
    return cands[0][1:] if cands else None

wm_txt, wm_cap = "segno console board v3", 2.2
wm_w = len(wm_txt) * wm_cap * 0.72
spot = find_text_spot(wm_w, wm_cap * 1.4, 33.0)
assert spot, 'no clear spot for the wordmark'
wx, wy = spot
wm, adv = text_polys(MONO, wm_txt, wm_cap, wx, wy, tracking=0.1)
art += wm
# The wordmark is now ground the year cannot use: it used to land 1.5 mm
# under it, through its descenders. First choice is the wordmark's own
# baseline, a word-space after it; the line below is the footswitch jacks'
# pad row on this board, and the search fallback is anywhere clear.
ART_ZONES.append((wx - 1.0, wy - wm_cap * 1.4 - 1.0, wx + adv + 1.0, wy + 1.0))
_yx = wx + adv + 2.5                 # adv: the set width, not the estimate
spot2 = (_yx, wy) if (box_clear(_yx, wy - 2.2, _yx + 12.0, wy + 0.6) and
                      _yx + 12.0 < BW - EDGE) else \
        find_text_spot(12.0, 2.2, wy + wm_cap * 1.4 + 1.2)
if spot2:
    yr, _ = text_polys(MONO, "MMXXVI", 1.5, spot2[0], spot2[1], tracking=0.25)
    art += yr
print('wordmark at', (wx, wy), '| year at', spot2)

# merge into silk_art.py (regenerate FRONT via extract, then rewrite BACK)
import re
p = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'silk_art.py')
s = open(p).read()
s = re.sub(r"BACK_ART = .*", "BACK_ART = " + repr([
    ([(round(px, 3), round(py, 3)) for px, py in outer],
     [[(round(px, 3), round(py, 3)) for px, py in h] for h in holes])
    for outer, holes in art]) + "\n# fmt: on", s, flags=re.S)
open(p, 'w').write(s)
print('back art polys:', len(art), '| big segno at x =', best)
