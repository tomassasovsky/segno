"""Floor support layouts under a 1 kN stomp, in the large-deflection model.

Run from hardware/enclosure with the enclosure venv (it carries openseespy):

    .venv/bin/python _stomp_fea_cases.py [load_N]

Prints peak von Mises, deflection and utilisation against the 95 MPa spec-minimum
yield for each layout in CASES, worst of STOP, CLEAR and REC/PLAY. This is the
model behind the "linear numbers are superseded" table in
docs/research/2026-09-09-enclosure-stomp-load-analysis.md; THREE rails is the
layout that shipped. Pedal and collar geometry come from the old linear model's
constants so both models load the same footprint.
"""
import sys, math
import openseespy.opensees as ops
from _stomp_fea_nl import Shell, _axis
import _stomp_fea as OLD

BW, BD, T, E, NU, FY = 846.0, 419.0, 2.0, 68900.0, 0.33, 95.0
COLLAR = OLD.COLLAR
PEDALS = OLD.PEDALS
DU, DV = 22.188, 48.685
U0, U1 = 18.43, 827.57
PITCH = 20.0
W_STRIP, T_RUB, E_RUB = 19.05, 3.2, 4.0
S = W_STRIP / (2 * T_RUB)
K_RAIL = E_RUB * (1 + 2 * S * S) * W_STRIP / T_RUB * PITCH
K_FOOT_SMALL, K_FOOT_BIG = 400.0, 1100.0


def rails(vs):
    out = []
    for v in vs:
        n = int((U1 - U0) // PITCH)
        out += [(U0 + i * (U1 - U0) / n, v) for i in range(n + 1)]
    return out


CASES = {
    "4 corner feet, RC-600 style": ([(14.3,45.0),(831.7,45.0),(14.3,374.0),(831.7,374.0)], K_FOOT_SMALL),
    "as drawn, 15 rubber feet":    (OLD.FEET, K_FOOT_SMALL),
    "20 feet, front+back of each pedal":
        ([(cu+du, cv+dv) for cu, cv in PEDALS.values() for du, dv in ((0,-DV),(0,DV))], K_FOOT_BIG),
    "40 feet, every chassis screw": (OLD.FEET_FIXED, K_FOOT_SMALL),
    "THREE rails":                  (rails([18.0, 114.883, 343.25]), K_RAIL),
    "FOUR rails":                   (rails([18.0, 114.883, 221.4, 343.25]), K_RAIL),
}


def build(pads, hmax=13.0):
    fx, fy = set(), set()
    for px, py in pads:
        fx.add(px); fy.add(py)
    for cu, cv in PEDALS.values():
        fx.update([cu - COLLAR[0]/2, cu, cu + COLLAR[0]/2])
        fy.update([cv - COLLAR[1]/2, cv, cv + COLLAR[1]/2])
    xs = _axis(0.0, BW, fx, hmax)
    ys = _axis(0.0, BD, fy, hmax)
    return Shell(xs, ys, T, E, NU, FY)


def run(pads, k, pedal, load, hmax=13.0, steps=16):
    s = build(pads, hmax)
    s.edge_inplane()
    s.springs(pads, k)
    cu, cv = PEDALS[pedal]
    s.pressure((cu - COLLAR[0]/2, cu + COLLAR[0]/2, cv - COLLAR[1]/2, cv + COLLAR[1]/2), load)
    frac = s.solve(steps=steps)
    return s.vonmises(), s.wmax(), frac, s.peak_at


if __name__ == '__main__':
    LOAD = float(sys.argv[1]) if len(sys.argv) > 1 else 1000.0
    print("LARGE-DEFLECTION SHELL ANALYSIS -- OpenSees ShellNLDKGQ")
    print("bottom plate %.0f x %.0f x %.1f mm, 1100-H14 (spec-min yield %.0f MPa)" % (BW, BD, T, FY))
    print("perimeter held IN PLANE by the folded walls, held UP only by the feet/rails")
    print("load: %.0f N over one pedal pedestal footprint\n" % LOAD)
    print("%-38s %8s %10s %9s %s" % ("", "peak", "deflection", "util", "worst pedal"))
    for tag, (pads, k) in CASES.items():
        worst = (0.0, 0.0, "", 1.0)
        for pedal in ("STOP", "CLEAR", "REC/PLAY"):
            vm, w, frac, at = run(pads, k, pedal, LOAD)
            if vm > worst[0]:
                worst = (vm, w, pedal, frac)
        flag = "" if worst[3] >= 1.0 else "  (only %.0f%% of load converged)" % (100*worst[3])
        print("%-38s %6.0f MPa %8.2f mm %8.2f  %-9s%s"
              % (tag, worst[0], worst[1], worst[0]/FY, worst[2], flag))
