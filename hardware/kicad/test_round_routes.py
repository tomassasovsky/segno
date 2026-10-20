"""Native copper regression tests for round_routes.py.

Run with KiCad's Python: python3 hardware/kicad/test_round_routes.py.
No project boards are changed. Each fixture runs the public CLI twice in a
fresh directory; native copper shapes check contacts, clearance and keepouts.
Use --out DIRECTORY to retain boards and logs for inspection.
"""
from pathlib import Path
import argparse
import collections
import hashlib
import json
import math
import shutil
import subprocess
import sys
import tempfile
import pcbnew as p
OWNERS = []
USB = {f'S{ch}_{side}_{pol}' for ch in (1, 2) for side in ('UP', 'DN') for pol in ('P', 'N')}

def pt(xy):
    return p.VECTOR2I(*(round(v * 1000000.0) for v in xy))

def xy(v):
    return (v.x, v.y)

def new_board():
    b = p.BOARD()
    b.GetDesignSettings().SetCopperLayerCount(2)
    for a, z in zip([(-10, -10), (15, -10), (15, 80), (-10, 80)], [(15, -10), (15, 80), (-10, 80), (-10, -10)]):
        e = p.PCB_SHAPE(b)
        e.SetShape(p.SHAPE_T_SEGMENT)
        e.SetStart(pt(a))
        e.SetEnd(pt(z))
        e.SetLayer(p.Edge_Cuts)
        e.SetWidth(50000)
        b.Add(e)
    return b

def net(b, name):
    n = b.FindNet(name)
    if n is None or n.GetNetname() != name:
        n = p.NETINFO_ITEM(b, name)
        b.Add(n)
    return n

def wire(b, name, points, width=0.3, layer=p.F_Cu, locked=False):
    for a, z in zip(points, points[1:]):
        t = p.PCB_TRACK(b)
        t.SetStart(pt(a))
        t.SetEnd(pt(z))
        t.SetWidth(round(width * 1000000.0))
        t.SetLayer(layer)
        t.SetNet(net(b, name))
        t.SetLocked(locked)
        b.Add(t)

def pad(b, name, where, size=(0.3, 0.3), layer=p.F_Cu, angle=0, fpangle=0, shape=p.PAD_SHAPE_CIRCLE, custom=False):
    f = p.FOOTPRINT(b)
    f.SetReference(f'J{len(list(b.GetFootprints())) + 1}')
    f.SetValue('regression_fixture')
    f.SetPosition(pt(where))
    f.SetOrientationDegrees(fpangle)
    b.Add(f)
    a = p.PAD(f)
    a.SetNumber('1')
    a.SetSize(pt(size))
    a.SetShape(shape)
    a.SetAttribute(p.PAD_ATTRIB_SMD)
    layers = p.LSET()
    layers.AddLayer(layer)
    a.SetLayerSet(layers)
    a.SetPosition(f.GetPosition())
    a.SetOrientationDegrees(angle)
    a.SetNet(net(b, name))
    f.Add(a)
    if custom:
        a.SetShape(p.PAD_SHAPE_CUSTOM)
        a.SetAnchorPadShape(layer, p.PAD_SHAPE_RECT)
        poly = p.SHAPE_POLY_SET()
        poly.NewOutline()
        for x, y in [(-1, -1), (1, -1), (1, 1), (-1, 1)]:
            v = pt((x, y))
            poly.Append(v.x, v.y)
        a.AddPrimitivePoly(layer, poly, 0, True)
    return a

def via(b, name, where):
    v = p.PCB_VIA(b)
    v.SetPosition(pt(where))
    v.SetWidth(600000)
    v.SetDrill(300000)
    v.SetLayerPair(p.F_Cu, p.B_Cu)
    v.SetViaType(p.VIATYPE_THROUGH)
    v.SetNet(net(b, name))
    b.Add(v)

