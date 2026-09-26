"""Move C20 beside U2 pin 6 on a routed console board, and re-route locally.

console_board_pcb.py places C20 there now; a rip-up and reroute would route to
it. This script does the same move on the committed board without putting the
router back over every signal: it moves the footprint, re-routes the three nets
whose copper ran through the new pocket, and moves the two pieces of silkscreen
the capacitor's body lands on.

The pocket is 2 mm east of the opto, because the ISOLATION barrier around U2's
DIN side allows nothing closer, and it is crossed by two 0.6 mm rails - +3V3 at
y 79.442 on the front and +3V3_PICO at y 78.415 - with MIDI_RX walling off the
front at y 82.0083 and the +5V busbar's diagonal walling off the back to the
east. C20's two through-hole pads block both layers, so neither rail can keep
its own lane past them:

- +3V3 moves to the BACK through the pocket. U2 pin 6 and C20 pin 1 are both
  through-hole, so the leg between them needs no via, and the run carries on
  behind C20 to J22 pin 1 - a real pad of the same net - and back up to the
  front east of the capacitor to rejoin the copper it always fed. The eastern
  via sits at x 146.5: far enough east of C20's ground pad (0.273 mm) and far
  enough west of the busbar's own vertical (0.32 mm).
- +3V3_PICO keeps its front lane at y 78.415, which clears C20's pads by
  0.385 mm, and dives to the back at x 140.2 - in the 2 mm gap between U2's
  east pin column and C20's supply pad - instead of diagonally under the
  capacitor. It crosses MIDI_RX on the back, where MIDI_RX is not, and lands on
  the stub it always used.
- C20's ground pad needs no stitch of its own: it is a through-hole pad in the
  GND pour on both faces, and after the old copper comes out the nearest thing
  to it on the back is 1.4 mm away, so the pour reaches it and thermally
  relieves it like any other ground pad.

The new copper is left unlocked and mitred: round_routes.py rounds it with the
rest of the routed corners, and its own anchor rules keep the pads and the via.

Every coordinate below is checked against the board before anything is written.

    python3 patch_console_c20.py out_console/segno_console_board.kicad_pcb
"""
import argparse
from pathlib import Path
import re
import uuid

HERE = Path(__file__).resolve().parent
CONTRACT = ('"C20": (43.85, 19.9, 0),',
            'LABEL_AT = {"J9": (81.1, 64.1), "J25": (61.4, 64.1), '
            '"J22": (47.5, 32.4)}',
            '"U2": (40.25, 23.0)',
            '"C20": (48.45, 18.9), "R4": (51.15, 18.9)')
ORIGIN = (100.0, 60.0)
BODY = (43.85, 19.9)                     # board-local body centre, from source
PITCH = 2.5
OLD_BODY = (24.0, 21.0)
# What this replaces: U2 pin 6's +3V3 leg east, its via to J22, that leg's
# back-side run and the old stub into J22 pin 1; C20's old ground stitch; and
# the Pico rail's western half, which ran diagonally under the new pocket.
OLD = (('+3V3', 'F.Cu', (137.81, 78.46), (138.792, 79.442)),
       ('+3V3', 'F.Cu', (138.792, 79.442), (145.723, 79.442)),
       ('+3V3', 'F.Cu', (145.723, 79.442), (155.798, 79.442)),
       ('+3V3', 'F.Cu', (145.723, 79.442), (145.723, 79.5487)),
       ('+3V3', 'B.Cu', (145.723, 81.2652), (145.723, 79.5487)),
       ('+3V3', 'B.Cu', (145.03, 81.9583), (145.723, 81.2652)),
       # The last leg of that run, into J22 pin 1's pad centre. An earlier
       # version of this script left it behind, and it was the dangling tail
       # the native DRC reported - old copper, not new.
       ('+3V3', 'B.Cu', (145.03, 83.46), (145.03, 81.9583)),
       ('GND', 'F.Cu', (125.25, 81.0), (125.25, 79.55)),
       ('+3V3_PICO', 'F.Cu', (155.505, 78.414999), (145.4402, 78.414999)),
       ('+3V3_PICO', 'B.Cu', (145.4402, 78.414999), (137.5099, 86.3453)))
