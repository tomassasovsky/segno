"""How much in-plane force does each bolt actually have to hold back?

The 135 MPa figure assumed the slotted joint SLIPS -- vertical link only, no
in-plane restraint. A torqued bolt through a slot does not slip until friction
is overcome. This reads the in-plane force at each of the fourteen links in the
CLAMPED model and compares it with the friction one M4 can supply.

Run from hardware/enclosure:  .venv/bin/python _stomp_fea_slip.py
Result on 2026-09-10: the four bolts nearest a CLEAR stomp each carry 1.0-1.4 kN
in plane against ~500 N of friction at 2 N.m, so they slip and the slotted figure
(135 MPa) is the one that applies.
"""
import sys
import math
import openseespy.opensees as ops
import _stomp_fea_beam as beam2

LINKS = []
_orig = ops.element
def spy(*a, **k):
    if a and a[0] == 'zeroLength' and len(a) > 4:
        LINKS.append((a[1], a[2], a[3]))
    return _orig(*a, **k)
ops.element = spy

for pedal in ('CLEAR', 'REC/PLAY'):
    LINKS.clear()
    vm, w, frac = beam2.case(pedal, 'bolted')
    ops.element = _orig
    rows = []
    for tag, n1, n2 in LINKS:
        if n1 < 300000 or n1 >= 400000:      # only the fourteen bolt links
            continue
        f = ops.eleResponse(tag, 'force')
        if not f:
            continue
        fx, fy, fz = f[0], f[1], f[2]
        rows.append((math.hypot(fx, fy), abs(fz), ops.nodeCoord(n1)[0]))
    ops.element = spy
    rows.sort(reverse=True)
    print('%-9s peak %.0f MPa, w %.2f mm, solved %.0f%%' % (pedal, vm, w, frac*100))
    print('   fourteen bolts, in-plane force each (N):',
          ' '.join('%.0f' % r[0] for r in sorted(rows, key=lambda r: r[2])))
    print('   worst in-plane %.0f N at u=%.0f ; worst vertical %.0f N'
          % (rows[0][0], rows[0][2], max(r[1] for r in rows)))
    total = sum(r[0] for r in rows)
    print('   total in-plane the fourteen hold back: %.0f N' % total)
    print()

D, MU = 4.0, 0.2
for torque in (1.0, 2.0, 3.0):
    preload = torque*1000.0/(0.2*D)          # T = K F d, K ~ 0.2
    print('M4 at %.1f N.m -> ~%.0f N preload -> ~%.0f N of friction per bolt '
          '(mu %.1f, one interface)' % (torque, preload, MU*preload, MU))
