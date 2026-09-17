"""Rear corner tabs, lid-seat flanges and the beam notch they need (#1067).

The development numbers are recomputed here from T2 / R2 / K0.33 rather than
read from the generator, so a wrong constant there cannot pass by agreeing with
itself.
"""
import math
from pathlib import Path
import sys
import tempfile
import unittest

import ezdxf

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import segno_enclosure as enclosure


T, R, K = 2.0, 2.0, 0.33
HALF_BEND = math.pi / 4 * (R + K * T)          # half of a 90 deg bend allowance
DEV = (R + T) - HALF_BEND                      # bend line -> outer mold line
BW, BD = 846.0, 419.0
REAR_INSIDE_Y = BD + DEV - T                   # rear wall inner face, folded
SLOPE = math.atan2(100.0 - 12.0, 397.0)


def _lines(entities, layer):
    for entity in entities:
        if entity.dxf.layer != layer:
            continue
        curves = (entity.virtual_entities()
                  if entity.dxftype() == 'LWPOLYLINE' else [entity])
        for curve in curves:
            if curve.dxftype() == 'LINE':
                yield (curve.dxf.start.x, curve.dxf.start.y), (curve.dxf.end.x, curve.dxf.end.y)


class RearTabsAndSeatFlangesTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.directory.cleanup)
        path = Path(cls.directory.name) / 'base.dxf'
        enclosure.dxf_base(str(path))
        cls.entities = list(ezdxf.readfile(path).modelspace())
        cls.bends = list(_lines(cls.entities, 'BEND'))
        cls.cuts = list(_lines(cls.entities, 'CUT'))

    def _tab_bends(self):
        return [(a, b) for a, b in self.bends
                if abs(a[1] - b[1]) < 1e-9 and (max(a[0], b[0]) < 0 or min(a[0], b[0]) > BW)]

    def test_each_tab_lands_on_the_rear_wall_inner_face(self):
        tabs = self._tab_bends()
        self.assertEqual(len(tabs), 2)
        for (a, b) in tabs:
            with self.subTest(side='left' if a[0] < 0 else 'right'):
                y = a[1]
                # Folding puts the tab's outer face DEV past its bend line; it
                # has to stop the nominal 0.20 mm gap short of the rear wall.
                self.assertAlmostEqual(REAR_INSIDE_Y - (y + DEV), 0.20, places=6)
                origin = 0.0 if a[0] < 0 else BW
                heights = sorted(abs(x - origin) for x in (a[0], b[0]))
                # The tab takes the whole rear edge: it starts at the floor
                # bend's tangent (half a 90 deg allowance up the flap).
                self.assertAlmostEqual(heights[0], HALF_BEND, places=6)
                # The free edge: 18 mm from the side wall's outer face.
                tips = [(p, q) for p, q in self.cuts
                        if abs(p[1] - q[1]) < 1e-9 and (p[0] < 0) == (a[0] < 0)
                        and abs(p[1] - (y + 18.0 - DEV)) < 1e-6]
                self.assertEqual(len(tips), 1)

    def test_corner_top_edge_follows_the_rear_wall_inside_at_constant_clearance(self):
        # Where side wall, rear wall and shoulder meet there is no slit, step or
        # loose piece: through the tab's bend and across the tab, each flat
        # station sits REAR_CORNER_CLR under the rear wall / shoulder inside
        # contour at the depth its OUTER surface reaches once folded.
        clr = enclosure.REAR_CORNER_CLR
        yc = REAR_INSIDE_Y - R
        zc = (enclosure.HR_FLAT - enclosure.bend_allowance(90.0 - enclosure.TRANS_ANGLE) / 2
              + DEV - T)
        tab = enclosure.rear_corner_tab()
        y_s = tab['y_s']
        stations = [(h, yf) for h, yf, _b in tab['section']
                    if y_s - 1e-9 <= yf <= y_s + 2 * HALF_BEND + 1e-9]
        self.assertGreaterEqual(len(stations), 9)
        for h, yf in stations:
            theta = (yf - y_s) / (R + K * T)
            y_out = y_s + (R + T) * math.sin(theta)
            z = h - T + DEV
            if y_out >= yc + (R - clr) * math.cos(math.radians(90 - enclosure.TRANS_ANGLE)):
                self.assertAlmostEqual(math.hypot(y_out - yc, z - zc), R - clr, places=6)
            else:
                self.assertLess(z, enclosure.rear_corner_contour_z(y_out, 0.0))
        # ...and no 0.2 mm cut anywhere in the rear corner.
        self.assertFalse([1 for p, q in self.cuts
                          if p[1] > 405 and abs(math.dist(p, q) - 0.2) < 1e-6])
        # The tab's flat part is capped by the same contour at its outer face.
        self.assertAlmostEqual(enclosure.rear_tab_z()[1],
                               zc + math.sqrt((R - clr) ** 2 - (REAR_INSIDE_Y - 0.2 - yc) ** 2),
                               places=6)

    def test_seat_flange_bend_sits_one_development_inside_the_lid_seat_edge(self):
        inclined = [(a, b) for a, b in self.bends
                    if abs(a[0] - b[0]) > 1 and abs(a[1] - b[1]) > 1]
        self.assertEqual(len(inclined), 2)
        tan = math.tan(SLOPE)
        for a, b in inclined:
            origin, sign = (0.0, -1) if a[0] < 0 else (BW, 1)
            # The old top edge, lid underside plane, as flat height h(y).
            edge = lambda y: 12.0 + (y + DEV) * tan - DEV
            with self.subTest(side='left' if sign < 0 else 'right'):
                for x, y in (a, b):
                    h = (x - origin) * sign
                    perpendicular = (edge(y) - h) * math.cos(SLOPE)
                    self.assertAlmostEqual(perpendicular, DEV, places=6)
                # The flange's free edge: parallel, 15 mm from the wall's outer
                # face once folded, i.e. 15 - 2 DEV outside the old edge line.
                length = math.dist(a, b)
                tips = [(p, q) for p, q in self.cuts
                        if abs(math.dist(p, q) - length) < 1e-6 and (p[0] < 0) == (sign < 0)]
                self.assertEqual(len(tips), 1)
                for x, y in tips[0]:
                    h = (x - origin) * sign
                    self.assertAlmostEqual((h - edge(y)) * math.cos(SLOPE),
                                           15.0 - 2 * DEV, places=6)

    def test_seat_flange_runs_to_the_lid_bend_with_slit_ends(self):
        seat = enclosure.side_seat_flange()
        self.assertGreaterEqual(seat['front_y'], 10.0)
        section = seat['section']
        # Both slits: 0.2 mm wide along the edge, bottoms past the bend band.
        for mouth, bottom in ((section[1], section[2]), (section[5], section[6])):
            self.assertAlmostEqual(math.dist(mouth[:2], bottom[:2]), 0.2, places=6)
        self.assertAlmostEqual(seat['relief'], DEV + HALF_BEND + 0.5, places=6)
        # The rear slit's far side climbs straight to the start of the arc that
        # clears the lid's rear bend by 0.3 mm: no dip or leftover edge before it.
        ridge = enclosure.base_rear_ridge_profile()[1]
        start = (ridge[1] - DEV, ridge[0])
        self.assertEqual(seat['ridge_start'], start)
        far_side = (start[0] - section[-1][0], start[1] - section[-1][1])
        along = (math.sin(SLOPE), math.cos(SLOPE))
        self.assertAlmostEqual(far_side[0] * along[0] + far_side[1] * along[1], 0.0, places=6)
        self.assertAlmostEqual(math.hypot(*far_side), seat['relief'] - 0.3, places=6)

    def test_spot_welds_sit_on_the_tab_away_from_its_ends(self):
        lo, hi = enclosure.rear_tab_z()
        self.assertEqual(len(enclosure.REAR_TAB_SPOTS_Z), 3)
        for z in enclosure.REAR_TAB_SPOTS_Z:
            self.assertGreaterEqual(z - lo, 10.0)
            self.assertGreaterEqual(hi - z, 10.0)
        spacing = [b - a for a, b in zip(enclosure.REAR_TAB_SPOTS_Z,
                                         enclosure.REAR_TAB_SPOTS_Z[1:])]
        self.assertGreaterEqual(min(spacing), 20.0)

    def test_beam_stays_out_of_the_seat_flanges(self):
        import cadquery as cq
        solid = enclosure._beam_solid()
        tilt = math.radians(enclosure.BEAM_TILT)
        normal = cq.Vector(0, -math.sin(tilt), math.cos(tilt))
        pads = [f for f in solid.Faces() if f.geomType() == 'PLANE'
                and f.normalAt().dot(normal) > 0.99999]
        pad = max(pads, key=lambda f: f.Area())
        # The lid underside lies the bare support gap above the pad, along the
        # pad normal; the flange and its inner bend occupy R + T below that.
        lid = pad.Center().dot(normal) + enclosure.BEAM_BARE_GAP
        flange_edge = 15.0 - DEV - enclosure.BEAM_U0        # beam local x
        span = enclosure.BEAM_LEN
        for x0, x1 in ((-5.0, flange_edge + 1.0), (span - flange_edge - 1.0, span + 5.0)):
            zone = (cq.Workplane('XY').box(x1 - x0, 200, R + T + 1.0, centered=False)
                    .translate((x0, -100, -(R + T + 1.0))).val()
                    .rotate((0, 0, 0), (1, 0, 0), math.degrees(tilt))
                    .translate(normal * lid))
            with self.subTest(end='left' if x0 < 0 else 'right'):
                self.assertLess(solid.intersect(zone).Volume(), 1e-6)
        # ...and the pad still bears everywhere else.
        self.assertAlmostEqual(pad.BoundingBox().xlen, span - 2 * enclosure.BEAM_PAD_X0,
                               places=3)


if __name__ == '__main__':
    unittest.main()
