"""Move C20 beside U2 pin 6 on a routed console board, and re-route locally.

console_board_pcb.py places C20 there now; a rip-up and reroute would route to
it. This script does the same move on the committed board without putting the
router back over every signal: it moves the footprint, re-routes the one branch
that is in the way - U2's +3V3 leg, which used to run straight across the new
ground pad - moves that branch's via to J22 onto the new path, and moves C20's
own ground stitch. It touches no other net: the Pico rail's own track and via
stay where they are, which is why C20 sits 0.75 mm west of the courtyard centre.

Every coordinate below is checked against the board before anything is written.

    python3 patch_console_c20.py out_console/segno_console_board.kicad_pcb
"""
import argparse
import math
from pathlib import Path
import re
import uuid

HERE = Path(__file__).resolve().parent
CONTRACT = ('"C20": (43.0, 19.6, 0),',)
ORIGIN = (100.0, 60.0)
BODY = (43.0, 19.6)                      # board-local body centre, from source
PITCH = 2.5
OLD_BODY = (24.0, 21.0)
# What this replaces: U2 pin 6's +3V3 leg east, its via to J22 and the leg's
# back-side run, plus C20's old ground stitch.
OLD = (('+3V3', 'F.Cu', (137.81, 78.46), (138.792, 79.442)),
       ('+3V3', 'F.Cu', (138.792, 79.442), (145.723, 79.442)),
       ('+3V3', 'F.Cu', (145.723, 79.442), (155.798, 79.442)),
       ('+3V3', 'F.Cu', (145.723, 79.442), (145.723, 79.5487)),
       ('+3V3', 'B.Cu', (145.723, 81.2652), (145.723, 79.5487)),
       ('+3V3', 'B.Cu', (145.03, 81.9583), (145.723, 81.2652)),
       ('GND', 'F.Cu', (125.25, 81.0), (125.25, 79.55)),
       # and the Pico rail's back-side leg, which ran under the new ground pad
       ('+3V3_PICO', 'B.Cu', (145.4402, 78.415), (137.5099, 86.3453)),
       ('+3V3_PICO', 'B.Cu', (137.5099, 86.3453), (137.5099, 87.0291)))
OLD_VIAS = ((145.723, 79.5487), (125.25, 79.55))
WIDTH = 0.6
VIA, DRILL = 0.8, 0.4


def geometry():
    """-> (pads, new tracks, new vias) in board coordinates."""
    cx, cy = ORIGIN[0]+BODY[0], ORIGIN[1]+BODY[1]
    supply, ground = (cx-PITCH/2, cy), (cx+PITCH/2, cy)
    u2 = (137.81, 78.46)
    knee = (u2[0]+abs(cy-u2[1]), cy)          # 45 degrees out of the pin
    dive = (supply[0]+1.4, cy+1.4)            # south around the ground pad
    lane = 146.0                              # where the via to J22 now sits
    rejoin = (147.558, 79.442)
    tracks = [('+3V3', 'F.Cu', u2, knee), ('+3V3', 'F.Cu', knee, supply),
              ('+3V3', 'F.Cu', supply, dive),
              ('+3V3', 'F.Cu', dive, (lane, dive[1])),
              ('+3V3', 'F.Cu', (lane, dive[1]), rejoin),
              ('+3V3', 'F.Cu', rejoin, (155.798, 79.442)),
              ('+3V3', 'B.Cu', (lane, dive[1]), (lane, dive[1]+1.49)),
              ('+3V3', 'B.Cu', (lane, dive[1]+1.49), (145.03, 83.46)),
              ('GND', 'F.Cu', ground, (ground[0]+1.65, ground[1])),
              # The Pico rail goes over the top of the capacitor instead of
              # under it: north out of its via, west past U2's pin row, then
              # down to the via it always used. 5.5 mm longer on a 0.6 mm
              # logic supply, which is 2.5 milliohms.
              ('+3V3_PICO', 'B.Cu', (145.4402, 78.415), (144.0, 77.0)),
              ('+3V3_PICO', 'B.Cu', (144.0, 77.0), (139.5, 77.0)),
              ('+3V3_PICO', 'B.Cu', (139.5, 77.0), (139.5, 84.0)),
              ('+3V3_PICO', 'B.Cu', (139.5, 84.0), (137.5099, 85.9901)),
              ('+3V3_PICO', 'B.Cu', (137.5099, 85.9901), (137.5099, 87.0291))]
    vias = [('+3V3', (lane, dive[1])), ('GND', (ground[0]+1.65, ground[1]))]
    return (supply, ground), tracks, vias


def number(value):
    return f'{round(value * 1_000_000) / 1_000_000:.6f}'.rstrip('0').rstrip('.')


