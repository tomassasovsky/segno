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
from pathlib import Path
import re
import uuid

import console_ring_power as crp

HERE = Path(__file__).resolve().parent
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
          f'{added.count("(segment")} rounded chords'
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
