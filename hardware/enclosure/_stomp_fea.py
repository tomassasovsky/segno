"""Rated-load check for the Segno console shell (issue #1019).

Kirchhoff plate-bending FE, 12-DOF ACM/MZC rectangle.  The shape functions are
DERIVED here from the 12-term polynomial basis rather than transcribed, and
`--selftest` reproduces Timoshenko's simply-supported and clamped square-plate
coefficients (w and M) to three figures, so the element is checkable.

What it answers: how much force a player can put on one pedal, or on the
faceplate, before the 2.0 mm aluminium takes a permanent set.

    python3 _stomp_fea.py --selftest     # element validation only
    python3 _stomp_fea.py                # the full report

Needs numpy + scipy (the enclosure venv has both).  Geometry is kept in sync by
hand with segno_enclosure.py -- FEET, PEDALS and the faceplate cutouts are
printed by the report so a drift is visible.
"""

import numpy as np
import scipy.sparse as sp
import scipy.sparse.linalg as spla

P_POW = [(0, 0), (1, 0), (0, 1), (2, 0), (1, 1), (0, 2),
         (3, 0), (2, 1), (1, 2), (0, 3), (3, 1), (1, 3)]


def _mono(x, y, dx=0, dy=0):
    """Row vector of the 12 monomials (or a derivative of them) at (x, y)."""
    out = np.zeros(12)
    for k, (px, py) in enumerate(P_POW):
        cx = 1.0
        for i in range(dx):
            cx *= (px - i)
        cy = 1.0
        for i in range(dy):
            cy *= (py - i)
        if cx == 0.0 or cy == 0.0:
            continue
        ex, ey = px - dx, py - dy
        out[k] = cx * cy * (x ** ex) * (y ** ey)
    return out


def _elem_C(a, b):
    """A^-1 for a rectangle 2a x 2b centred on its local origin."""
    A = np.zeros((12, 12))
    corners = [(-a, -b), (a, -b), (a, b), (-a, b)]
    for i, (x, y) in enumerate(corners):
        A[3 * i + 0] = _mono(x, y, 0, 0)
        A[3 * i + 1] = _mono(x, y, 1, 0)
        A[3 * i + 2] = _mono(x, y, 0, 1)
    return np.linalg.inv(A)


_GAUSS = {n: np.polynomial.legendre.leggauss(n) for n in (3, 4)}


def elem_k(a, b, Dm, C):
    """12x12 bending stiffness."""
    xg, wg = _GAUSS[4]
    k = np.zeros((12, 12))
    for xi, wxi in zip(xg, wg):
        for eta, weta in zip(xg, wg):
            x, y = a * xi, b * eta
            B = np.vstack([-_mono(x, y, 2, 0) @ C,
                           -_mono(x, y, 0, 2) @ C,
                           -2.0 * _mono(x, y, 1, 1) @ C])
            k += (wxi * weta * a * b) * (B.T @ Dm @ B)
    return k


def elem_f(a, b, C, q, box=None):
    """Consistent nodal load for pressure q over the element, or over the
    axis-aligned sub-rectangle `box` = (x0, x1, y0, y1) in LOCAL coords."""
    x0, x1, y0, y1 = box if box else (-a, a, -b, b)
    if x1 <= x0 or y1 <= y0:
        return np.zeros(12)
    xg, wg = _GAUSS[4]
    hx, cx = (x1 - x0) / 2.0, (x1 + x0) / 2.0
    hy, cy = (y1 - y0) / 2.0, (y1 + y0) / 2.0
    f = np.zeros(12)
    for xi, wxi in zip(xg, wg):
        for eta, weta in zip(xg, wg):
            x, y = cx + hx * xi, cy + hy * eta
            N = _mono(x, y, 0, 0) @ C
            f += (wxi * weta * hx * hy * q) * N
    return f


