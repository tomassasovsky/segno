#!/usr/bin/env python3
"""Generates src/core/engine_fx_rate.inc: per-rate corrections that make the
effect kinds' filters reproduce their 48 kHz responses at 44.1 kHz (#1547),
as tool/eq_rate_fit.py does for the EQ kind's bands (#1436). At 96 kHz the
engine runs the 48 kHz designs on alternate samples and needs no table.

The kinds are fitted to the Looper X at 48 kHz, and their filters are
bilinear designs at the running rate. Near the top of the band the 48 kHz
response is compressed toward its 24 kHz Nyquist frequency, so at 44.1 kHz
the same design runs darker there (the effects matrix, #1547). This fits,
over a grid of each filter's settings, what to change at 44.1 kHz so it
matches its 48 kHz response from 20 Hz to FIT_TOP, in the same way as
eq_rate_fit.py (whose fitting machinery it reuses):

- 'lpq', 'hpq': the RBJ low- and high-pass (le_eq_design's cuts) over their
  corner and Q, where the EQ's 'lp' and 'hp' tables hold Q 1/sqrt(2) only.
- 'lp1', 'hp1': the bilinear one-pole low- and high-pass (le_prewarp's
  corner), fitted as a biquad: the kinds run them as biquads.
  These four store, like the EQ's tables, how the fitted biquad's
  coefficients differ from the plain design.
- 'ladder': the LPF kind's four-pole ladder, linear (its feedback k below
  oscillation), over its corner and k. A ladder is not one biquad, so this
  fits a correction biquad that runs after it, and stores the correction's
  own coefficients (the identity where none is needed).

The bells and high shelves the kinds use are already covered by the EQ's
'bell' and 'hs' tables (an RBJ peak is a bell at another Q; le_rate_design
converts it).

Usage: python3 rate_fit.py > ../src/core/engine_fx_rate.inc
(needs numpy and scipy).
"""
import sys

import numpy as np
from scipy.optimize import least_squares

import eq_rate_fit as eq

RATES = (44100,)
# The fits stop at the top of the effects matrix's highest band (the 16 kHz
# third, 18.1 kHz). Above it a 44.1 kHz design falls into its zeros at
# 22.05 kHz faster than one biquad can follow the 48 kHz response: chasing
# it to 20 kHz left the ladder's correction 2 dB short at 16 kHz, and the
# low-pass's fits near the top on separate branches, whose interpolation
# pruned most of its table.
FIT_TOP = 18100.0
CONTINUITY_DB = 0.05  # how much better another start must be (fit())
TAME_DB = 12.0  # the most a ladder's correction may add anywhere (tame())
NE = eq.NE

GRIDS = {
    'lpq': dict(f=(120.0, 23520.0, 24), q=(0.1, 2.0, 19), g=(0.0, 0.0, 1)),
    'hpq': dict(f=(20.0, 8000.0, 12), q=(0.3, 2.0, 7), g=(0.0, 0.0, 1)),
    'lp1': dict(f=(100.0, 20000.0, 12), q=(0.70710678118654752,) * 2 + (1,), g=(0.0, 0.0, 1)),
    'hp1': dict(f=(20.0, 8000.0, 12), q=(0.70710678118654752,) * 2 + (1,), g=(0.0, 0.0, 1)),
    'ladder': dict(f=(20.0, 20000.0, 24), q=(0.2, 3.99, 17), g=(0.0, 0.0, 1)),
}
# How much worse than the plain design the interpolated design may be
# between grid points before prune drops the corrections around it: the
# effects matrix's tolerance (eq_rate_fit.py's 0.1 dB is for the EQ's bells;
# a cut's correction near the top of the band is many dB, and varies too
# fast across a cell for that). A dropped grid point leaves its other cells
# between a fit and the plain design, often worse than either, so a tighter
# bound cascaded through most of the low-pass's table.
PRUNE_DB = 1.0


