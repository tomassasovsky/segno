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
OLD_TAP = ((35.62, 20), (35.62, 22))           # U2's own rail tap
OLD_LEG = ((36.79, 16.29), (35.62, 17.46))     # its feed from the C5 cluster
DEAD_FILLET = 35.62                            # the blend that went with it


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


def wire(a, b, width):
    return (f'\t(segment\n\t\t(start {number(a[0])} {number(a[1])})\n'
            f'\t\t(end {number(b[0])} {number(b[1])})\n'
            f'\t\t(width {number(width)})\n\t\t(locked yes)\n'
            f'\t\t(layer "F.Cu")\n\t\t(net "+5V_LED")\n'
            f'\t\t(uuid "{uuid.uuid4()}")\n\t)\n')


def patch(path, dry_run=False):
    text = path.read_text()
    segments = [(span, body) for span, body in blocks(text, 'segment')]
    drop, wanted = [], list(OLD_RAIL)+[OLD_TAP, OLD_LEG]
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
    def centre_x(body):
        xs = [float(x) for x, _y in
              re.findall(r'\(xy ([-\d.]+) ([-\d.]+)\)', body.split(
                  '(filled_polygon')[0])]
        return sum(xs)/len(xs) if xs else None
    fillets = [(span, body) for span, body in blocks(text, 'zone')
               if '"TAP_FILLET"' in body
               and abs((centre_x(body) or 0)-DEAD_FILLET) < 0.6]
    if len(fillets) != 1:
        raise SystemExit(f'{path.name}: expected one blend overlay at '
                         f'x={DEAD_FILLET}, found {len(fillets)}')
    drop.append(fillets[0][0])
    nodes = rp.rounded(rp.feed_nodes())
    added = ''.join(wire(a, b, rp.WIDTH) for a, b in zip(nodes, nodes[1:]))
    added += ''.join(wire(a, b, rp.TAP_WIDTH)
                     for a, b in zip(rp.LINK, rp.LINK[1:]))
    for span in sorted(drop, reverse=True):
        text = text[:span[0]] + text[span[1]:]
    spot = re.search(r'^\t\(zone\n', text, re.M)
    cut = spot.start() if spot else text.rindex('\n)')
    text = text[:cut] + added + text[cut:]
    if added.count('(') != added.count(')'):
        raise SystemExit('generated copper is unbalanced')
    if not dry_run:
        path.write_text(text)
    print(f'{path.name}: rail rounded into {len(nodes)-1} chords, U2 tap and '
          f'its feed leg replaced by the {len(rp.LINK)-1}-segment C5 link, '
          f'stale blend overlay removed' + (' (dry run)' if dry_run else ''))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('boards', nargs='+', type=Path)
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    for board in args.boards:
        patch(board, args.dry_run)


if __name__ == '__main__':
    main()