class Plate:
    def __init__(self, xs, ys, t, E, nu, t_of=None, hole=None):
        # t_of(xc, yc) -> local EQUIVALENT plate thickness, for riveted stiffeners
        # hole(xc, yc) -> True if the element is cut away
        self.t_of = t_of
        self.hole = hole
        self.xs, self.ys = np.asarray(xs, float), np.asarray(ys, float)
        self.nx, self.ny = len(xs) - 1, len(ys) - 1
        self.t, self.E, self.nu = t, E, nu
        self.D = E * t ** 3 / (12.0 * (1.0 - nu ** 2))
        self.Dm = self.D * np.array([[1.0, nu, 0.0], [nu, 1.0, 0.0],
                                     [0.0, 0.0, (1.0 - nu) / 2.0]])
        self.nnode = (self.nx + 1) * (self.ny + 1)
        self.ndof = 3 * self.nnode
        self._cache = {}

    def live(self, i, j):
        if self.hole is None:
            return True
        return not self.hole((self.xs[i] + self.xs[i + 1]) / 2.0,
                             (self.ys[j] + self.ys[j + 1]) / 2.0)

    def live_dofs(self):
        keep = np.zeros(self.nnode, bool)
        for i in range(self.nx):
            for j in range(self.ny):
                if self.live(i, j):
                    for n in (self.nid(i, j), self.nid(i + 1, j),
                              self.nid(i + 1, j + 1), self.nid(i, j + 1)):
                        keep[n] = True
        return np.repeat(keep, 3)

    def nid(self, i, j):
        return i * (self.ny + 1) + j

    def edofs(self, i, j):
        n = [self.nid(i, j), self.nid(i + 1, j),
             self.nid(i + 1, j + 1), self.nid(i, j + 1)]
        return np.array([3 * m + d for m in n for d in range(3)])

    def _te(self, i, j):
        if self.t_of is None:
            return self.t
        return self.t_of((self.xs[i] + self.xs[i + 1]) / 2.0,
                         (self.ys[j] + self.ys[j + 1]) / 2.0)

    def _Dm(self, te):
        D = self.E * te ** 3 / (12.0 * (1.0 - self.nu ** 2))
        return D * np.array([[1.0, self.nu, 0.0], [self.nu, 1.0, 0.0],
                             [0.0, 0.0, (1.0 - self.nu) / 2.0]])

    def _geom(self, i, j):
        a = (self.xs[i + 1] - self.xs[i]) / 2.0
        b = (self.ys[j + 1] - self.ys[j]) / 2.0
        te = self._te(i, j)
        key = (round(a, 9), round(b, 9), round(te, 6))
        if key not in self._cache:
            C = _elem_C(a, b)
            self._cache[key] = (C, elem_k(a, b, self._Dm(te), C))
        return a, b, self._cache[key]

    def assemble(self):
        rows, cols, vals = [], [], []
        for i in range(self.nx):
            for j in range(self.ny):
                if not self.live(i, j):
                    continue
                _, _, (_, ke) = self._geom(i, j)
                ed = self.edofs(i, j)
                rows.append(np.repeat(ed, 12))
                cols.append(np.tile(ed, 12))
                vals.append(ke.ravel())
        K = sp.coo_matrix((np.concatenate(vals),
                           (np.concatenate(rows), np.concatenate(cols))),
                          shape=(self.ndof, self.ndof)).tocsr()
        self.K = K
        return K

    def pressure_on_rect(self, rect, total_force):
        """Nodal force vector: `total_force` spread as uniform pressure over the
        axis-aligned rect (x0, x1, y0, y1) in GLOBAL coords."""
        x0, x1, y0, y1 = rect
        area = (x1 - x0) * (y1 - y0)
        q = -total_force / area          # +z up, load acts downward
        F = np.zeros(self.ndof)
        for i in range(self.nx):
            ex0, ex1 = self.xs[i], self.xs[i + 1]
            if ex1 <= x0 or ex0 >= x1:
                continue
            for j in range(self.ny):
                ey0, ey1 = self.ys[j], self.ys[j + 1]
                if ey1 <= y0 or ey0 >= y1 or not self.live(i, j):
                    continue
                a, b, (C, _) = self._geom(i, j)
                cx, cy = (ex0 + ex1) / 2.0, (ey0 + ey1) / 2.0
                box = (max(ex0, x0) - cx, min(ex1, x1) - cx,
                       max(ey0, y0) - cy, min(ey1, y1) - cy)
                F[self.edofs(i, j)] += elem_f(a, b, C, q, box)
        return F

    def pressure_on_band(self, rect, band, total_force):
        """Load on a `band`-wide perimeter frame of rect (picture-frame bearing)."""
        x0, x1, y0, y1 = rect
        ix0, ix1, iy0, iy1 = x0 + band, x1 - band, y0 + band, y1 - band
        area = (x1 - x0) * (y1 - y0) - max(0.0, ix1 - ix0) * max(0.0, iy1 - iy0)
        q = -total_force / area
        F = np.zeros(self.ndof)
        for i in range(self.nx):
            ex0, ex1 = self.xs[i], self.xs[i + 1]
            if ex1 <= x0 or ex0 >= x1:
                continue
            for j in range(self.ny):
                ey0, ey1 = self.ys[j], self.ys[j + 1]
                if ey1 <= y0 or ey0 >= y1 or not self.live(i, j):
                    continue
                a, b, (C, _) = self._geom(i, j)
                cx, cy = (ex0 + ex1) / 2.0, (ey0 + ey1) / 2.0
                ox0, ox1 = max(ex0, x0), min(ex1, x1)
                oy0, oy1 = max(ey0, y0), min(ey1, y1)
                f = elem_f(a, b, C, q, (ox0 - cx, ox1 - cx, oy0 - cy, oy1 - cy))
                hx0, hx1 = max(ox0, ix0), min(ox1, ix1)
                hy0, hy1 = max(oy0, iy0), min(oy1, iy1)
                if hx1 > hx0 and hy1 > hy0:            # subtract the hole
                    f -= elem_f(a, b, C, q,
                                (hx0 - cx, hx1 - cx, hy0 - cy, hy1 - cy))
                F[self.edofs(i, j)] += f
        return F

    def spring_pads(self, centres, diameter, k_total):
        """Elastic vertical foundation over Ø`diameter` discs.  Returns a sparse
        diagonal added to K, and a per-pad node/weight map for reactions."""
        diag = np.zeros(self.ndof)
        pads = []
        # tributary area per node
        trib = np.zeros(self.nnode)
        for i in range(self.nx + 1):
            dx = ((self.xs[min(i + 1, self.nx)] - self.xs[max(i - 1, 0)]) / 2.0)
            for j in range(self.ny + 1):
                dy = ((self.ys[min(j + 1, self.ny)] - self.ys[max(j - 1, 0)]) / 2.0)
                trib[self.nid(i, j)] = dx * dy
        for (cx, cy) in centres:
            ids, ws = [], []
            for i in range(self.nx + 1):
                if abs(self.xs[i] - cx) > diameter / 2.0:
                    continue
                for j in range(self.ny + 1):
                    if (self.xs[i] - cx) ** 2 + (self.ys[j] - cy) ** 2 > (diameter / 2.0) ** 2:
                        continue
                    ids.append(self.nid(i, j))
                    ws.append(trib[self.nid(i, j)])
            ids, ws = np.array(ids), np.array(ws, float)
            assert len(ids) >= 1, f"pad at {cx},{cy} caught no node"
            ws = ws / ws.sum()
            for n, w in zip(ids, ws):
                diag[3 * n] += k_total * w
            pads.append((ids, ws))
        return sp.diags(diag).tocsr(), pads

    def moments(self, u):
        """Bending moments at every element's 4 corners, averaged per node."""
        Mx = np.zeros(self.nnode); My = np.zeros(self.nnode)
        Mxy = np.zeros(self.nnode); cnt = np.zeros(self.nnode)
        for i in range(self.nx):
            for j in range(self.ny):
                if not self.live(i, j):
                    continue
                a, b, (C, _) = self._geom(i, j)
                ue = u[self.edofs(i, j)]
                for (x, y), n in zip([(-a, -b), (a, -b), (a, b), (-a, b)],
                                     [self.nid(i, j), self.nid(i + 1, j),
                                      self.nid(i + 1, j + 1), self.nid(i, j + 1)]):
                    B = np.vstack([-_mono(x, y, 2, 0) @ C,
                                   -_mono(x, y, 0, 2) @ C,
                                   -2.0 * _mono(x, y, 1, 1) @ C])
                    m = self._Dm(self._te(i, j)) @ (B @ ue)
                    Mx[n] += m[0]; My[n] += m[1]; Mxy[n] += m[2]; cnt[n] += 1
        cnt[cnt == 0] = 1.0
        return Mx / cnt, My / cnt, Mxy / cnt

    def elem_thickness_at_nodes(self):
        te = np.zeros(self.nnode); c = np.zeros(self.nnode)
        for i in range(self.nx):
            for j in range(self.ny):
                if not self.live(i, j):
                    continue
                v = self._te(i, j)
                for n in (self.nid(i, j), self.nid(i + 1, j),
                          self.nid(i + 1, j + 1), self.nid(i, j + 1)):
                    te[n] = max(te[n], v); c[n] += 1
        return te

    def vonmises(self, u):
        Mx, My, Mxy = self.moments(u)
        s = 6.0 / (self.elem_thickness_at_nodes() ** 2
                   if self.t_of is not None else self.t ** 2)
        sx, sy, sxy = s * Mx, s * My, s * Mxy
        return np.sqrt(sx ** 2 - sx * sy + sy ** 2 + 3.0 * sxy ** 2), (sx, sy, sxy)