def prewarp(hz, sr):
    """le_prewarp: tan(pi hz / sr), the corner held under 0.45 of the rate."""
    return np.tan(np.pi * min(hz, 0.45 * sr) / sr)


def onepole(high, hz, sr):
    k = prewarp(hz, sr)
    b0 = 1.0 / (1.0 + k) if high else k / (1.0 + k)
    return np.array([b0, -b0 if high else b0, 0.0, (k - 1.0) / (k + 1.0), 0.0])


def design(shape, hz, db, q, sr):
    """The engine's plain design of [shape] (le_rate_design)."""
    if shape == 'lpq':
        return eq.design('lp', hz, 0.0, q, sr)
    if shape == 'hpq':
        return eq.design('hp', hz, 0.0, q, sr)
    if shape == 'lp1':
        return onepole(False, hz, sr)
    if shape == 'hp1':
        return onepole(True, hz, sr)
    if shape == 'ladder':
        return np.array([1.0, 0.0, 0.0, 0.0, 0.0])  # the correction's identity
    return eq.design(shape, hz, db, q, sr)


def ladder_db(hz, k, f, sr):
    """The LPF kind's ladder, linear, at [sr]: four bilinear one-poles at
    [hz] in a loop of gain [k], its input scaled by 1 + k (fx_lpf_kprocess)."""
    g = prewarp(hz, sr)
    z = np.exp(-1j * 2 * np.pi * f / sr)
    h1 = g * (1 + z) / ((1 + g) + (g - 1) * z)
    h4 = h1 ** 4
    h = (1 + k) * h4 / (1 + k * h4)
    return 20 * np.log10(np.maximum(np.abs(h), 1e-15))


def target(shape, f0, db, q, sr, n=eq.NF):
    """What the filter at [sr] should read: its 48 kHz response; for the
    ladder, what its correction should add to the ladder at [sr]."""
    f = np.geomspace(20.0, min(FIT_TOP, 0.49 * sr), n)
    if shape == 'ladder':
        t48 = ladder_db(f0, q, f, 48000)
        sel = t48 > -40.0
        return f[sel], t48[sel] - ladder_db(f0, q, f[sel], sr)
    t = eq.mag_db(design(shape, f0, db, q, 48000), f, 48000)
    sel = t > -40.0
    return f[sel], t[sel]


def score(c, shape, f0, db, q, sr):
    f, t = target(shape, f0, db, q, sr, NE)
    return np.abs(eq.mag_db(c, f, sr) - t).max() if len(f) else 0.0


def tame(c, sr):
    """Whether a ladder's correction is one to run on a swept, possibly
    oscillating filter: its poles well inside the unit circle (radius at
    most 0.97) and its gain nowhere above +12 dB up to the Nyquist
    frequency."""
    if abs(c[4]) > 0.94 or abs(c[3]) > 1.0 + c[4] - 0.03:
        return False
    f = np.linspace(10.0, 0.5 * sr, 256)
    return bool(np.all(eq.mag_db(c, f, sr) <= TAME_DB))


