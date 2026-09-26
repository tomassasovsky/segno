"""Bring a committed board's AUX input path up to the one route_critical draws.

route_critical.py is the source of truth: a full build redraws this path from
it. This script exists so the committed boards can be moved forward without
putting the router back over unrelated signals. It removes exactly the old
input copper - the 3mm trunk, the 1.9mm neck, the taper overlay and the two
old branch feeds - and writes the uniform 2.0mm path, the 1.5mm bulk branch,
the 0.8mm film branch and their blend overlays in its place. It touches no
other net, no other layer and no footprint, and it refuses to run against a
board whose old copper is not exactly what it expects, or against a source
file whose widths have moved on.

Needs no KiCad: the edit is textual, on the same fields KiCad writes.

    python3 patch_aux_input.py hand/screen_power_hand.kicad_pcb
    python3 patch_aux_input.py --dry-run hand/*.kicad_pcb
"""
import argparse
import math
from pathlib import Path
import re
import uuid

HERE = Path(__file__).resolve().parent
# Kept in step with route_critical.py by check_source() below, which refuses to
# patch a board once the generator's widths or tap positions have moved.
AUX, CAP, FILM = 2., 1.5, .8
CAP_TAP, FILM_TAP = 46.5, 50.
BLEND, FILM_BLEND, REACH, OVERLAP = .8, .7, .5, .2
CONTRACT = ('AUX=2.', 'CAP,FILM=1.5,.8', 'CAP_TAP,FILM_TAP=46.5,50.',
            'def sweep(width):return width/2+1',
            'reach=.5,overlap=.2', 'inward=e-side*overlap')
# The input path's own corners, and the two branch polylines, as the generator
# states them. Pad ends are filled in from the board.
TRUNK_BENDS = ((55, 14), (52, 11), (45.5, 11), (44, 9.5))
CAP_BENDS = ((CAP_TAP, 11), (CAP_TAP, 14.5))
FILM_BENDS = ((FILM_TAP, 11), (FILM_TAP, 17.5))
# Exactly the copper this replaces: (width, start, end), millimetres.
OLD = ((3., (56, 14), (55, 14)), (3., (55, 14), (52, 11)),
       (3., (52, 11), (47, 11)),
       (1.9, (47, 11), (45.5, 11)), (1.9, (45.5, 11), (44, 9.5)),
       (1.9, (44, 9.5), (44, 7.05)),
       (1.5, (47, 11), (45.5, 12.5)), (1.5, (45.5, 12.5), (44.4, 12.5)),
       (1.5, (44.4, 12.5), (41.817621, 15.082378)),
       (1.5, (41.817621, 15.082378), (41.817621, 16.5)),
       (.8, (47, 11), (46.8, 11.2)), (.8, (46.8, 11.2), (46.8, 17.3)),
       (.8, (46.8, 17.3), (48.5, 19)))
OLD_TAPER = ((45.5, 11.95), (47, 12.5), (47, 9.5), (45.5, 10.05))


def sweep(width):
    return width/2+1


def quarter(centre, frm, to, steps=12):
    radius = math.dist(centre, frm)
    first = math.atan2(frm[1]-centre[1], frm[0]-centre[0])
    last = math.atan2(to[1]-centre[1], to[0]-centre[0])
    if last-first > math.pi:
        last -= math.tau
    if first-last > math.pi:
        last += math.tau
    return [(centre[0]+radius*math.cos(first+(last-first)*i/steps),
             centre[1]+radius*math.sin(first+(last-first)*i/steps))
            for i in range(steps+1)]


def curve(points, radius, steps=8):
    """The generator's cornering, chord for chord."""
    out = [points[0]]
    last = len(points)-3
    for i, corner in enumerate(points[1:-1]):
        before, after = points[i], points[i+2]
        v1 = (before[0]-corner[0], before[1]-corner[1])
        v2 = (after[0]-corner[0], after[1]-corner[1])
        l1, l2 = math.hypot(*v1), math.hypot(*v2)
        u1, u2 = (v1[0]/l1, v1[1]/l1), (v2[0]/l2, v2[1]/l2)
        angle = math.acos(max(-1, min(1, u1[0]*u2[0]+u1[1]*u2[1])))
        if angle > math.pi-1e-9:
            out.append(corner)
            continue
        tangent = min(radius/math.tan(angle/2),
                      l1 if i == 0 else l1/2, l2 if i == last else l2/2)
        r = tangent*math.tan(angle/2)
        t1 = (corner[0]+u1[0]*tangent, corner[1]+u1[1]*tangent)
        t2 = (corner[0]+u2[0]*tangent, corner[1]+u2[1]*tangent)
        bisector = (u1[0]+u2[0], u1[1]+u2[1])
        bl = math.hypot(*bisector)
        centre = (corner[0]+bisector[0]/bl*(r/math.sin(angle/2)),
                  corner[1]+bisector[1]/bl*(r/math.sin(angle/2)))
        out += quarter(centre, t1, t2, steps)
    out.append(points[-1])
    return [q for i, q in enumerate(out)
            if i == 0 or math.dist(q, out[i-1]) > 1e-9]


