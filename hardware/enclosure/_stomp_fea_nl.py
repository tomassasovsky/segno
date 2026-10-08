"""Large-deflection shell analysis of the console floor, in OpenSees.

The old model (_stomp_fea.py) is linear Kirchhoff bending. It is right to 0.3%
against Timoshenko while a plate stays inside small-deflection theory, and it is
useless outside it: at w/t = 10 it overstates deflection sixfold, which is why it
said a Boss RC-600 yields at 42 kg. This one uses ShellNLDKGQ, which carries the
membrane stretching the old one drops, and which reproduces Timoshenko exactly in
the small-deflection limit (validated at w/t = 0.01, ratio 1.00).
"""
import math
import openseespy.opensees as ops


def _axis(lo, hi, feats, hmax):
    pts = sorted({lo, hi} | {round(v, 6) for v in feats if lo < v < hi})
    out = []
    for a, b in zip(pts, pts[1:]):
        n = max(1, int(math.ceil((b - a) / hmax)))
        out += [a + (b - a) * i / n for i in range(n)]
    out.append(hi)
    return out


class Shell:
    def __init__(self, xs, ys, t, E, nu, fy):
        self.xs, self.ys, self.t, self.E, self.nu, self.fy = xs, ys, t, E, nu, fy
        self.nx, self.ny = len(xs) - 1, len(ys) - 1
        ops.wipe()
        ops.model('basic', '-ndm', 3, '-ndf', 6)
        ops.section('ElasticMembranePlateSection', 1, E, nu, t, 0.0)
        for i, x in enumerate(xs):
            for j, y in enumerate(ys):
                ops.node(self.nid(i, j), float(x), float(y), 0.0)
        e = 0
        for i in range(self.nx):
            for j in range(self.ny):
                e += 1
                ops.element('ShellNLDKGQ', e, self.nid(i, j), self.nid(i+1, j),
                            self.nid(i+1, j+1), self.nid(i, j+1), 1)
        self.nel = e
        self.next_tag = e + 1

    def nid(self, i, j):
        return i * (self.ny + 1) + j + 1

    def near(self, x, y):
        i = min(range(self.nx + 1), key=lambda k: abs(self.xs[k] - x))
        j = min(range(self.ny + 1), key=lambda k: abs(self.ys[k] - y))
        return i, j

    def edge_inplane(self):
        """The folded walls hold the plate edge in plane. They do NOT hold it up:
        the walls stop at the plate, they never reach the floor."""
        for i in range(self.nx + 1):
            for j in range(self.ny + 1):
                if i in (0, self.nx) or j in (0, self.ny):
                    ops.fix(self.nid(i, j), 1, 1, 0, 0, 0, 0)

    def springs(self, pads, k_each):
        """A foot or a rail pad: a vertical spring to ground, no in-plane hold."""
        ops.uniaxialMaterial('Elastic', 99, k_each)
        seen = set()
        for (px, py) in pads:
            i, j = self.near(px, py)
            if (i, j) in seen:
                continue
            seen.add((i, j))
            n = self.nid(i, j)
            g = 100000 + n
            ops.node(g, float(self.xs[i]), float(self.ys[j]), 0.0)
            ops.fix(g, 1, 1, 1, 1, 1, 1)
            ops.element('zeroLength', self.next_tag, g, n, '-mat', 99, '-dir', 3)
            self.next_tag += 1
        return len(seen)

    def pressure(self, rect, total):
        x0, x1, y0, y1 = rect
        cells = []
        for i in range(self.nx):
            for j in range(self.ny):
                cx = (self.xs[i] + self.xs[i+1]) / 2.0
                cy = (self.ys[j] + self.ys[j+1]) / 2.0
                if x0 <= cx <= x1 and y0 <= cy <= y1:
                    a = (self.xs[i+1] - self.xs[i]) * (self.ys[j+1] - self.ys[j])
                    cells.append((i, j, a))
        area = sum(c[2] for c in cells)
        assert cells, 'load patch fell between nodes'
        ops.timeSeries('Linear', 1)
        ops.pattern('Plain', 1, 1)
        for i, j, a in cells:
            q = total * a / area / 4.0
            for n in (self.nid(i, j), self.nid(i+1, j),
                      self.nid(i+1, j+1), self.nid(i, j+1)):
                ops.load(n, 0.0, 0.0, -q, 0.0, 0.0, 0.0)

    def solve(self, steps=30):
        ops.system('UmfPack')
        ops.numberer('RCM')
        ops.constraints('Plain')
        ops.test('NormDispIncr', 1e-6, 300, 0)
        ops.algorithm('Newton')
        ops.integrator('LoadControl', 1.0 / steps)
        ops.analysis('Static')
        done = 0
        for _ in range(steps):
            if ops.analyze(1) != 0:
                ops.algorithm('ModifiedNewton', '-initial')
                if ops.analyze(1) != 0:
                    return done / steps
                ops.algorithm('Newton')
            done += 1
        return 1.0

    def vonmises(self, skip=None):
        """Stress resultants -> surface stress -> von Mises, worst of both faces.

        Use 'stresses', NOT 'forces': the latter is the element's 24-value nodal
        force vector, and reading it as resultants gives a stress that is 20x too
        high and scales with mesh size. Validated at 2.4% against Timoshenko's
        M = 0.0479 q L^2 for a simply supported square plate.
        """
        t, worst, where = self.t, 0.0, None
        e = 0
        for i in range(self.nx):
            for j in range(self.ny):
                e += 1
                cx = (self.xs[i] + self.xs[i+1]) / 2.0
                cy = (self.ys[j] + self.ys[j+1]) / 2.0
                if skip and skip(cx, cy):
                    continue
                r = ops.eleResponse(e, 'stresses')
                for p in range(0, len(r), 8):
                    nxx, nyy, nxy, mxx, myy, mxy = r[p:p+6]
                    for sg in (+1.0, -1.0):
                        sx = nxx / t + sg * 6.0 * mxx / t**2
                        sy = nyy / t + sg * 6.0 * myy / t**2
                        sxy = nxy / t + sg * 6.0 * mxy / t**2
                        vm = math.sqrt(sx*sx - sx*sy + sy*sy + 3.0*sxy*sxy)
                        if vm > worst:
                            worst, where = vm, (round(cx, 1), round(cy, 1))
        self.peak_at = where
        return worst

    def wmax(self):
        return min(ops.nodeDisp(self.nid(i, j), 3)
                   for i in range(self.nx + 1) for j in range(self.ny + 1))