def fixture(label):
    b = new_board()
    L = [(-3, 0), (0, 0), (0, 3)]
    wire(b, 'A', L)
    if label == 'internal_pad':
        pad(b, 'A', (0, 0), size=(0.2, 0.2))
    elif label == 'edge_contact_pad':
        pad(b, 'A', (0.18, -0.18))
    elif label in ('track_keepout', 'footprint_track_keepout'):
        owner = b
        if label == 'footprint_track_keepout':
            owner = p.FOOTPRINT(b)
            owner.SetReference('KEEP')
            owner.SetValue('keepout_fixture')
            b.Add(owner)
        z = p.ZONE(owner)
        z.SetLayer(p.F_Cu)
        z.SetIsRuleArea(True)
        z.SetDoNotAllowTracks(True)
        z.SetDoNotAllowVias(False)
        z.SetDoNotAllowZoneFills(False)
        z.SetDoNotAllowPads(False)
        z.SetDoNotAllowFootprints(False)
        poly = z.Outline()
        poly.NewOutline()
        for vertex in [(-0.6, 0.25), (-0.25, 0.25), (-0.25, 0.6), (-0.6, 0.6)]:
            v = pt(vertex)
            poly.Append(v.x, v.y)
        owner.Add(z)
    elif label == 'internal_via':
        via(b, 'A', (0, 0))
        wire(b, 'A', [(0, 0), (0, -2)], layer=p.B_Cu)
        pad(b, 'A', (0, -2), layer=p.B_Cu)
    elif label == 'different_width_branch':
        wire(b, 'A', [(0, 0), (1, -1)], width=0.1)
        pad(b, 'A', (1, -1))
    elif label == 'locked_branch':
        wire(b, 'A', [(0, 0), (1, -1)], locked=True)
        pad(b, 'A', (1, -1))
    elif label == 'segment_interior_branch':
        for t in list(b.GetTracks()):
            b.RemoveNative(t)
        L = [(-3, 0), (3, 0), (3, 3)]
        wire(b, 'A', L)
        wire(b, 'A', [(2.8, 0), (2.8, -1)], width=0.1)
        pad(b, 'A', (2.8, -1))
    elif label == 'rotated_foreign_pad':
        pad(b, 'B', (-1.35, 2.15), size=(3.2, 1.6), angle=90, fpangle=90, shape=p.PAD_SHAPE_RECT)
    elif label == 'custom_foreign_pad':
        pad(b, 'B', (-1.55, 1.55), custom=True)
    elif label == 'two_new_chains':
        wire(b, 'B', [(-3, 0.7), (-0.7, 0.7), (-0.7, 3)])
    elif label == 'usb_skip':
        for t in list(b.GetTracks()):
            b.RemoveNative(t)
        for index, (ch, side) in enumerate(((c, s) for c in (1, 2) for s in ('UP', 'DN'))):
            y = 10 + 15 * index
            center = [(0, y), (4, y), (6, y + 2), (10, y + 2)]
            normals = []
            for a, z in zip(center, center[1:]):
                dx, dy = (z[0] - a[0], z[1] - a[1])
                l = math.hypot(dx, dy)
                normals.append((dy / l, -dx / l))
            offsets = [normals[0]]
            for a, z in zip(normals, normals[1:]):
                d = 1 + sum((x * y for x, y in zip(a, z)))
                offsets.append(((a[0] + z[0]) / d, (a[1] + z[1]) / d))
            offsets.append(normals[-1])
            for pol, sign in [('P', 1), ('N', -1)]:
                points = [(a[0] + v[0] * 0.505 * sign, a[1] + v[1] * 0.505 * sign) for a, v in zip(center, offsets)]
                wire(b, f'S{ch}_{side}_{pol}', points, 0.85)
        return b
    elif label == 'simple_curve':
        # The two 45-degree turns have room only for the 0.05 mm inside
        # radius. This catches the real ring's floating-point floor rejection.
        for track in list(b.GetTracks()):
            b.RemoveNative(track)
        L = [(0, 0), (0, 1.2633), (-0.2134, 1.4767), (-6.2189, 1.4767)]
        wire(b, 'A', L, width=0.55)
    else:
        raise ValueError(label)
    for terminal in (L[0], L[-1]):
        pad(b, 'A', terminal)
    return b

def load(path):
    b = p.LoadBoard(str(path))
    OWNERS.append(b)
    return b

