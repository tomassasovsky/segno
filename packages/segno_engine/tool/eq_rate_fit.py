#!/usr/bin/env python3
"""Generates src/core/engine_fx_eq_rate.inc: per-rate corrections that make
the EQ kind's bands reproduce the Looper X's 48 kHz responses at 44.1 and
96 kHz (#1436).

The EQ's bands are measured at 48 kHz (docs/plan/2026-10-23-looperx-eq-
measured.md). At another rate the same design differs near the top of the
band, where the 48 kHz response is compressed toward its 24 kHz Nyquist
frequency. For each band shape and each point of a grid over its
parameters, this fits one biquad at the running rate to the 48 kHz
magnitude response over 20 Hz to 20 kHz, and stores the difference between
its coefficients and the plain design the engine computes at that rate
(le_eq_band_design). The engine adds the interpolated difference when it
designs a band, so a correction costs a table lookup and no fitting.

How each fit stays valid:
- The fitted filter is a 2nd-order analog prototype, bilinear at the running
  rate, whose numerator and denominator squared magnitudes are each
  (a - b v)^2 + c v with v the squared prewarped frequency and a, b, c > 0.
  That is nonnegative at every frequency, so every fit is realizable as a
  stable, minimum-phase biquad. (A free least-squares fit of the squared
  magnitude, tried first, often was not.)
- It minimises the largest dB error by least squares reweighted toward the
  worst points, from several starts: the plain design, the plain design
  with its zeros moved to 24 kHz, and the neighbouring grid points' fits.
- A fit is judged on a grid eight times denser than the one it is fitted
  on, so a notch or peak between the fitting points counts. A grid point
  keeps the plain design (no correction) unless its fit beats it.
- Above 24 kHz (at 96 kHz) the 48 kHz response says nothing. A fit is
  penalised there for rising more than 3 dB above the larger of the 48 kHz
  response at 24 kHz and at 20 kHz (for the high cut, at least -15 dB), and
  rejected past 6 dB (ultra_cap) unless the plain design is already that
  high there, so a correction never boosts or rings in the ultrasonic band
  (checked up to the Nyquist frequency). Between 20 and 24 kHz, outside the
  scored band, it is rejected for rising 3 dB above both the 48 kHz
  response and the plain design.
- After the grid is built, the corrections around any cell where the
  interpolated design, at 27 points inside the cell, is worse than the
  plain design by more than 0.1 dB, or breaks that bound, are dropped
  (prune), until none is.

Usage: python3 eq_rate_fit.py > ../src/core/engine_fx_eq_rate.inc
(needs numpy and scipy; takes a few minutes).
"""
import sys
import numpy as np
from scipy.optimize import least_squares

RATES = (44100, 96000)
NF = 64  # fit points, 20 Hz to 20 kHz (or 0.49 fs)
NE = 480  # scoring points: a fit is judged where it was not fitted too
NU = 64  # points from 24 kHz to the Nyquist frequency, for the bound there
MARGIN = 0.9999  # how close to the stability edge a correction may move a pole

# The grids: (shape, log f0 range and points per octave, Q range and count,
# gain range and count). Shapes as le_eq_band_design: 'bell', 'hs' (the
# high shelf), 'lp' and 'hp' (the cuts, Q 1/sqrt(2)). The low shelf (at
# most 1 kHz) needs none: its plain design is within 0.15 dB at 96 kHz; nor
# do bells below 100 Hz (within 0.04 dB).
GRIDS = {
    'bell': dict(f=(100.0, 20000.0, 6), q=(0.4, 10.0, 9), g=(-18.0, 18.0, 13)),
    'hs': dict(f=(1200.0, 20000.0, 6), q=(0.4, 10.0, 9), g=(-18.0, 18.0, 13)),
    'lp': dict(f=(120.0, 20000.0, 12), q=(0.70710678118654752,) * 2 + (1,), g=(0.0, 0.0, 1)),
    'hp': dict(f=(20.0, 8000.0, 12), q=(0.70710678118654752,) * 2 + (1,), g=(0.0, 0.0, 1)),
}