# =====  BASE PLATE  =========================================================


# ---- geometry (mm) ---------------------------------------------------------
BW, BD = 846.0, 419.0
T = 2.0
E, NU = 68900.0, 0.33          # every Al alloy: E ~ 69 GPa. Temper changes yield, not E.
FOOT_PAD = 18.0                # chassis-face contact diameter
COLLAR = (88.75, 115.37)       # printed pedestal footprint (u, v)
RIM = 3.0                      # PLAT_WALL: the collar bears on a 3 mm perimeter rim

FEET = [(14.3, 45.0), (14.3, 374.0), (831.7, 45.0), (831.7, 374.0),
        (119.57, 66.2), (321.86, 66.2), (524.14, 66.2), (726.43, 66.2),
        (119.57, 374.0), (321.86, 374.0), (524.14, 374.0), (726.43, 374.0),
        (321.86, 229.97), (625.29, 131.44), (726.43, 131.44)]

PEDALS = {"REC/PLAY": (69.0, 66.2), "STOP": (170.14, 66.2),
          "UNDO": (271.29, 66.2), "MODE": (372.43, 66.2),
          "TRACK1": (473.57, 66.2), "TRACK2": (574.71, 66.2),
          "TRACK3": (675.86, 66.2), "TRACK4": (777.0, 66.2),
          "CLEAR": (271.29, 229.97), "BANK": (372.43, 229.97)}