def fit(shape, f0, db, q, sr, neighbours):
    f, t = target(shape, f0, db, q, sr)
    plain = design(shape, f0, db, q, sr)
    if len(f) < 4:
        return np.zeros(5), plain, 0.0, 0.0
    e_plain = score(plain, shape, f0, db, q, sr)
    v = eq.uof(f, sr) ** 2

    # The ladder's correction, above the fit and up to the Nyquist frequency:
    # held a little under tame()'s +12 dB, or the fit runs its poles out to it.
    vt = eq.uof(np.linspace(min(FIT_TOP, 0.45 * sr), 0.499 * sr, 16), sr) ** 2

    def residual(y, w):
        r = w * (eq.amag_db(y, v) - t)
        if shape == 'ladder':
            r = np.concatenate([r, 10.0 * np.maximum(eq.amag_db(y, vt) - (TAME_DB - 0.2), 0.0)])
        return r
    starts = list(neighbours)
    if shape != 'ladder':
        xp = eq.from_digital(plain)
        xz = xp.copy()  # the plain design with its zeros at 24 kHz
        xz[1] = xz[0] - np.log(eq.uof(24000.0, sr) ** 2)
        xz[2] = np.log(1e-8)
        starts = [xp, xz] + starts
    else:
        # the identity, and a gentle shelf either way
        starts = [np.log([1.0, 1e-3, 2.0, 1e-3, 2.0]), np.log([1.0, 0.5, 2.0, 1.0, 2.0]),
                  np.log([1.0, 1.0, 2.0, 0.5, 2.0])] + starts
    first_nb = len(starts) - len(neighbours)
    best = (e_plain, plain)
    best_nb = (np.inf, plain)
    for si, x0 in enumerate(starts):
        w = np.ones(len(f))
        x = np.array(x0, float)
        try:
            for _ in range(4):
                r = least_squares(lambda y: residual(y, w), x, method='lm', max_nfev=600)
                x = r.x
                e = np.abs(eq.amag_db(x, v) - t)
                w = w * (1 + e / (e.max() + 1e-12))
        except (ValueError, FloatingPointError):
            continue
        c = eq.to_digital(x)
        if not np.all(np.isfinite(c)):
            continue
        e = score(c, shape, f0, db, q, sr)
        if shape == 'ladder' and not tame(c, sr):
            continue
        if e < best[0] - 1e-4:
            best = (e, c)
        if si >= first_nb and e < best_nb[0]:
            best_nb = (e, c)
    # A fit from a neighbour's solution stays on its branch, so the grid
    # interpolates smoothly between them: it is kept unless another start
    # is clearly better.
    if best_nb[0] <= best[0] + CONTINUITY_DB and best_nb[0] < e_plain - 1e-4:
        best = best_nb
    return best[1] - plain, best[1], best[0], e_plain


def axes(shape):
    g = GRIDS[shape]
    f_lo, f_hi, per_oct = g['f']
    nf = int(round(np.log2(f_hi / f_lo) * per_oct)) + 1
    return (np.linspace(np.log(f_lo), np.log(f_hi), nf),
            np.linspace(np.log(g['q'][0]), np.log(g['q'][1]), int(g['q'][2])),
            np.linspace(g['g'][0], g['g'][1], int(g['g'][2])))


def corrected(shape, sr, axes_, D, f0, q, g):
    idx, wts = [], []
    for ax, val in zip(axes_, (np.log(f0), np.log(q), g)):
        if len(ax) < 2:
            idx.append(0)
            wts.append(0.0)
            continue
        u = np.clip((val - ax[0]) / (ax[1] - ax[0]), 0, len(ax) - 1)
        k = min(int(u), len(ax) - 2)
        idx.append(k)
        wts.append(u - k)
    d = np.zeros(5)
    for corner in range(8):
        ii, w = [], 1.0
        for axis in range(3):
            hi = (corner >> axis) & 1
            n = len(axes_[axis])
            ii.append(idx[axis] + (hi if n > 1 else 0))
            w *= wts[axis] if hi else 1 - wts[axis]
        if w:
            d += w * D[tuple(ii)]
    return eq.guarded(design(shape, f0, g, q, sr), d)