def design(shape, hz, db, q, sr):
    """The engine's plain design (engine_fx.c le_eq_bell / le_eq_design)."""
    hz = min(hz, 0.49 * sr)
    w0 = 2 * np.pi * hz / sr
    cw, sw = np.cos(w0), np.sin(w0)
    if shape == 'bell':
        k = np.sin(0.5 * w0) / q
        v = 10 ** (abs(db) / 20)
        num = np.array([1 + v * k, -2 * cw, 1 - v * k])
        den = np.array([1 + k, -2 * cw, 1 - k])
        if db < 0:
            num, den = den, num
    else:
        al = sw / (2 * q)
        A = 10 ** (db / 40)
        sa = 2 * np.sqrt(A) * al
        if shape == 'hs':
            num = np.array([A * ((A + 1) + (A - 1) * cw + sa), -2 * A * ((A - 1) + (A + 1) * cw),
                            A * ((A + 1) + (A - 1) * cw - sa)])
            den = np.array([(A + 1) - (A - 1) * cw + sa, 2 * ((A - 1) - (A + 1) * cw), (A + 1) - (A - 1) * cw - sa])
        elif shape == 'ls':
            num = np.array([A * ((A + 1) - (A - 1) * cw + sa), 2 * A * ((A - 1) - (A + 1) * cw),
                            A * ((A + 1) - (A - 1) * cw - sa)])
            den = np.array([(A + 1) + (A - 1) * cw + sa, -2 * ((A - 1) + (A + 1) * cw), (A + 1) + (A - 1) * cw - sa])
        elif shape == 'lp':
            num = np.array([(1 - cw) / 2, 1 - cw, (1 - cw) / 2])
            den = np.array([1 + al, -2 * cw, 1 - al])
        else:  # hp
            num = np.array([(1 + cw) / 2, -(1 + cw), (1 + cw) / 2])
            den = np.array([1 + al, -2 * cw, 1 - al])
    return np.array([num[0], num[1], num[2], den[1], den[2]]) / den[0]


def mag_db(c, f, sr):
    z = np.exp(-1j * 2 * np.pi * f / sr)
    h = (c[0] + c[1] * z + c[2] * z * z) / (1 + c[3] * z + c[4] * z * z)
    return 20 * np.log10(np.maximum(np.abs(h), 1e-15))


def uof(f, sr):
    return np.tan(np.pi * f / sr)


def amag_db(x, v):
    an, bn, cn, bd, cd = np.exp(x)
    num = (an - bn * v) ** 2 + cn * v
    den = (1.0 - bd * v) ** 2 + cd * v
    return 10 * np.log10(np.maximum(num / den, 1e-30))


def to_digital(x):
    an, bn, cn, bd, cd = np.exp(x)
    c0, c1, c2 = an, np.sqrt(cn), bn
    d0, d1, d2 = 1.0, np.sqrt(cd), bd
    a0 = d0 + d1 + d2
    return np.array([(c0 + c1 + c2) / a0, 2 * (c0 - c2) / a0, (c0 - c1 + c2) / a0,
                     2 * (d0 - d2) / a0, (d0 - d1 + d2) / a0])


def from_digital(c):
    b0, b1, b2, a1, a2 = c
    d0 = (1 + a1 + a2) / 4
    d2 = (1 - a1 + a2) / 4
    d1 = (1 - a2) / 2
    c0 = (b0 + b1 + b2) / 4
    c2 = (b0 - b1 + b2) / 4
    c1 = (b0 - b2) / 2
    v = np.array([abs(c0 / d0), abs(c2 / d0), max((c1 / d0) ** 2, 1e-12), abs(d2 / d0), max((d1 / d0) ** 2, 1e-12)])
    return np.log(np.maximum(v, 1e-12))


def target(shape, f0, db, q, sr, n=NF):
    f = np.geomspace(20.0, min(20000.0, 0.49 * sr), n)
    t = mag_db(design(shape, f0, db, q, 48000), f, 48000)
    sel = t > -40.0  # below -40 dB the 48 kHz response is not worth matching
    return f[sel], t[sel]


def score(c, shape, f0, db, q, sr):
    """The largest dB error of design c against the 48 kHz response, on the
    dense scoring grid."""
    f, t = target(shape, f0, db, q, sr, NE)
    return np.abs(mag_db(c, f, sr) - t).max()