def tracks(b):
    out = []
    for t in b.GetTracks():
        kind = t.GetClass()
        if kind == 'PCB_VIA':
            out.append((kind, t.GetNetname(), xy(t.GetPosition()), t.GetWidth(p.F_Cu), t.GetDrill(), t.IsLocked()))
            continue
        row = (kind, t.GetNetname(), t.GetLayer(), t.GetWidth(), tuple(sorted((xy(t.GetStart()), xy(t.GetEnd())))), t.IsLocked())
        if kind == 'PCB_ARC':
            row += (xy(t.GetMid()),)
        out.append(row)
    return sorted(out, key=str)

def copper_signature(rows):
    return [tuple(t[:5] + t[6:]) for t in rows]

def pad_geometry(b):
    out = []
    for f in b.GetFootprints():
        for a in f.Pads():
            polys = []
            for layer in (p.F_Cu, p.B_Cu):
                if a.IsOnLayer(layer):
                    s = a.GetEffectivePolygon(layer)
                    polys.append((layer, tuple((tuple((xy(s.COutline(i).CPoint(j)) for j in range(s.COutline(i).PointCount()))) for i in range(s.OutlineCount())))))
            out.append((f.GetReference(), a.GetNumber(), a.GetNetname(), xy(a.GetPosition()), xy(a.GetSize()), xy(a.GetDrillSize()), a.GetOrientationDegrees(), tuple(polys)))
    return sorted(out, key=str)

def items(b):
    out = []
    for item in list(b.GetTracks()) + [a for f in b.GetFootprints() for a in f.Pads()]:
        shapes = {layer: item.GetEffectiveShape(layer) for layer in (p.F_Cu, p.B_Cu) if item.IsOnLayer(layer)}
        if shapes:
            out.append((item.GetNetname(), item, shapes))
    return out

def components(b):
    allitems = items(b)
    by = collections.defaultdict(list)
    for index, (name, _, _) in enumerate(allitems):
        by[name].append(index)
    result = {}
    for name, indices in by.items():
        graph = {i: set() for i in indices}
        for pos, i in enumerate(indices):
            for j in indices[pos + 1:]:
                aa, bb = (allitems[i][2], allitems[j][2])
                if any((aa[layer].Collide(bb[layer], 0) for layer in set(aa) & set(bb))):
                    graph[i].add(j)
                    graph[j].add(i)
        left = set(indices)
        count = 0
        while left:
            count += 1
            todo = [left.pop()]
            while todo:
                for j in graph[todo.pop()] & left:
                    left.remove(j)
                    todo.append(j)
        result[name] = count
    return result

def minimum_clearance(b):
    copper = items(b)
    best = 2000000
    found = False
    for i, (name, a, ashapes) in enumerate(copper):
        for other, _, bshapes in copper[i + 1:]:
            if other == name:
                continue
            for layer in set(ashapes) & set(bshapes):
                sa, sb = (ashapes[layer], bshapes[layer])
                found = True
                if not sa.Collide(sb, best):
                    continue
                lo, hi = (0, best)
                if sa.Collide(sb, 0):
                    return 0
                while hi - lo > 1:
                    mid = (lo + hi) // 2
                    if sa.Collide(sb, mid):
                        hi = mid
                    else:
                        lo = mid
                best = hi
    return best if found else None

def keepout_hits(b):
    count = 0
    for zone in list(b.Zones()) + [z for f in b.GetFootprints() for z in f.Zones()]:
        if not zone.GetIsRuleArea() or not zone.GetDoNotAllowTracks():
            continue
        for t in b.GetTracks():
            if t.GetClass() == 'PCB_VIA' or not zone.IsOnLayer(t.GetLayer()):
                continue
            if zone.Outline().Collide(t.GetEffectiveShape(t.GetLayer()), 0):
                count += 1
    return count

