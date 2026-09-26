"""Bring the manufactured ring board's strip supply up to the current source.

ring_power.py is the source of truth: install() draws this geometry before the
router runs. This script exists so the routed board can be moved forward
without a reroute. It rounds the 1.5 mm J1 to J2 rail's corners, and replaces
U2's own rail tap with the short link from C5 pin 1 that the source now
installs - the two taps, the rail between them and the pocket's 0.65 mm copper
used to enclose 8.9 mm2 of bare board. The three ground return barrels, the
rail's width and path, the C5 tap and its blend are untouched, and so is every
other net.

Geometry comes from ring_power itself, so this cannot drift from the source.

    python3 patch_ring_feed.py segno_pedal_ring.kicad_pcb
"""
import argparse
from pathlib import Path
import re
import uuid

import ring_power as rp

# Exactly the copper this replaces.
OLD_RAIL = (((52, 20), (47, 20)), ((47, 20), (45, 22)), ((45, 22), (39, 22)),
            ((39, 22), (35.62, 22)), ((35.62, 22), (32.19, 22)),
            ((32.19, 22), (32.19, 24)))
TAP = ((35.62, 20), (35.62, 22))               # U2's own rail tap
LEG = ((36.79, 16.29), (35.62, 17.46))         # its feed from the C5 cluster
LINK = ((39, 18.5), (37.5, 20), (35.62, 20))   # the dog-leg that replaced them


def number(value):
    return f'{round(value * 1_000_000) / 1_000_000:.6f}'.rstrip('0').rstrip('.')


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


def endpoints(body):
    pairs = []
    for key in ('start', 'end'):
        got = re.search(r'\(%s ([-\d.]+) ([-\d.]+)\)' % key, body)
        pairs.append((float(got.group(1)), float(got.group(2))))
    return pairs


def same(a, b, tol=2e-4):
    return abs(a[0]-b[0]) <= tol and abs(a[1]-b[1]) <= tol


def wire(a, b, width, locked=True):
    return (f'\t(segment\n\t\t(start {number(a[0])} {number(a[1])})\n'
            f'\t\t(end {number(b[0])} {number(b[1])})\n'
            f'\t\t(width {number(width)})\n'
            + ('\t\t(locked yes)\n' if locked else '')
            + f'\t\t(layer "F.Cu")\n\t\t(net "+5V_LED")\n'
              f'\t\t(uuid "{uuid.uuid4()}")\n\t)\n')


def fillet_zone(points):
    body = ''.join(f'\t\t\t\t(xy {number(x)} {number(y)})\n' for x, y in points)
    return ('\t(zone\n\t\t(net "+5V_LED")\n\t\t(layer "F.Cu")\n'
            f'\t\t(uuid "{uuid.uuid4()}")\n\t\t(name "TAP_FILLET")\n'
            '\t\t(locked yes)\n\t\t(hatch edge 0.5)\n\t\t(priority 20)\n'
            '\t\t(connect_pads yes\n\t\t\t(clearance 0)\n\t\t)\n'
            '\t\t(min_thickness 0.05)\n\t\t(fill yes\n'
            '\t\t\t(thermal_gap 0.5)\n\t\t\t(thermal_bridge_width 0.5)\n'
            '\t\t\t(island_removal_mode 0)\n\t\t)\n'
            f'\t\t(polygon\n\t\t\t(pts\n{body}\t\t\t)\n\t\t)\n\t)\n')


def restore_taps(path, dry_run=False):
    """Put U2's own tap and its feed leg back, on a board that lost them.

    The owner prefers the two straight vertical taps with rounded bases to the
    single tap and the dog-leg that replaced them, so this undoes that part of
    the earlier migration while keeping the rounded rail.
    """
    text = path.read_text()
    drop = []
    for a, b in zip(LINK, LINK[1:]):
        hits = [span for span, body in blocks(text, 'segment')
                if '"+5V_LED"' in body and '"F.Cu"' in body
                and ((same(endpoints(body)[0], a) and same(endpoints(body)[1], b))
                     or (same(endpoints(body)[0], b)
                         and same(endpoints(body)[1], a)))]
        if len(hits) != 1:
            raise SystemExit(f'{path.name}: expected one link segment {a}->{b}, '
                             f'found {len(hits)} - the taps are already back, '
                             'or this board never had the link')
        drop += hits
    if '"TAP_FILLET"' not in text:
        raise SystemExit(f'{path.name}: no blend overlay to match; run the '
                         'rail patch first')
    added = wire(TAP[0], TAP[1], rp.TAP_WIDTH)
    added += wire(LEG[0], LEG[1], rp.TAP_WIDTH, locked=False)
    added += fillet_zone(rp.tap_outline(TAP[0][0]))
    for span in sorted(drop, reverse=True):
        text = text[:span[0]] + text[span[1]:]
    spot = re.search(r'^\t\(zone\n', text, re.M)
    cut = spot.start() if spot else text.rindex('\n)')
    text = text[:cut] + added + text[cut:]
    if not dry_run:
        path.write_text(text)
    print(f'{path.name}: U2 tap, its feed leg and the second blend overlay '
          'restored' + (' (dry run)' if dry_run else ''))


def patch(path, dry_run=False):
    text = path.read_text()
    segments = [(span, body) for span, body in blocks(text, 'segment')]
    drop, wanted = [], list(OLD_RAIL)
    for a, b in wanted:
        hits = [(span, body) for span, body in segments
                if '"+5V_LED"' in body and '"F.Cu"' in body
                and ((same(endpoints(body)[0], a) and same(endpoints(body)[1], b))
                     or (same(endpoints(body)[0], b)
                         and same(endpoints(body)[1], a)))]
        if len(hits) != 1:
            raise SystemExit(f'{path.name}: expected one +5V_LED F.Cu segment '
                             f'{a}->{b}, found {len(hits)} - already patched, '
                             'or not the board this migrates')
        drop.append(hits[0][0])
    nodes = rp.rounded(rp.feed_nodes())
    added = ''.join(wire(a, b, rp.WIDTH) for a, b in zip(nodes, nodes[1:]))
    for span in sorted(drop, reverse=True):
        text = text[:span[0]] + text[span[1]:]
    spot = re.search(r'^\t\(zone\n', text, re.M)
    cut = spot.start() if spot else text.rindex('\n)')
    text = text[:cut] + added + text[cut:]
    if added.count('(') != added.count(')'):
        raise SystemExit('generated copper is unbalanced')
    if not dry_run:
        path.write_text(text)
    print(f'{path.name}: rail rounded into {len(nodes)-1} chords'
          + (' (dry run)' if dry_run else ''))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('boards', nargs='+', type=Path)
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--restore-taps', action='store_true',
                        help="put U2's tap and its feed leg back on a board "
                             'an earlier version of this script changed')
    args = parser.parse_args()
    for board in args.boards:
        if args.restore_taps:
            restore_taps(board, args.dry_run)
        else:
            patch(board, args.dry_run)


if __name__ == '__main__':
    main()