OLD_VIAS = ((145.723, 79.5487), (125.25, 79.55), (145.4402, 78.414999))
# The Pico rail's own stub at (137.5099, 86.3453)->(137.5099, 87.0291), its via
# there and its front leg south-west of it all stay: the new run lands on that
# stub exactly where the old diagonal did.
LANDING = (137.5099, 86.3453)
EAST = (155.798, 79.442)                 # where the +3V3 copper east of C20 ends
PICO_EAST = (155.505, 78.414999)
U2_PIN6 = (137.81, 78.46)
J22_PIN1 = (145.03, 83.46)
WIDTH = 0.6
VIA, DRILL = 0.8, 0.4
# Silk: the EXP label and U2's designator sit where the capacitor's body now is,
# C20's own designator would print on R4's pad, and R4's is in the one strip
# C20's fits in. console_board_pcb.py pins all four, so these are the spots a
# clean build prints: the label under J22's housing, U2's in the gap south-east
# of the opto, C20's and R4's side by side in the strip below R4. A footprint's
# designator moves with the footprint, so these offsets are footprint-local.
SILK = ((None, 'EXP', (146.3, 80.145), (147.5, 92.4)),
        ('U2', 'Reference', (10.43, 2.54), (10.06, 4.54)),
        ('C20', 'Reference', (1.25, -3.0438), (5.85, -1.0)),
        ('R4', 'Reference', (5.08, 3.0438), (6.23, 2.9)))


def geometry():
    """-> (pads, new tracks, new vias) in board coordinates."""
    cx, cy = ORIGIN[0]+BODY[0], ORIGIN[1]+BODY[1]
    supply, ground = (cx-PITCH/2, cy), (cx+PITCH/2, cy)
    lane = 146.5                         # the +3V3 rejoin, east of C20's pads
    dive = (140.2, 80.5)                 # where the Pico rail changes face
    tracks = [
        # +3V3: the opto's pin, the capacitor, J22's pad, and back to the front.
        ('+3V3', 'B.Cu', U2_PIN6, supply),
        ('+3V3', 'B.Cu', supply, (supply[0]+1.4, supply[1]+1.4)),
        ('+3V3', 'B.Cu', (supply[0]+1.4, supply[1]+1.4), J22_PIN1),
        ('+3V3', 'B.Cu', J22_PIN1, (lane, J22_PIN1[1]-1.37)),
        ('+3V3', 'B.Cu', (lane, J22_PIN1[1]-1.37), (lane, EAST[1])),
        ('+3V3', 'F.Cu', (lane, EAST[1]), EAST),
        # The Pico rail: same front lane, further west, then down the gap
        # between U2's pin column and C20's supply pad and across on the back.
        ('+3V3_PICO', 'F.Cu', PICO_EAST, (dive[0], PICO_EAST[1])),
        ('+3V3_PICO', 'F.Cu', (dive[0], PICO_EAST[1]), dive),
        ('+3V3_PICO', 'B.Cu', dive, (dive[0], 85.0)),
        ('+3V3_PICO', 'B.Cu', (dive[0], 85.0), LANDING)]
    vias = [('+3V3', (lane, EAST[1])), ('+3V3_PICO', dive)]
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


def move_silk(text, ref, name, frm, to):
    """Move one silk item, refusing to touch a board that does not hold it.

    A footprint's designator is a property inside the footprint and its
    position is footprint-local; a board label is a gr_text in absolute
    millimetres. Both are matched on their exact current position, so a board
    whose silk has already moved is left alone rather than half-patched.
    """
    if ref is None:
        head = f'(gr_text "{name}"\n\t\t(at '
        start = text.find(head)
        if start < 0:
            raise SystemExit(f'no board label {name!r} to move')
        window = (start, start+len(head)+60)
    else:
        (fstart, fend), body = footprint(text, ref)
        head = f'(property "{name}" "{ref}"\n\t\t\t(at '
        inner = body.find(head)
        if inner < 0:
            raise SystemExit(f'{ref} has no {name} property to move')
        window = (fstart+inner, fstart+inner+len(head)+60)
    chunk = text[window[0]:window[1]]
    old = f'(at {number(frm[0])} {number(frm[1])}'
    if old not in chunk:
        raise SystemExit(f'{name} is not at {frm} - already patched, or not '
                         'the board this migrates')
    return (text[:window[0]]
            + chunk.replace(old, f'(at {number(to[0])} {number(to[1])}', 1)
            + text[window[1]:])


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
    for ref, name, frm, to in SILK:
        text = move_silk(text, ref, name, frm, to)
    if not dry_run:
        path.write_text(text)
    print(f'{path.name}: C20 moved to the U2 pin 6 slot, {len(OLD)} segments '
          f'and {len(OLD_VIAS)} vias replaced by {len(tracks)} segments and '
          f'{len(vias)} vias, {len(SILK)} silk items moved'
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
