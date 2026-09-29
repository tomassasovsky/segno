"""The side-wall tops the lid rests on, after #1067's rework (2026-09-29).

#1067 added a lid-seat flange along each side wall and spot-welded rear tabs.
Both came out: pre-bent, the flange sits over the side-wall bend's punch where
the wall is short, and the welder has no resistance spot welder. The base is
the #1025 part again (plain single-fold walls, four fusion-welded corners, same
native formed export), and the wider lid (#1067) stays.

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


class SideWallTopsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.directory.cleanup)
        path = Path(cls.directory.name) / 'base.dxf'
        enclosure.dxf_base(str(path))
        cls.entities = list(ezdxf.readfile(path).modelspace())
        cls.bends = list(_lines(cls.entities, 'BEND'))
        cls.cuts = list(_lines(cls.entities, 'CUT'))

    def test_base_folds_five_times_with_no_seat_flange_or_tab(self):
        self.assertEqual(len(self.bends), 5)
        self.assertEqual([row[1] for row in enclosure.BEND_TABLES['segno_base']],
                         ['trasera -> transición', 'pared frontal', 'pared trasera',
                          'pared izquierda', 'pared derecha'])
        for name in ('SIDE_SEAT_FLANGE', 'REAR_TAB_W', 'REAR_TAB_SPOTS_Z', 'side_seat_flange',
                     'rear_corner_tab'):
            self.assertFalse(hasattr(enclosure, name), name)

    def test_wall_top_is_the_lid_underside_from_the_cove_to_the_ridge(self):
        # Behind the #1025 front cove the top edge is one straight line on the
        # lid underside plane, as flat height h(y), up to the crease with the
        # transition flange's underside: no slit, step or flange anywhere on it.
        tan = math.tan(SLOPE)
        edge = lambda y: 12.0 + (y + DEV) * tan - DEV
        th = math.radians(enclosure.TRANS_ANGLE)
        for origin, sign in ((0.0, -1), (BW, 1)):
            with self.subTest(side='left' if sign < 0 else 'right'):
                tops = [(p, q) for p, q in self.cuts
                        if (p[0] < 0) == (sign < 0) and (q[0] < 0) == (sign < 0)
                        and abs(p[0] - q[0]) > 1 and abs(p[1] - q[1]) > 100]
                self.assertEqual(len(tops), 1)
                ends = sorted(tops[0], key=lambda pt: pt[1])
                for x, y in ends:
                    self.assertAlmostEqual((x - origin) * sign, edge(y), places=6)
                self.assertLess(ends[0][1], 3.0)
                crease_y = ends[1][1]
                flange_under = (enclosure.RIDGE_Y - (crease_y - enclosure.RIDGE_Z) * math.tan(th)
                                - 2 * T / math.cos(th) - DEV)
                self.assertAlmostEqual(edge(crease_y), flange_under, places=6)

    def test_ridge_closure_keeps_clear_of_the_lid_bend_and_the_flange_tip(self):
        # Behind the crease the wall follows the lid's inside bend and steps down
        # past the transition flange's tip, 0.30 mm off both (the #1025 closure).
        # A wall top that merely ran on along the flange underside would put the
        # tip's bottom corner on the wall, and Fusion refuses to fold that.
        a, b = SLOPE, math.radians(enclosure.TRANS_ANGLE)
        front, rear = (-math.sin(a), math.cos(a)), (math.sin(b), math.cos(b))
        tip_dir = (-math.cos(b), math.sin(b))
        dot = lambda n, p: n[0] * p[0] + n[1] * p[1]
        corner = (enclosure.RIDGE_Z, enclosure.RIDGE_Y)
        ridge = enclosure.base_rear_ridge_profile()
        self.assertEqual(len(ridge), 5)
        start, _f_tan, _r_tan, tip_top, tip_bottom = [p[:2] for p in ridge]
        self.assertAlmostEqual(dot(front, corner) - T - dot(front, start), 0.30, places=6)
        self.assertAlmostEqual(dot(rear, corner) - T - dot(rear, tip_top), 0.30, places=6)
        flange_tip = dot(tip_dir, corner) - enclosure.D_FL_TIP
        for p in (tip_top, tip_bottom):
            self.assertAlmostEqual(dot(tip_dir, p) - flange_tip, 0.30, places=6)
        self.assertAlmostEqual(dot(rear, tip_bottom), dot(rear, corner) - 2 * T, places=6)

    def test_transition_flange_tip_is_back_at_its_ridge_clearance(self):
        # With no seat flange to meet, the tip stops 2 mm down the facet again,
        # clear of the lid's inside bend by more than the forming tolerance.
        self.assertAlmostEqual(enclosure.D_FL_TIP, 2.0, places=9)
        fold = math.radians(enclosure.SLOPE_ANGLE + enclosure.TRANS_ANGLE)
        self.assertGreater(enclosure.D_FL_TIP - (R + T) * math.tan(fold / 2), 0.5)
        # The nine lap screws did not move.
        self.assertAlmostEqual(enclosure.SEAM_TAP_V, 99.46275870925763, places=9)
        self.assertAlmostEqual(enclosure.SEAM_LAP_V, 433.2058704837384, places=9)

    def test_faceplate_overhangs_each_side_skin_by_one_sheet(self):
        # Owner call (#1067): the lid runs 2 mm past each side skin; the rear wall
        # and its shoulder stay at the base's outer width, and nothing on the lid
        # moves.
        self.assertAlmostEqual(enclosure.BASE_OUTER_W, 849.8, places=9)
        self.assertAlmostEqual(enclosure.LID_W, 849.8 + 4.0, places=9)
        self.assertAlmostEqual(enclosure.LID_OX, (enclosure.LID_W - BW) / 2, places=9)
        shoulder = [row for row in enclosure.BEND_TABLES['segno_base'] if row[1].startswith('trasera')]
        self.assertAlmostEqual(shoulder[0][4], 849.8, places=9)
        front, lap = enclosure.BEND_TABLES['segno_faceplate']
        self.assertAlmostEqual(front[4], 853.8, places=9)
        # #1088: the overhang tapers out before the rear bend; the lap is flush.
        self.assertAlmostEqual(lap[4], 849.8, places=9)

    def test_drawings_ask_for_four_fusion_welded_corners_and_no_spot_welds(self):
        notes = ' '.join(e.dxf.text if e.dxftype() == 'TEXT' else e.text
                         for e in self.entities if e.dxftype() in ('TEXT', 'MTEXT'))
        footnote = enclosure.BEND_FOOTNOTES['segno_base']
        self.assertIn('cuatro esquinas', notes)
        self.assertIn('cuatro esquinas', footnote)
        for text in (notes, footnote):
            self.assertNotIn('resistencia', text)
            self.assertNotIn('lengüeta', text)
            self.assertNotIn('pestaña de asiento', text)

    def test_beam_pad_runs_the_full_length_between_the_ear_reliefs(self):
        # Without the seat flanges there is nothing to notch the pad around: it
        # stops only at the ear reliefs, like the foot.
        import cadquery as cq
        solid = enclosure._beam_solid()
        tilt = math.radians(enclosure.BEAM_TILT)
        normal = cq.Vector(0, -math.sin(tilt), math.cos(tilt))
        pads = [f for f in solid.Faces() if f.geomType() == 'PLANE'
                and f.normalAt().dot(normal) > 0.99999]
        pad = max(pads, key=lambda f: f.Area())
        self.assertAlmostEqual(pad.BoundingBox().xlen,
                               enclosure.BEAM_LEN - 2 * enclosure._BEAM_REL, places=3)
        self.assertFalse(hasattr(enclosure, 'BEAM_PAD_X0'))


if __name__ == '__main__':
    unittest.main()