def blend_outlines():
    """The two POWER_FILLET outlines, per tap and side."""
    lead = sweep(AUX)*math.tan(math.radians(22.5))
    turn = (45.5+lead, 11-sweep(AUX), sweep(AUX)+AUX/2)
    edge = 11+AUX/2
    out = []
    for x, width, spec, radius in ((CAP_TAP, CAP, turn, BLEND),
                                   (FILM_TAP, FILM, None, FILM_BLEND)):
        for side in (-1, 1):
            e = x+side*width/2
            centre = e+side*radius
            inward = e-side*OVERLAP
            if spec and side < 0:
                cx, cy, outer = spec
                cy_f = cy+math.sqrt((outer+radius)**2-(centre-cx)**2)
                scale = outer/(outer+radius)
                far = (cx+(centre-cx)*scale, cy+(cy_f-cy)*scale)
                out.append([(e, cy_f), *quarter((centre, cy_f), (e, cy_f), far),
                            (far[0]+(cx-far[0])*REACH/outer,
                             far[1]+(cy-far[1])*REACH/outer),
                            (inward, cy_f-radius-REACH), (inward, cy_f)])
            else:
                out.append([(e, edge+radius),
                            *quarter((centre, edge+radius), (e, edge+radius),
                                     (centre, edge)),
                            (centre, edge-REACH), (inward, edge-REACH),
                            (inward, edge+radius)])
    return out


def check_source():
    text = (HERE/'route_critical.py').read_text()
    missing = [line for line in CONTRACT if line not in text]
    if missing:
        raise SystemExit('route_critical.py no longer declares: '
                         + '; '.join(missing))


def number(value):
    return f'{value:.6f}'.rstrip('0').rstrip('.')


def segments(text):
    """(span, width, start, end, layer, net) for every segment in the file."""
    out = []
    for m in re.finditer(r'\t\(segment\n(?:\t\t\([^\n]*\)\n)+\t\)\n', text):
        block = m.group(0)

        def field(key, count=1):
            got = re.search(r'\(%s ([-\d.]+)%s\)' % (
                key, r' ([-\d.]+)' if count == 2 else ''), block)
            return tuple(float(v) for v in got.groups()) if got else None
        out.append((m.span(), field('width')[0], field('start', 2),
                    field('end', 2),
                    re.search(r'\(layer "([^"]+)"\)', block).group(1),
                    re.search(r'\(net "([^"]+)"\)', block).group(1)))
    return out


def zones(text):
    """(span, name, layer, net, points) for every top-level zone."""
    out = []
    for m in re.finditer(r'\n\t\(zone\n', text):
        start = m.start()+1
        depth = 0
        for end in range(text.index('(', start), len(text)):
            depth += (text[end] == '(') - (text[end] == ')')
            if depth == 0:
                break
        block = text[start:end+1]
        name = re.search(r'\t\t\(name "([^"]+)"\)', block)
        net = re.search(r'\t\t\(net "([^"]+)"\)', block)
        # The outline, not the cached fill: everything before filled_polygon.
        outline = block.split('(filled_polygon')[0]
        pts = re.search(r'\(polygon\n((?:.*\n)*?)\t\t\)', outline)
        # A rule area lists (layers "F.Cu" ...) where a pour has (layer "F.Cu").
        layer = re.search(r'\t\t\(layers? "([^"]+)"', block)
        out.append(((start, end+1), name.group(1) if name else None,
                    layer.group(1) if layer else None,
                    net.group(1) if net else None,
                    [(float(a), float(b)) for a, b in
                     re.findall(r'\(xy ([-\d.]+) ([-\d.]+)\)',
                                pts.group(1) if pts else '')]))
    return out


def wire(a, b, width, uid=None):
    return (f'\t(segment\n\t\t(start {number(a[0])} {number(a[1])})\n'
            f'\t\t(end {number(b[0])} {number(b[1])})\n'
            f'\t\t(width {number(width)})\n\t\t(locked yes)\n'
            f'\t\t(layer "F.Cu")\n\t\t(net "AUX_5V")\n'
            f'\t\t(uuid "{uid or uuid.uuid4()}")\n\t)\n')


def fillet_zone(points, uid=None):
    body = ''.join(f'\t\t\t\t(xy {number(x)} {number(y)})\n' for x, y in points)
    return ('\t(zone\n\t\t(net "AUX_5V")\n\t\t(layer "F.Cu")\n'
            f'\t\t(uuid "{uid or uuid.uuid4()}")\n'
            '\t\t(name "POWER_FILLET")\n'
            '\t\t(locked yes)\n\t\t(hatch edge 0.5)\n\t\t(priority 20)\n'
            '\t\t(connect_pads yes\n\t\t\t(clearance 0.2)\n\t\t)\n'
            '\t\t(min_thickness 0.05)\n\t\t(fill yes\n'
            '\t\t\t(thermal_gap 0.5)\n\t\t\t(thermal_bridge_width 0.5)\n'
            '\t\t\t(island_removal_mode 0)\n\t\t)\n'
            f'\t\t(polygon\n\t\t\t(pts\n{body}\t\t\t)\n\t\t)\n\t)\n')