def prune(shape, sr, axes_, D):
    """eq_rate_fit.prune: drop the corrections around any cell where the
    interpolated design, at the points inside it, is more than PRUNE_DB
    worse than the plain design."""
    lf, lq, gs = axes_
    rng = [range(max(len(ax) - 1, 1)) for ax in axes_]
    fr = (0.25, 0.5, 0.75)
    for _ in range(30):
        dropped = 0
        for i in rng[0]:
            for j in rng[1]:
                for k in rng[2]:
                    corners = [(i + (c & 1) * (len(lf) > 1), j + ((c >> 1) & 1) * (len(lq) > 1),
                                k + ((c >> 2) & 1) * (len(gs) > 1)) for c in range(8)]
                    if not any(np.any(D[ii]) for ii in corners):
                        continue
                    bad = False
                    for a in fr:
                        for b in (fr if len(lq) > 1 else (0.0,)):
                            f0 = np.exp(lf[i] + a * (lf[i + 1] - lf[i]))
                            q = np.exp(lq[j] + b * (lq[j + 1] - lq[j])) if len(lq) > 1 else np.exp(lq[0])
                            c = corrected(shape, sr, axes_, D, f0, q, 0.0)
                            plain = design(shape, f0, 0.0, q, sr)
                            if score(c, shape, f0, 0.0, q, sr) > score(plain, shape, f0, 0.0, q, sr) + PRUNE_DB:
                                bad = True
                                break
                        if bad:
                            break
                    if bad:
                        for ii in corners:
                            if np.any(D[ii]):
                                D[ii] = 0
                                dropped += 1
        print('  %s %d: pruned %d grid points' % (shape, sr, dropped), file=sys.stderr)
        if not dropped:
            break


def build(shape, sr):
    lf, lq, gs = axes(shape)
    D = np.zeros((len(lf), len(lq), len(gs), 5))
    X = {}
    worst = 0.0
    for i, a in enumerate(lf):
        for j, b in enumerate(lq):
            for k, g in enumerate(gs):
                nb = [X[n] for n in ((i - 1, j, k), (i, j - 1, k)) if n in X]
                d, c, e, _ = fit(shape, np.exp(a), g, np.exp(b), sr, nb)
                D[i, j, k] = d
                if np.any(d):
                    X[(i, j, k)] = eq.from_digital(c)
                worst = max(worst, e)
        print('  %s %d: f0 %.0f Hz done (worst %.3f dB)' % (shape, sr, np.exp(a), worst), file=sys.stderr)
    prune(shape, sr, (lf, lq, gs), D)
    return (lf, lq, gs), D


HEADER = ('/* Generated by tool/rate_fit.py (#1547): do not edit.\n'
          ' *\n'
          ' * Per-rate coefficient corrections for the kinds\' filters, so each\n'
          ' * reproduces its 48 kHz response at the running rate, in\n'
          ' * le_eq_rate_table\'s layout. The ladder\'s holds a correction\n'
          ' * biquad\'s own coefficients less the identity. */\n\n')


def table(shape, sr):
    """One shape's table at one rate, as C."""
    (lf, lq, gs), D = build(shape, sr)
    name = 'LE_RF_%s_%d' % (shape.upper(), sr)
    lines = ['static const le_eq_rate_table %s = {' % name,
             '    %d, %d, %d,' % (len(lf), len(lq), len(gs)),
             '    %.9g, %.9g, %.9g, %.9g, %.9g, %.9g,' % (
                 lf[0], (lf[-1] - lf[0]) / max(len(lf) - 1, 1), lq[0],
                 (lq[-1] - lq[0]) / max(len(lq) - 1, 1), gs[0],
                 (gs[-1] - gs[0]) / max(len(gs) - 1, 1)),
             '    (const float[]){']
    flat = D.reshape(-1)
    for s in range(0, len(flat), 5):
        lines.append('        ' + ', '.join(('%.6g' % v if abs(v) > 1e-9 else '0')
                                            for v in flat[s:s + 5]) + ',')
    lines.append('    }};')
    return '\n'.join(lines) + '\n\n'


def main():
    """Every table (slow: run `rate_fit.py SHAPE RATE` for one, in
    parallel, and join them under HEADER in this order)."""
    if len(sys.argv) == 3:
        sys.stdout.write(table(sys.argv[1], int(sys.argv[2])))
        return
    sys.stdout.write(HEADER)
    for sr in RATES:
        for shape in GRIDS:
            sys.stdout.write(table(shape, sr))
            sys.stdout.flush()


if __name__ == '__main__':
    main()
