"""Bring a routed console board's 1.7 mm ring supply up to the current source.

console_ring_power.py is the source of truth: a rip-up and reroute installs
this geometry before the router runs. This script exists so the committed
board can be moved forward without putting Freerouting back over every signal
on it. It replaces exactly the eleven old mitred supply segments with the
rounded run the generator now yields - same 1.7 mm width, same path, the
vertical beside the pill busbar moved 0.27 mm east so the two overlap instead
of leaving a 0.05 mm dead-end slot at J24 pad 3 - and touches nothing else:
no zones, no vias, no other net, no footprint.

Needs no KiCad for the edit itself; it imports console_ring_power for the
geometry, so run it with the same Python that runs the board scripts.

    python3 patch_console_feed.py out_console/segno_console_board.kicad_pcb
"""
import argparse
import math
from pathlib import Path
import re
import uuid

import console_ring_power as crp

HERE = Path(__file__).resolve().parent
# Checked against console_board_pcb.py, so this cannot drift from the source
# that pours the same fillet on a regenerated board.
CONTRACT = ('PILL_BAR_R = 1.0', 'PILL_BLEND_R = 0.3',
            'PILL_BLEND_OVERLAP = 0.2', 'PILL_BAR_PRIORITY = 1')
BAR_R, BLEND_R, OVERLAP = 1.0, 0.3, 0.2
# Exactly the supply copper this replaces: (layer, start, end), millimetres.
OLD = (('B.Cu', (105.4, 113.0), (102.0, 116.4)),
       ('B.Cu', (102.0, 116.4), (102.0, 137.0)),
       ('B.Cu', (102.0, 137.0), (104.4, 139.4)),
       ('B.Cu', (104.4, 139.4), (104.4, 145.4)),
       ('B.Cu', (104.4, 145.4), (106.5, 147.5)),
       ('B.Cu', (106.5, 147.5), (139.0, 147.5)),
       ('B.Cu', (139.0, 147.5), (141.8, 144.7)),
       ('B.Cu', (141.8, 144.7), (141.8, 136.9)),
       ('F.Cu', (141.8, 136.9), (141.8, 134.0)),
       ('F.Cu', (141.8, 134.0), (146.8, 129.0)),
       ('F.Cu', (146.8, 129.0), (148.75, 129.0)))


def number(value):
    # Quantised by the generator, so the text and pcbnew name the same integer.
    return f'{crp._iu(value) / crp.IU:.6f}'.rstrip('0').rstrip('.')


def segments(text):
    """(span, width, start, end, layer, net) for every segment in the file."""
    out = []
    for m in re.finditer(r'\t\(segment\n(?:\t\t\([^\n]*\)\n)+\t\)\n', text):
        block = m.group(0)

        def pair(key):
            got = re.search(r'\(%s ([-\d.]+) ([-\d.]+)\)' % key, block)
            return (float(got.group(1)), float(got.group(2)))
        out.append((m.span(),
                    float(re.search(r'\(width ([\d.]+)\)', block).group(1)),
                    pair('start'), pair('end'),
                    re.search(r'\(layer "([^"]+)"\)', block).group(1),
                    re.search(r'\(net "([^"]+)"\)', block).group(1)))
    return out


def same(a, b, tol=2e-6):
    return abs(a[0]-b[0]) <= tol and abs(a[1]-b[1]) <= tol


def wire(a, b, layer):
    return (f'\t(segment\n\t\t(start {number(a[0])} {number(a[1])})\n'
            f'\t\t(end {number(b[0])} {number(b[1])})\n'
            f'\t\t(width {number(crp.WIDTH)})\n\t\t(locked yes)\n'
            f'\t\t(layer "{layer}")\n\t\t(net "+5V")\n'
            f'\t\t(uuid "{uuid.uuid4()}")\n\t)\n')