def same(a, b, tol=2e-6):
    return abs(a[0]-b[0]) <= tol and abs(a[1]-b[1]) <= tol


def patch(path, dry_run=False):
    text = path.read_text()
    found = segments(text)
    drop = []
    for width, a, b in OLD:
        hits = [s for s in found
                if s[1] == width and s[4] == 'F.Cu' and s[5] == 'AUX_5V'
                and ((same(s[2], a) and same(s[3], b))
                     or (same(s[2], b) and same(s[3], a)))]
        if len(hits) != 1:
            raise SystemExit(f'{path.name}: expected one {width}mm AUX segment '
                             f'{a}->{b}, found {len(hits)}')
        drop.append(hits[0][0])
    taper = [z for z in zones(text)
             if z[1] == 'POWER_TAPER' and z[3] == 'AUX_5V' and z[2] == 'F.Cu'
             and len(z[4]) == len(OLD_TAPER)
             and all(same(p, q) for p, q in zip(z[4], OLD_TAPER))]
    if len(taper) != 1:
        raise SystemExit(f'{path.name}: expected one AUX taper overlay, '
                         f'found {len(taper)}')
    drop.append(taper[0][0])
    # Pad ends come from the board, so a footprint that moved is caught by the
    # segment match above rather than silently re-drawn in the wrong place.
    j1, q3d = OLD[0][1], OLD[5][2]
    cap, film = OLD[9][2], OLD[12][2]
    added = ''
    for points, width in (
            ([j1, *TRUNK_BENDS, q3d], AUX),
            ([*CAP_BENDS, (cap[0], CAP_BENDS[-1][1]), cap], CAP),
            ([*FILM_BENDS, film], FILM)):
        chords = curve(points, sweep(width))
        added += ''.join(wire(a, b, width)
                         for a, b in zip(chords, chords[1:]))
    added += ''.join(fillet_zone(shape) for shape in blend_outlines())
    for span in sorted(drop, reverse=True):
        text = text[:span[0]] + text[span[1]:]
    cut = text.index('\t(zone\n')
    text = text[:cut] + added + text[cut:]
    if added.count('(') != added.count(')'):
        raise SystemExit('generated copper is unbalanced')
    if not dry_run:
        path.write_text(text)
    print(f'{path.name}: replaced {len(OLD)} segments and the taper overlay '
          f'with {added.count("(segment")} chords and '
          f'{added.count("(zone")} blend overlays'
          + (' (dry run)' if dry_run else ''))


def patch_fillets(path, dry_run=False):
    """Restate only the four blend overlays on an already-patched board.

    For a board the full patch has already run on: the tracks, the tap
    positions and the exposed arcs are unchanged, so each overlay is matched by
    its own first corner - the point where its arc meets the branch edge - and
    rewritten with the closure that overlaps the branch. Nothing else in the
    file is read or written, and the cached fill goes with the old outline, so
    KiCad pours these afresh.
    """
    text = path.read_text()
    stale = [s for s in segments(text) for width, a, b in OLD
             if s[1] == width and s[4] == 'F.Cu' and s[5] == 'AUX_5V'
             and ((same(s[2], a) and same(s[3], b))
                  or (same(s[2], b) and same(s[3], a)))]
    if stale:
        raise SystemExit(f'{path.name}: still carries {len(stale)} of the old '
                         'AUX segments - run the full patch, not --fillets-only')
    found = [z for z in zones(text)
             if z[1] == 'POWER_FILLET' and z[3] == 'AUX_5V' and z[2] == 'F.Cu']
    if len(found) != 4:
        raise SystemExit(f'{path.name}: expected four AUX blend overlays, '
                         f'found {len(found)}')
    wanted = blend_outlines()
    edits = []
    for span, _name, _layer, _net, points in found:
        match = [shape for shape in wanted if same(shape[0], points[0])]
        if len(match) != 1:
            raise SystemExit(f'{path.name}: no single blend outline starts at '
                             f'{points[0]}')
        uid = re.search(r'\t\t\(uuid "([^"]+)"\)', text[span[0]:span[1]])
        edits.append((span, fillet_zone(match[0], uid.group(1))))
        wanted.remove(match[0])
    for span, block in sorted(edits, reverse=True):
        text = text[:span[0]] + block + text[span[1]:]
    if not dry_run:
        path.write_text(text)
    print(f'{path.name}: restated {len(edits)} blend overlays'
          + (' (dry run)' if dry_run else ''))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('boards', nargs='+', type=Path)
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--fillets-only', action='store_true',
                        help='restate the four blend overlays on a board the '
                             'full patch has already run on')
    args = parser.parse_args()
    check_source()
    for board in args.boards:
        if args.fillets_only:
            patch_fillets(board, args.dry_run)
        else:
            patch(board, args.dry_run)


if __name__ == '__main__':
    main()
