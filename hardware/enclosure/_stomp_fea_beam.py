"""The beam bolted at its FOURTEEN actual points, not smeared along the plate.

Run from hardware/enclosure:  .venv/bin/python _stomp_fea_beam.py
Reproduces the bottom-plate table in the design doc: no beam 96 MPa, slotted
fixings 135, plain fixings 147, at a 1 kN stomp.

The difference matters. Sharing nodes ties the plate to the beam in-plane along
the whole line, which stops the plate stretching and takes away the membrane
relief it was using -- stress up, deflection down. Real bolts transfer vertical
load at fourteen places, and a slotted hole transfers no in-plane load at all.
"""
import sys
import openseespy.opensees as ops
from _stomp_fea_nl import Shell, _axis
import _stomp_fea_cases as R

BW, BD, T, E, NU, FY = 846.0, 419.0, 2.0, 68900.0, 0.33, 95.0
E_ST, VB, ZB = 210000.0, 148.997, 22.3      # steel, beam line, neutral axis height
EI_HAT = 1.37e10                            # 1.6 mm hat, 40 wide x 42 tall
BOLTS = None


def bolt_us():
    import segno_enclosure as se
    return se.beam_bolt_u()


def wall_k():
    h = 12.0 + (100.0 - 12.0) * (VB / 397.0)
    return 48.0 * 68900.0 * (T * h**3 / 12.0) / (343.25 - 114.883)**3


def case(pedal, mode, EI=EI_HAT):
    """mode: 'none' | 'slotted' (vertical only) | 'bolted' (all DOF) | 'smeared'"""
    import segno_enclosure as se
    pads = R.rails([18.0, 114.883, 343.25])
    bus = bolt_us()
    fx = {p[0] for p in pads} | {0.0, BW} | set(bus)
    fy = {p[1] for p in pads} | {VB}
    for cu, cv in R.PEDALS.values():
        fx.update([cu - R.COLLAR[0]/2, cu, cu + R.COLLAR[0]/2])
        fy.update([cv - R.COLLAR[1]/2, cv, cv + R.COLLAR[1]/2])
    s = Shell(_axis(0.0, BW, fx, 14.0), _axis(0.0, BD, fy, 14.0), T, E, NU, FY)
    s.edge_inplane()
    s.springs(pads, R.K_RAIL)
    if mode != 'none':
        j = min(range(s.ny + 1), key=lambda k: abs(s.ys[k] - VB))
        Iz = EI / E_ST
        ops.geomTransf('Corotational', 7, 0.0, 0.0, 1.0)
        if mode == 'smeared':
            for i in range(s.nx):
                ops.element('elasticBeamColumn', s.next_tag, s.nid(i, j), s.nid(i+1, j),
                            246.4, E_ST, E_ST/2.6, 2*Iz, Iz, Iz, 7)
                s.next_tag += 1
        else:
            base = 300000
            for i in range(s.nx + 1):
                ops.node(base + i, float(s.xs[i]), float(s.ys[j]), ZB/10.0)
            for i in range(s.nx):
                ops.element('elasticBeamColumn', s.next_tag, base + i, base + i + 1,
                            246.4, E_ST, E_ST/2.6, 2*Iz, Iz, Iz, 7)
                s.next_tag += 1
            ops.uniaxialMaterial('Elastic', 97, 1.0e7)
            dirs = [3] if mode == 'slotted' else [1, 2, 3]
            for bu in bus:
                i = min(range(s.nx + 1), key=lambda k: abs(s.xs[k] - bu))
                ops.element('zeroLength', s.next_tag, base + i, s.nid(i, j),
                            '-mat', *([97] * len(dirs)), '-dir', *dirs)
                s.next_tag += 1
            # the beam's ends land on the side walls
            ops.uniaxialMaterial('Elastic', 96, wall_k())
            for i in (0, s.nx):
                g = 400000 + i
                ops.node(g, float(s.xs[i]), float(s.ys[j]), ZB/10.0)
                ops.fix(g, 1, 1, 1, 1, 1, 1)
                ops.element('zeroLength', s.next_tag, g, base + i, '-mat', 96, '-dir', 3)
                s.next_tag += 1
            # a beam along x bending in z needs uz and roty; everything else
            # is a rigid-body mode and leaves the system singular. With
            # vertical-only links there is nothing else holding it.
            for i in range(s.nx + 1):
                ops.fix(base + i, 1, 1, 0, 1, 0, 1)
    cu, cv = R.PEDALS[pedal]
    s.pressure((cu - R.COLLAR[0]/2, cu + R.COLLAR[0]/2,
                cv - R.COLLAR[1]/2, cv + R.COLLAR[1]/2), 1000.0)
    frac = s.solve(steps=10)
    return s.vonmises(), s.wmax(), frac


if __name__ == '__main__':
    FY = 95.0
    MODES = (('no beam', 'none'),
             ('beam, 14 bolts, SLOTTED (vertical only)', 'slotted'),
             ('beam, 14 bolts, plain holes (all DOF)', 'bolted'))
    if 'smeared' in sys.argv[1:]:
        MODES += (('beam smeared along the plate', 'smeared'),)
    print('%-44s %8s %10s %6s %s' % ('', 'peak', 'deflect', 'util', 'worst pedal'))
    for label, mode in MODES:
        worst = (0.0, 0.0, 1.0, '')
        for pedal in ('STOP', 'CLEAR', 'BANK', 'REC/PLAY'):
            vm, w, frac = case(pedal, mode)
            if vm > worst[0]:
                worst = (vm, w, frac, pedal)
        print('%-44s %6.0f MPa %8.2f mm %6.2f  %s%s' % (
            label, worst[0], worst[1], worst[0] / FY, worst[3],
            '' if worst[2] >= 1.0 else '  (only %.0f%% converged)' % (100 * worst[2])))