def guarded(plain, d):
    """plain + s * d with the largest s in [0, 1] that keeps the poles inside
    the region |a2| <= MARGIN, |a1| <= MARGIN (1 + a2), or no further out
    than the plain design's where that is already past it. Each bound is
    linear in s, so s, and the design, move continuously with the settings
    (le_eq_rate_correct does the same)."""
    a1, a2 = plain[3], plain[4]
    da1, da2 = d[3], d[4]
    s = 1.0
    for g0, dg in ((a2 - MARGIN, da2), (-a2 - MARGIN, -da2),
                   (a1 - MARGIN * (1 + a2), da1 - MARGIN * da2),
                   (-a1 - MARGIN * (1 + a2), -da1 - MARGIN * da2)):
        bound = max(0.0, g0)
        if dg > 0:
            s = min(s, (bound - g0) / dg)
    return plain + max(s, 0.0) * d


def guide(shape, f0, db, q, sr):
    """Above 24 kHz (at rates that have it) the 48 kHz response says
    nothing; these points keep the fit from rising there (fit()), so the
    ultrasonic band is neither boosted nor resonant."""
    if sr <= 48000:
        return np.zeros(0), np.zeros(0)
    f = np.linspace(24000.0, 0.45 * sr, 8)  # (fit(); ultrasonic_ok checks to Nyquist)
    t48 = mag_db(design(shape, f0, db, q, 48000), np.array([23990.0]), 48000)[0]
    return f, np.full(len(f), max(t48, -40.0))


def fit(shape, f0, db, q, sr, neighbours):
    f, t = target(shape, f0, db, q, sr)
    plain = design(shape, f0, db, q, sr)
    e_plain = score(plain, shape, f0, db, q, sr)
    fg, tg = guide(shape, f0, db, q, sr)
    cap = ultra_cap(shape, t, tg) - 3.0  # where the penalty starts
    v = uof(f, sr) ** 2
    vg = uof(fg, sr) ** 2

    def residual(y, w):
        r = w * (amag_db(y, v) - t)
        if len(fg) and shape != 'lp':  # a low-pass fit falls there anyway
            r = np.concatenate([r, np.maximum(amag_db(y, vg) - cap, 0.0)])
        return r
    xp = from_digital(plain)
    xz = xp.copy()  # the plain design with its zeros at 24 kHz
    xz[1] = xz[0] - np.log(uof(24000.0, sr) ** 2)
    xz[2] = np.log(1e-8)
    best = (e_plain, plain)
    for x0 in [xp, xz] + list(neighbours):
        w = np.ones(len(f))
        x = np.array(x0, float)
        for _ in range(4):
            r = least_squares(lambda y: residual(y, w), x, method='lm', max_nfev=600)
            x = r.x
            e = np.abs(amag_db(x, v) - t)
            w = w * (1 + e / (e.max() + 1e-12))
        c = to_digital(x)
        e = score(c, shape, f0, db, q, sr)
        if len(fg) and not ultrasonic_ok(shape, sr, c, f0, db, q):
            continue  # it would boost or ring above 24 kHz
        if e < best[0] - 1e-4:
            best = (e, c)
    return best[1] - plain, best[1], best[0], e_plain


def axes(shape):
    g = GRIDS[shape]
    f_lo, f_hi, per_oct = g['f']
    nf = int(round(np.log2(f_hi / f_lo) * per_oct)) + 1
    return (np.linspace(np.log(f_lo), np.log(f_hi), nf),
            np.linspace(np.log(g['q'][0]), np.log(g['q'][1]), int(g['q'][2])),
            np.linspace(g['g'][0], g['g'][1], int(g['g'][2])))


def build(shape, sr):
    lf, lq, gs = axes(shape)
    D = np.zeros((len(lf), len(lq), len(gs), 5))
    X = {}
    worst = 0.0
    for i, a in enumerate(lf):
        for j, b in enumerate(lq):
            for k, g in enumerate(gs):
                nb = [X[n] for n in ((i - 1, j, k), (i, j - 1, k), (i, j, k - 1)) if n in X]
                d, c, e, _ = fit(shape, np.exp(a), g, np.exp(b), sr, nb)
                D[i, j, k] = d
                X[(i, j, k)] = from_digital(c)
                worst = max(worst, e)
        print('  %s %d: f0 %.0f Hz done (worst on the grid %.3f dB)' % (shape, sr, np.exp(a), worst), file=sys.stderr)
    prune(shape, sr, (lf, lq, gs), D)
    return (lf, lq, gs), D


def corrected(shape, sr, axes_, D, f0, q, g):
    """The engine's design at these settings: the plain design plus the
    interpolated correction (le_eq_rate_correct)."""
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
    return guarded(design(shape, f0, g, q, sr), d)