def collar_rect(cu, cv):
    return (cu - COLLAR[0] / 2, cu + COLLAR[0] / 2,
            cv - COLLAR[1] / 2, cv + COLLAR[1] / 2)


def _base_grid(feature, lo, hi, hmax):
    f = sorted({lo, hi} | {v for v in feature if lo < v < hi})
    out = []
    for a, b in zip(f, f[1:]):
        n = max(1, int(np.ceil((b - a) / hmax)))
        out.extend(np.linspace(a, b, n + 1)[:-1])
    out.append(hi)
    return np.array(out)


def base_build(hmax=8.0, feet=FEET):
    fx, fy = set(), set()
    for cx, cy in feet:
        fx.update([cx - FOOT_PAD / 2, cx, cx + FOOT_PAD / 2])
        fy.update([cy - FOOT_PAD / 2, cy, cy + FOOT_PAD / 2])
    for cu, cv in PEDALS.values():
        x0, x1, y0, y1 = collar_rect(cu, cv)
        fx.update([x0, x0 + RIM, x1 - RIM, x1])
        fy.update([y0, y0 + RIM, y1 - RIM, y1])
    xs = _base_grid(fx, 0.0, BW, hmax)
    ys = _base_grid(fy, 0.0, BD, hmax)
    return Plate(xs, ys, T, E, NU), xs, ys