def inspect(before, after):
    errors = []
    ta, tb = (tracks(before), tracks(after))
    ka, kb = (keepout_hits(before), keepout_hits(after))
    if kb > ka:
        errors.append('new track copper inside a native track keepout')
    if pad_geometry(before) != pad_geometry(after):
        errors.append('pad geometry changed')
    if [t for t in ta if t[0] == 'PCB_VIA'] != [t for t in tb if t[0] == 'PCB_VIA']:
        errors.append('via geometry changed')
    if collections.Counter((t for t in ta if t[5] is True)) - collections.Counter((t for t in tb if t[5] is True)):
        errors.append('pre-existing locked geometry changed')
    if [t for t in ta if t[1] in USB] != [t for t in tb if t[1] in USB]:
        errors.append('USB geometry changed')
    ca, cb = (components(before), components(after))
    if ca != cb:
        errors.append('native copper connectivity changed')
    ga, gb = (minimum_clearance(before), minimum_clearance(after))
    floor = min(200000, ga) if ga is not None else None
    if floor is not None and (gb is None or gb + 2 < floor):
        errors.append('foreign copper clearance below native baseline/rule floor')
    return {'errors': errors, 'before_keepout_hits': ka, 'after_keepout_hits': kb, 'before_components': ca, 'after_components': cb, 'before_clearance_mm': None if ga is None else ga / 1000000.0, 'after_clearance_mm': None if gb is None else gb / 1000000.0, 'before_track_count': len(ta), 'after_track_count': len(tb), 'geometry_changed': copper_signature(ta) != copper_signature(tb)}
CASES = ('edge_contact_pad', 'track_keepout', 'footprint_track_keepout', 'simple_curve', 'internal_pad', 'internal_via', 'different_width_branch', 'locked_branch', 'segment_interior_branch', 'rotated_foreign_pad', 'custom_foreign_pad', 'two_new_chains', 'usb_skip')

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--helper', type=Path, default=Path(__file__).with_name('round_routes.py'))
    ap.add_argument('--out', type=Path)
    ap.add_argument('--cases', nargs='*', choices=CASES)
    args = ap.parse_args()
    temporary = tempfile.TemporaryDirectory(prefix='round-routes-test-') if args.out is None else None
    args.out = args.out or Path(temporary.name)
    args.out.mkdir(parents=True, exist_ok=True)
    results = {}
    for name in args.cases or CASES:
        folder = args.out / name
        folder.mkdir(exist_ok=True)
        path = folder / 'fixture.kicad_pcb'
        fixture(name).Save(str(path))
        before = folder / 'before.kicad_pcb'
        shutil.copy2(path, before)
        cmd = [sys.executable, str(args.helper.resolve()), str(path), '--skip', ','.join(sorted(USB))]
        first = subprocess.run(cmd, capture_output=True, text=True)
        (folder / 'first.log').write_text(first.stdout + first.stderr)
        if first.returncode:
            results[name] = {'errors': ['helper failed'], 'exit_code': first.returncode}
            continue
        firstbytes = path.read_bytes()
        firstfile = folder / 'first.kicad_pcb'
        firstfile.write_bytes(firstbytes)
        a, b = (load(before), load(firstfile))
        row = inspect(a, b)
        second = subprocess.run(cmd, capture_output=True, text=True)
        (folder / 'second.log').write_text(second.stdout + second.stderr)
        row['second_exit_code'] = second.returncode
        row['second_bytes_stable'] = firstbytes == path.read_bytes()
        row['second_geometry_stable'] = copper_signature(tracks(load(path))) == copper_signature(tracks(b))
        if second.returncode:
            row['errors'].append('second run failed')
        if not row['second_bytes_stable']:
            row['errors'].append('second run changed bytes')
        if not row['second_geometry_stable']:
            row['errors'].append('second run changed track geometry')
        if name == 'simple_curve' and (not row['geometry_changed']):
            row['errors'].append('unobstructed corner was not rounded')
        if name == 'two_new_chains':
            row['nets_changed'] = {n: copper_signature([t for t in tracks(a) if t[1] == n]) != copper_signature([t for t in tracks(b) if t[1] == n]) for n in ('A', 'B')}
            if not all(row['nets_changed'].values()):
                row['errors'].append('two-chain fixture did not exercise two replacements')
        results[name] = row
        print(name, 'PASS' if not row['errors'] else 'FAIL', '; '.join(row['errors']), flush=True)
    report = {'helper': str(args.helper.resolve()), 'helper_sha256': hashlib.sha256(args.helper.read_bytes()).hexdigest(), 'native_version': p.GetBuildVersion(), 'results': results, 'passed': all((not r['errors'] for r in results.values()))}
    (args.out / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    return 0 if report['passed'] else 1
if __name__ == '__main__':
    sys.exit(main())