def blend(text):
    """The fillet outline for the busbar corner the supply crosses.

    Takes the busbar's own rectangle from the board, so the two agree by
    construction rather than by a copied number.
    """
    source = (HERE/'console_board_pcb.py').read_text()
    missing = [line for line in CONTRACT if line not in source]
    if missing:
        raise SystemExit('console_board_pcb.py no longer declares: '
                         + '; '.join(missing))
    rect = priority = None
    for _span, body in blocks(text, 'zone'):
        if '(net "+5V")' not in body or '"B.Cu"' not in body:
            continue
        pts = [(float(x), float(y)) for x, y in
               re.findall(r'\(xy ([-\d.]+) ([-\d.]+)\)',
                          body.split('(filled_polygon')[0])]
        if len(pts) == 4:
            rect = (min(p[0] for p in pts), min(p[1] for p in pts),
                    max(p[0] for p in pts), max(p[1] for p in pts))
            # The blend fills at the bar's own priority, so the two union. Taken
            # from the board for the same reason as the rectangle: a copied
            # number is a number that can drift. On a higher priority the blend
            # CUT the bar - it filled straight under the overlay and its 1 mm
            # corner arc came back clipped into a 48 degree kink.
            priority = int((re.search(r'\(priority (\d+)\)', body)
                            or (None, 0))[1])
    if rect is None:
        raise SystemExit('no rectangular +5V busbar zone on the back')
    x0, _y0, _x1, y1 = rect
    edge = crp.BACK_PATH[1][0] + crp.WIDTH/2.0
    if not x0 < edge < x0 + BAR_R:
        return priority, None
    cx, cy = x0 + BAR_R, y1 - BAR_R
    centre = (edge + BLEND_R,
              cy + math.sqrt((BAR_R + BLEND_R)**2 - (edge + BLEND_R - cx)**2))
    scale = BAR_R/(BAR_R + BLEND_R)
    touch = (cx + (centre[0]-cx)*scale, cy + (centre[1]-cy)*scale)
    inside = (touch[0] + (cx-touch[0])*OVERLAP/BAR_R,
              touch[1] + (cy-touch[1])*OVERLAP/BAR_R)
    back = edge - OVERLAP
    arc = []
    first = math.atan2(centre[1]-centre[1], edge-centre[0])
    last = math.atan2(touch[1]-centre[1], touch[0]-centre[0])
    if last - first > math.pi:
        last -= math.tau
    if first - last > math.pi:
        last += math.tau
    for i in range(13):
        angle = first + (last-first)*i/12
        arc.append((centre[0]+BLEND_R*math.cos(angle),
                    centre[1]+BLEND_R*math.sin(angle)))
    return priority, [(edge, centre[1]), *arc, inside, (back, inside[1]),
                      (back, centre[1])]


def fillet_zone(points, priority):
    body = ''.join(f'\t\t\t\t(xy {number(x)} {number(y)})\n' for x, y in points)
    return ('\t(zone\n\t\t(net "+5V")\n\t\t(layer "B.Cu")\n'
            f'\t\t(uuid "{uuid.uuid4()}")\n\t\t(name "POWER_FILLET")\n'
            '\t\t(locked yes)\n\t\t(hatch edge 0.5)\n'
            f'\t\t(priority {priority})\n'
            '\t\t(connect_pads\n\t\t\t(clearance 0.25)\n\t\t)\n'
            '\t\t(min_thickness 0.05)\n\t\t(fill yes\n'
            '\t\t\t(thermal_gap 0.3)\n\t\t\t(thermal_bridge_width 1.2)\n'
            '\t\t\t(island_removal_mode 0)\n\t\t)\n'
            f'\t\t(polygon\n\t\t\t(pts\n{body}\t\t\t)\n\t\t)\n\t)\n')


def blocks(text, keyword):
    """(span, body) for every top-level block of this kind."""
    out = []
    for m in re.finditer(r'^\t\(%s\n' % keyword, text, re.M):
        start = m.start()
        depth = 0
        for end in range(text.index('(', start), len(text)):
            depth += (text[end] == '(') - (text[end] == ')')
            if depth == 0:
                break
        out.append(((start, end+2), text[start:end+1]))
    return out


def patch(path, dry_run=False):
    text = path.read_text()
    found = segments(text)
    supply = [s for s in found
              if s[5] == '+5V' and abs(s[1]-crp.WIDTH) < 1e-9]
    if len(supply) != len(OLD):
        raise SystemExit(f'{path.name}: expected {len(OLD)} supply segments at '
                         f'{crp.WIDTH} mm, found {len(supply)} - already '
                         'patched, or not the board this migrates')
    drop = []
    for layer, a, b in OLD:
        hits = [s for s in supply
                if s[4] == layer and ((same(s[2], a) and same(s[3], b))
                                      or (same(s[2], b) and same(s[3], a)))]
        if len(hits) != 1:
            raise SystemExit(f'{path.name}: {layer} supply segment {a}->{b} is '
                             f'not on the board once ({len(hits)} matches)')
        drop.append(hits[0][0])
    layers = {crp.pcbnew.B_Cu: 'B.Cu', crp.pcbnew.F_Cu: 'F.Cu'}
    added = ''.join(wire(a, b, layers[layer])
                    for a, b, layer, width in crp._required_tracks()
                    if abs(width-crp.WIDTH) < 1e-9)
    if '"POWER_FILLET"' in text:
        raise SystemExit(f'{path.name}: already carries a blend overlay')
    priority, shape = blend(text)
    if shape:
        added += fillet_zone(shape, priority)
    for span in sorted(drop, reverse=True):
        text = text[:span[0]] + text[span[1]:]
    # Anchored at a line start: a footprint's own keepout zone is indented
    # deeper, and inserting board copper inside a footprint silently loses it.
    spot = re.search(r'^\t\(zone\n', text, re.M)
    cut = spot.start() if spot else text.rindex('\n)')
    text = text[:cut] + added + text[cut:]
    if added.count('(') != added.count(')'):
        raise SystemExit('generated copper is unbalanced')
    if not dry_run:
        path.write_text(text)
    print(f'{path.name}: replaced {len(OLD)} mitred supply segments with '
          f'{added.count("(segment")} rounded chords and '
          f'{added.count("(zone")} blend overlay'
          + (' (dry run)' if dry_run else ''))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('boards', nargs='+', type=Path)
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    for board in args.boards:
        patch(board, args.dry_run)


if __name__ == '__main__':
    main()