def solve(p, F, feet, k_foot, preload=0.0, verbose=False):
    """Elastic feet, released one at a time if they go into net tension."""
    K = p.assemble()
    active = list(range(len(feet)))
    for _ in range(12):
        Kf, pads = p.spring_pads([feet[i] for i in active], FOOT_PAD, k_foot)
        u = spla.spsolve((K + Kf).tocsc(), F)
        R = []
        for (ids, ws) in pads:
            w = float(np.sum(ws * u[3 * ids]))
            R.append(-k_foot * w)          # + = foot in compression
        R = np.array(R)
        bad = [active[i] for i in np.argsort(R) if R[i] < -preload]
        if not bad:
            return u, dict(zip(active, R))
        active = [i for i in active if i != bad[0]]
        if verbose:
            print(f"    released foot {bad[0]} at {feet[bad[0]]}")
    raise RuntimeError("contact iteration did not settle")


def report(p, u, tag, force):
    vm, (sx, sy, sxy) = p.vonmises(u)
    i = int(np.argmax(vm))
    ix, iy = divmod(i, p.ny + 1)
    return dict(tag=tag, force=force, vm=vm[i],
                at=(round(float(p.xs[ix]), 1), round(float(p.ys[iy]), 1)),
                wmax=float(np.min(u[0::3])), vmfield=vm)


# =====  FACEPLATE  ==========================================================


LW, LV = 849.8, 397.0          # faceplate: width x sloped run

RECTS = []          # (u0, u1, v0, v1)
for u0 in (29.8, 131.0, 232.1, 333.3, 434.4, 535.5, 636.7, 737.8):
    RECTS.append((u0, u0 + 78.35, 12.2, 128.2))
for u0 in (232.1, 333.3):
    RECTS.append((u0, u0 + 78.35, 179.9, 296.0))
for u0 in (39.0, 140.1, 241.3, 342.4, 443.6, 544.7, 645.9, 747.0):
    RECTS.append((u0, u0 + 60.0, 138.6, 144.6))
for u0 in (241.3, 342.4):
    RECTS.append((u0, u0 + 60.0, 306.4, 312.4))
RECTS.append((42.7, 196.4, 285.5, 371.0))       # 7 in
RECTS.append((454.4, 796.2, 179.9, 371.0))      # 15.6 in
RING = (119.6, 229.2, 33.5)                     # encoder ring bore

POSTS = [(625.0, 165.0), (726.0, 165.0)]
POST_PAD = (30.14, 20.0)


def lid_hole(x, y):
    for u0, u1, v0, v1 in RECTS:
        if u0 <= x <= u1 and v0 <= y <= v1:
            return True
    return (x - RING[0]) ** 2 + (y - RING[1]) ** 2 <= RING[2] ** 2


def lid_solid(u0, u1, v0, v1, pad=0.0):
    for a0, a1, b0, b1 in RECTS:
        if u0 - pad < a1 and u1 + pad > a0 and v0 - pad < b1 and v1 + pad > b0:
            return False
    cx, cy, r = RING
    if u0 - pad < cx + r and u1 + pad > cx - r and v0 - pad < cy + r and v1 + pad > cy - r:
        return False
    return True


def _lid_grid(feat, lo, hi, hmax):
    f = sorted({lo, hi} | {v for v in feat if lo < v < hi})
    out = []
    for a, b in zip(f, f[1:]):
        n = max(1, int(np.ceil((b - a) / hmax)))
        out.extend(np.linspace(a, b, n + 1)[:-1])
    out.append(hi)
    return np.array(out)