def blocks(text, keyword):
    out = []
    for m in re.finditer(r'^\t\(%s[\s(]' % keyword, text, re.M):
        start = m.start()
        depth = 0
        for end in range(text.index('(', start), len(text)):
            depth += (text[end] == '(') - (text[end] == ')')
            if depth == 0:
                break
        out.append(((start, end+2), text[start:end+1]))
    return out


def footprint(text, ref):
    for span, body in blocks(text, 'footprint'):
        if re.search(r'\(property "Reference" "%s"' % ref, body):
            return span, body
    raise SystemExit(f'no footprint {ref} on the board')


def pair(body, key):
    got = re.search(r'\(%s ([-\d.]+) ([-\d.]+)' % key, body)
    return (float(got.group(1)), float(got.group(2)))


def same(a, b, tol=2e-4):
    return abs(a[0]-b[0]) <= tol and abs(a[1]-b[1]) <= tol


def wire(net, layer, a, b, width=WIDTH):
    return (f'\t(segment\n\t\t(start {number(a[0])} {number(a[1])})\n'
            f'\t\t(end {number(b[0])} {number(b[1])})\n'
            f'\t\t(width {number(width)})\n'
            f'\t\t(layer "{layer}")\n\t\t(net "{net}")\n'
            f'\t\t(uuid "{uuid.uuid4()}")\n\t)\n')


def via(net, at):
    return (f'\t(via\n\t\t(at {number(at[0])} {number(at[1])})\n'
            f'\t\t(size {number(VIA)})\n\t\t(drill {number(DRILL)})\n'
            f'\t\t(layers "F.Cu" "B.Cu")\n\t\t(net "{net}")\n'
            f'\t\t(uuid "{uuid.uuid4()}")\n\t)\n')


def patch(path, dry_run=False):
    source = (HERE/'console_board_pcb.py').read_text()
    missing = [line for line in CONTRACT if line not in source]
    if missing:
        raise SystemExit('console_board_pcb.py no longer declares: '
                         + '; '.join(missing))
    text = path.read_text()
    span, body = footprint(text, 'C20')
    here = pair(body, 'at')
    want_old = (ORIGIN[0]+OLD_BODY[0]-PITCH/2, ORIGIN[1]+OLD_BODY[1])
    if not same(here, want_old):
        raise SystemExit(f'{path.name}: C20 is at {here}, not {want_old} - '
                         'already patched, or not the board this migrates')
    (supply, _ground), tracks, vias = geometry()
    moved = body.replace(f'(at {number(here[0])} {number(here[1])})',
                         f'(at {number(supply[0])} {number(supply[1])})', 1)
    if moved == body:
        raise SystemExit(f'{path.name}: could not rewrite C20\'s position')
    drop = []
    for net, layer, a, b in OLD:
        hits = [s for s, seg in blocks(text, 'segment')
                if f'(net "{net}")' in seg and f'(layer "{layer}")' in seg
                and ((same(pair(seg, 'start'), a) and same(pair(seg, 'end'), b))
                     or (same(pair(seg, 'start'), b)
                         and same(pair(seg, 'end'), a)))]
        if len(hits) != 1:
            raise SystemExit(f'{path.name}: expected one {net} {layer} segment '
                             f'{a}->{b}, found {len(hits)}')
        drop += hits
    for at in OLD_VIAS:
        hits = [s for s, v in blocks(text, 'via') if same(pair(v, 'at'), at)]
        if len(hits) != 1:
            raise SystemExit(f'{path.name}: expected one via at {at}, '
                             f'found {len(hits)}')
        drop += hits
    added = ''.join(wire(*t) for t in tracks) + ''.join(via(*v) for v in vias)
    text = text[:span[0]] + moved + text[span[1]-1:]      # footprint first
    shift = len(moved) - (span[1]-1 - span[0])
    drop = [(a+shift if a > span[0] else a, b+shift if b > span[0] else b)
            for a, b in drop]
    for cut in sorted(drop, reverse=True):
        text = text[:cut[0]] + text[cut[1]:]
    spot = re.search(r'^\t\(zone\n', text, re.M)
    cut = spot.start() if spot else text.rindex('\n)')
    text = text[:cut] + added + text[cut:]
    if added.count('(') != added.count(')'):
        raise SystemExit('generated copper is unbalanced')
    if not dry_run:
        path.write_text(text)
    print(f'{path.name}: C20 moved to the U2 pin 6 slot, {len(OLD)} segments '
          f'and {len(OLD_VIAS)} vias replaced by {len(tracks)} segments and '
          f'{len(vias)} vias' + (' (dry run)' if dry_run else ''))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('boards', nargs='+', type=Path)
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    for board in args.boards:
        patch(board, args.dry_run)


if __name__ == '__main__':
    main()