def ultra_cap(shape, t, tg):
    """The most a corrected band may rise to above 24 kHz: 6 dB over the
    larger of the 48 kHz response at 24 kHz and at 20 kHz; for the high cut,
    which falls toward its 24 kHz zero, at least -9 dB (still a cut)."""
    top = max(float(tg.max()) if len(tg) else -1e9, float(t[-1]))
    if shape == 'lp':
        top = max(top, -15.0)
    return top + 6.0


def ultrasonic_ok(shape, sr, c, f0, g, q):
    """Whether design c stays, above the scored band, under its bound: from
    20 to 24 kHz, 3 dB over the larger of the 48 kHz response and the plain
    design; from 24 kHz to the Nyquist frequency, under ultra_cap or the
    plain design where that is higher."""
    if sr <= 48000:
        return True
    f, t = target(shape, f0, g, q, sr)
    fg, tg = guide(shape, f0, g, q, sr)
    fb = np.linspace(20000.0, 23990.0, 24)
    plain = design(shape, f0, g, q, sr)
    lim = np.maximum(mag_db(design(shape, f0, g, q, 48000), fb, 48000), mag_db(plain, fb, sr)) + 3.0
    if np.any(mag_db(c, fb, sr) > lim):
        return False
    fu = np.linspace(24000.0, 0.5 * sr, NU)  # to the Nyquist frequency itself
    own = mag_db(plain, fu, sr)
    return bool(np.all(mag_db(c, fu, sr) <= np.maximum(own, ultra_cap(shape, t, tg)) + 0.01))


def prune(shape, sr, axes_, D):
    """Drops the corrections around any cell where the design the engine
    runs (the plain design plus the interpolated correction), at 27 points
    inside the cell, is more than 0.1 dB worse than the plain design on the
    dense scoring grid, or rises past the bound above 24 kHz; until no cell
    does."""
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
                            for e in (fr if len(gs) > 1 else (0.0,)):
                                f0 = np.exp(lf[i] + a * (lf[i + 1] - lf[i]))
                                q = np.exp(lq[j] + b * (lq[j + 1] - lq[j])) if len(lq) > 1 else np.exp(lq[0])
                                g = gs[k] + e * (gs[k + 1] - gs[k]) if len(gs) > 1 else gs[0]
                                c = corrected(shape, sr, axes_, D, f0, q, g)
                                plain = design(shape, f0, g, q, sr)
                                if (score(c, shape, f0, g, q, sr) > score(plain, shape, f0, g, q, sr) + 0.1
                                        or not ultrasonic_ok(shape, sr, c, f0, g, q)):
                                    bad = True
                                    break
                            if bad:
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


def main():
    out = sys.stdout
    out.write('/* Generated by tool/eq_rate_fit.py (#1436): do not edit.\n'
              ' *\n'
              ' * Per-rate coefficient corrections for the EQ kind\'s bands, so each\n'
              ' * band reproduces its 48 kHz response at the running rate. Indexed\n'
              ' * [f0][q][gain][b0 b1 b2 a1 a2], on the axes each table names: ln f0 and\n'
              ' * ln Q from their first value in equal steps, gain in dB likewise. */\n\n')
    for sr in RATES:
        for shape in GRIDS:
            (lf, lq, gs), D = build(shape, sr)
            name = 'LE_EQR_%s_%d' % (shape.upper(), sr)
            out.write('static const le_eq_rate_table %s = {\n' % name)
            out.write('    %d, %d, %d,\n' % (len(lf), len(lq), len(gs)))
            out.write('    %.9g, %.9g, %.9g, %.9g, %.9g, %.9g,\n' % (
                lf[0], (lf[-1] - lf[0]) / max(len(lf) - 1, 1), lq[0],
                (lq[-1] - lq[0]) / max(len(lq) - 1, 1), gs[0], (gs[-1] - gs[0]) / max(len(gs) - 1, 1)))
            out.write('    (const float[]){\n')
            flat = D.reshape(-1)
            for s in range(0, len(flat), 5):
                out.write('        ' + ', '.join(('%.6g' % v if abs(v) > 1e-9 else '0') for v in flat[s:s + 5]) + ',\n')
            out.write('    }};\n\n')
    out.flush()


if __name__ == '__main__':
    main()