def lid_build(hmax=8.0, extra_x=(), extra_y=()):
    fx = set(extra_x); fy = set(extra_y)
    for u0, u1, v0, v1 in RECTS:
        fx.update([u0, u1]); fy.update([v0, v1])
    for cu, cv in POSTS:
        fx.update([cu - POST_PAD[0] / 2, cu + POST_PAD[0] / 2])
        fy.update([cv - POST_PAD[1] / 2, cv + POST_PAD[1] / 2])
    fx.update([RING[0] - RING[2], RING[0] + RING[2]])
    fy.update([RING[1] - RING[2], RING[1] + RING[2]])
    xs = _lid_grid(fx, 0.0, LW, hmax); ys = _lid_grid(fy, 0.0, LV, hmax)
    return Plate(xs, ys, T, E, NU, hole=lid_hole), xs, ys


def lid_assemble(p, k_post=2000.0):
    K = p.assemble().tolil()
    live = p.live_dofs()
    fixed = []
    for i in range(p.nx + 1):
        for j in range(p.ny + 1):
            if i in (0, p.nx) or j in (0, p.ny):
                fixed.append(3 * p.nid(i, j))          # skirt ledge: w = 0
    # steel props under the faceplate
    diag = np.zeros(p.ndof)
    for cu, cv in POSTS:
        ids = [p.nid(i, j) for i in range(p.nx + 1) for j in range(p.ny + 1)
               if abs(p.xs[i] - cu) <= POST_PAD[0] / 2 and abs(p.ys[j] - cv) <= POST_PAD[1] / 2]
        for n in ids:
            diag[3 * n] += k_post / len(ids)
    K = (K.tocsr() + sp.diags(diag).tocsr())
    dead = np.where(~live)[0]
    fixed = sorted(set(fixed) | set(dead.tolist()))
    free = np.setdiff1d(np.arange(p.ndof), fixed)
    return K, free


# =====  REPORT  =============================================================
# 1100-H14, lot 26E0269 (Alcast, cert 2026-04-01): Rp0.2 127, Rm 145, A 10%.
# ABNT NBR 7823 minimum for the alloy/temper is 95 MPa -- design to that unless
# every delivery carries a certificate.
YIELD_LOT, YIELD_SPEC, FATIGUE = 127.0, 95.0, 41.0
REF = 1000.0                      # reference stomp; every result scales linearly

DU, DV = 22.188, 48.685           # the pedestal's four EXISTING chassis screws
_F8 = [(u, 66.2) for u in (69.0, 170.14, 271.29, 372.43,
                           473.57, 574.71, 675.86, 777.0)]
_MID = [(271.29, 229.97), (372.43, 229.97)]
FEET_FIXED = FEET + [(u + du, v + dv) for u, v in _F8 + _MID
                     for du in (-DU, DU) for dv in (-DV, DV)]


