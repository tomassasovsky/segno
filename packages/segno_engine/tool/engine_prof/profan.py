#!/usr/bin/env python3
"""Reads section-profiler snapshots (src/core/engine_prof.h, proftel.py), #1914.
The layout constants below follow le_prof; keep them in step. usage:
profan.py hist <label=a.bin:b.bin> ...   per-section percentiles of b minus a
profan.py tail <a.bin> <b.bin> [n]        b's slowest tail records after a
profan.py timeline <a.bin> <b.bin> <events> [ms]
    tail records after a in bins of ms (default 250), each event line
    `<uptime seconds> <text>` printed where it falls
profan.py oct <a.bin> <b.bin>             the octaver pairs' counters"""
import struct, sys
NAMES = ['ring', 'cmd', 'dub', 'setup', 'loop1', 'jobs_cb', 'join', 'postjobs', 'loop2',
         'meters', 'tail', 'PROCESS', 'out_wall', 'out_cpu', 'in_cpu',
         'SERVICE', 'l1_max', 'in_flt', 'out_flt', 'in_ivcs', 'out_ivc', 'ncmd', 'l1_at',
         'cb_job', 'wk_job', 'wk_wake']
PER_CALL, N, BINS, TAILN = 23, 26, 4096, 32768
HIST0, TAIL0, REC = 204, 426192, 104
OCT0 = TAIL0 + TAILN * REC
SVC = 15; COUNTS = range(17, 23)
def load(p):
    b = open(p, 'rb').read()
    magic, sec, bins, cap = struct.unpack_from('<4I', b, 0)
    assert magic == 0x31393134 and sec == N and bins == BINS and cap == TAILN, (hex(magic), sec, bins, cap)
    tail_ns, calls, tail_n = struct.unpack_from('<3Q', b, 16)
    h = [struct.unpack_from(f'<{BINS}I', b, HIST0 + k * BINS * 4) for k in range(N)]
    return b, calls, tail_n, h
def pct(h, q):
    tot = sum(h)
    if tot == 0: return float('nan')
    want = q / 100 * tot; c = 0
    for i, v in enumerate(h):
        c += v
        if c >= want: return i + 0.5
    return BINS
def mean(h):
    tot = sum(h); return sum((i + 0.5) * v for i, v in enumerate(h)) / tot if tot else float('nan')
def recs(a, b):
    _, _, na, _ = load(a); bb, _, nb, _ = load(b)
    out = []
    for i in range(max(na, nb - TAILN), nb):
        at, fr, *ns = struct.unpack_from(f'<QI{PER_CALL}I', bb, TAIL0 + (i % TAILN) * REC)
        out.append((at, fr, ns))
    return out
def row(ns):
    return ' '.join(f'{v:7d}' if k in COUNTS else f'{v / 1000:7.1f}' for k, v in enumerate(ns))
mode = sys.argv[1]
if mode == 'hist':
    rows = []
    for spec in sys.argv[2:]:
        lab, ab = spec.split('='); a, b = ab.split(':')
        _, ca, _, ha = load(a); _, cb, _, hb = load(b)
        rows.append((lab, cb - ca, [[y - x for x, y in zip(ha[k], hb[k])] for k in range(N)]))
    print(f"{'section':10s} " + ' '.join(f'{lab:>34s}' for lab, _, _ in rows))
    print(f"{'':10s} " + ' '.join(f"{'mean   p50   p99 p99.9 p99.99':>34s}" for _ in rows))
    for k in range(N):
        cells = []
        for lab, calls, d in rows:
            h = d[k]
            if k in COUNTS:
                h2 = list(h); m = sum(i * v for i, v in enumerate(h2)) / max(1, sum(h2))
                cells.append(f'mean {m:.4f} nonzero {sum(h2[1:])} max {max((i for i, v in enumerate(h2) if v), default=0)}')
            else:
                cells.append(f'{mean(h):6.1f}{pct(h,50)-0.5:6.0f}{pct(h,99)-0.5:6.0f}{pct(h,99.9)-0.5:6.0f}{pct(h,99.99)-0.5:7.0f}' + (f' n{sum(h)//1000}k' if k >= PER_CALL else '     '))
        print(f'{NAMES[k]:10s} ' + ' '.join(f'{c:>34s}' for c in cells))
    for lab, calls, d in rows:
        print(f'{lab}: callbacks {calls}, service over 667 us: {sum(d[SVC][667:])}, over 513 (77 %): {sum(d[SVC][513:])}, process over 667: {sum(d[11][667:])}')
elif mode == 'tail':
    r = recs(sys.argv[2], sys.argv[3]); lim = int(sys.argv[4]) if len(sys.argv) > 4 else 60
    print(f'{len(r)} tail records')
    print('at_s         fr ' + ' '.join(f'{n[:7]:>7s}' for n in NAMES[:PER_CALL]))
    t0 = r[0][0] if r else 0
    for at, fr, ns in sorted(r, key=lambda x: -x[2][SVC])[:lim]:
        print(f'{at / 1e9:12.3f} {fr:3d} ' + row(ns))
    if r:
        print('mean             ' + ' '.join(f'{sum(x[2][k] for x in r) / len(r) / (1 if k in COUNTS else 1000):7.1f}' for k in range(PER_CALL)))
elif mode == 'oct':
    # The octaver family's pairs (le_oct_run_pair) between the snapshots.
    a = struct.unpack_from('<11Q', load(sys.argv[2])[0], OCT0)
    b = struct.unpack_from('<11Q', load(sys.argv[3])[0], OCT0)
    d = [y - x for x, y in zip(a, b)]
    print(f'samples on both channels {d[0]}, on the left alone {d[1]}; tries '
          f'equal {d[2]}, differing {d[3:9]}; mono runs a stereo sample ended '
          f'{d[10]}')
else:
    r = recs(sys.argv[2], sys.argv[3]); ms = float(sys.argv[5]) if len(sys.argv) > 5 else 250
    ev = []
    for ln in open(sys.argv[4]):
        t, _, txt = ln.strip().partition(' ')
        try: ev.append((float(t), txt))
        except ValueError: pass
    bins = {}
    for at, fr, ns in r:
        bins.setdefault(int(at / 1e6 // ms), []).append(ns)
    keys = sorted(set(bins) | {int(t * 1000 // ms) for t, _ in ev})
    print(f'bin start s  n>500 n>667  max   | mean of slow records: ' + ' '.join(f'{n[:7]:>7s}' for n in NAMES[:PER_CALL]))
    ei = 0; ev.sort()
    for k in keys:
        while ei < len(ev) and ev[ei][0] * 1000 < (k + 1) * ms:
            print(f'{ev[ei][0]:12.3f}  ---- {ev[ei][1]}'); ei += 1
        b = bins.get(k)
        if not b: continue
        over = sum(1 for ns in b if ns[SVC] > 666700); mx = max(ns[SVC] for ns in b) / 1000
        m = [sum(ns[j] for ns in b) / len(b) for j in range(PER_CALL)]
        print(f'{k * ms / 1000:12.3f} {len(b):5d} {over:5d} {mx:6.0f} | ' + ' '.join(f'{v:7.2f}' if j in COUNTS else f'{v / 1000:7.1f}' for j, v in enumerate(m)))