def selftest():
    """Timoshenko, table 8 (SS) and 35 (clamped): w = a*q L^4/D, M = b*q L^2."""
    E0, nu0, t0, L, q = 70000.0, 0.3, 2.0, 400.0, 0.01
    D0 = E0 * t0 ** 3 / (12 * (1 - nu0 ** 2))
    for bc, wc, mc in (("simply supported", 0.00406, 0.0479),
                       ("clamped", 0.00126, 0.0231)):
        n = 32
        ax = np.linspace(0, L, n + 1)
        p = Plate(ax, ax, t0, E0, nu0)
        K = p.assemble().tolil()
        F = p.pressure_on_rect((0, L, 0, L), q * L * L)
        fixed = []
        for i in range(n + 1):
            for j in range(n + 1):
                ex, ey = i in (0, n), j in (0, n)
                if not (ex or ey):
                    continue
                nd = p.nid(i, j)
                fixed.append(3 * nd)
                if bc == "clamped":
                    if ex: fixed.append(3 * nd + 1)
                    if ey: fixed.append(3 * nd + 2)
                else:
                    if ex: fixed.append(3 * nd + 2)
                    if ey: fixed.append(3 * nd + 1)
        fixed = sorted(set(fixed))
        free = np.setdiff1d(np.arange(p.ndof), fixed)
        K = K.tocsr()
        u = np.zeros(p.ndof)
        u[free] = spla.spsolve(K[free][:, free].tocsc(), F[free])
        c = p.nid(n // 2, n // 2)
        _, (sx, _, _) = p.vonmises(u)
        print(f"  {bc:17s} w {abs(u[3*c]):7.3f} vs {wc*q*L**4/D0:7.3f} mm   "
              f"M {abs(sx[c])*t0**2/6/(q*L*L):.4f} vs {mc:.4f} q L^2")


def _base_case(feet, pedal, kind, force=REF, k_foot=400.0, hmax=8.0):
    p, _, _ = base_build(hmax=hmax, feet=feet)
    K = p.assemble()
    Kf, _pads = p.spring_pads(feet, FOOT_PAD, k_foot)
    cu, cv = PEDALS[pedal]
    x0, x1, y0, y1 = collar_rect(cu, cv)
    if kind == "rim":
        F = p.pressure_on_band((x0, x1, y0, y1), RIM, force)
    elif kind == "area":
        F = p.pressure_on_rect((x0, x1, y0, y1), force)
    else:                                   # toe: resultant pushed forward
        F = p.pressure_on_rect((x0, x1, y0, (y0 + y1) / 2), force)
    u = spla.spsolve((K + Kf).tocsc(), F)
    vm, _s = p.vonmises(u)
    return vm.max(), float(u[0::3].min())


def _lid_case(rect, force, posts=None, hmax=6.0):
    global POSTS
    if posts is not None:
        POSTS = posts
    p, _, _ = lid_build(hmax=hmax)
    K, free = lid_assemble(p)
    F = p.pressure_on_rect(rect, force)
    u = np.zeros(p.ndof)
    u[free] = spla.spsolve(K[free][:, free].tocsc(), F[free])
    vm, _s = p.vonmises(u)
    return vm.max(), float(u[0::3].min())


def _row(tag, vm, w):
    print(f"  {tag:46s} {vm:6.0f} MPa {w:7.2f} mm"
          f"   yields at {REF*YIELD_LOT/vm:6.0f} N"
          f" ({REF*YIELD_LOT/vm/9.81:4.0f} kg)"
          f" | spec-min {REF*YIELD_SPEC/vm:5.0f} N")


def main():
    print(f"BASE PLATE, {REF:.0f} N on one pedal "
          f"(1100-H14: lot 127 MPa, spec min 95, fatigue ~41)\n")
    for pedal in ("STOP", "CLEAR"):
        for kind in ("rim", "area", "toe"):
            vm, w = _base_case(FEET, pedal, kind)
            _row(f"as designed - {pedal}, {kind} bearing", vm, w)
    print()
    for pedal in ("STOP", "CLEAR"):
        for kind in ("rim", "toe"):
            vm, w = _base_case(FEET_FIXED, pedal, kind)
            _row(f"foot on each chassis screw - {pedal}, {kind}", vm, w)

    print(f"\nFACEPLATE, 300 N point load")
    spots = [("rib between two pedal slots", (109.6, 129.6, 40, 100)),
             ("band before the screens, over a post", (600, 650, 148, 178)),
             ("band before the screens, no post", (475, 525, 148, 178)),
             ("ligament left of CLEAR", (180, 230, 215, 265)),
             ("field left of the 7in", (1, 41, 300, 360))]
    for tag, rect in spots:
        vm, w = _lid_case(rect, 300.0)
        print(f"  {tag:46s} {vm:6.0f} MPa {w:7.2f} mm"
              f"   dents at {300*YIELD_LOT/vm:5.0f} N"
              f" ({300*YIELD_LOT/vm/9.81:4.0f} kg)")


if __name__ == "__main__":
    import sys
    print("element validation vs Timoshenko:")
    selftest()
    if "--selftest" not in sys.argv:
        print()
        main()
