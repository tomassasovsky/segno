"""Pedestal feet — the supports that actually carry a stomp (issue #1019).

The twenty floor supports sit in the gaps BETWEEN pedals, so a stomp reaches
them only by bending the 2.0 mm floor: 353 MPa and 23 mm of travel under 1 kN
on one pedal, first yield around 360 N. A foot on each of a pedestal's four
chassis screws takes that to 89 MPa and 1.4 mm. `_stomp_fea.py` is the model;
these are the geometry regressions that keep the fix intact.

The load claim rests on one property above all: the feet must land on the
screws that are ALREADY there, so the cut file does not change. That is the
first test below, and it is the one to distrust if the drawing ever moves.
"""
import math
from pathlib import Path
import sys
import tempfile
import unittest

import ezdxf

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import segno_enclosure as enclosure


def rounded(point):
    return tuple(round(value, 3) for value in point)


class PedestalFeet(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.feet = enclosure.pedestal_foot_xy()
        cls.floor = enclosure.base_foot_xy()
        cls.radius = enclosure.PEDESTAL_FOOT_BODY_D / 2.0

    def test_one_foot_per_chassis_screw_on_every_pedal(self):
        self.assertEqual(len(self.feet),
                         len(enclosure.PEDALS) * len(enclosure.platform_foot_xy()))
        self.assertEqual(len(set(map(rounded, self.feet))), len(self.feet))

    def test_every_foot_lands_on_a_hole_the_cut_file_already_has(self):
        """The whole point: no new bores. Read it back out of a fresh DXF."""
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'segno_base.dxf'
            enclosure.dxf_base(str(path))
            bores = set()
            for entity in ezdxf.readfile(path).modelspace():
                if entity.dxftype() != 'CIRCLE' or entity.dxf.layer != 'CUT':
                    continue
                if abs(entity.dxf.radius - enclosure.D_M3_METAL / 2.0) > 1e-7:
                    continue
                bores.add(rounded((entity.dxf.center.x, entity.dxf.center.y)))
        for foot in self.feet:
            with self.subTest(foot=foot):
                self.assertIn(rounded(foot), bores,
                              'pedestal foot is not on an existing M3 chassis bore '
                              '-- segno_base.dxf would have to change')

    def test_foot_height_matches_the_floor_supports(self):
        """Two heights means the console stands on one set and rocks on the other."""
        self.assertAlmostEqual(enclosure.PEDESTAL_FOOT_H, enclosure.FOOT_H, places=9)

    def test_the_screw_passes_and_its_head_does_not_reach_the_floor(self):
        self.assertGreater(enclosure.PEDESTAL_FOOT_BORE,
                           enclosure.D_M3_METAL - 0.5)
        self.assertLess(enclosure.PEDESTAL_FOOT_CBORE_H,
                        enclosure.PEDESTAL_FOOT_H - 1.0)
        self.assertGreater(enclosure.PEDESTAL_FOOT_CBORE_D,
                           enclosure.PEDESTAL_FOOT_BORE)

    def test_feet_stay_inside_the_pedestal_footprint(self):
        for fx, fy in enclosure.platform_foot_xy():     # x = depth, y = width
            with self.subTest(station=(fx, fy)):
                self.assertLessEqual(abs(fx) + self.radius,
                                     enclosure.CONSOLE_PLATFORM_D / 2.0)
                self.assertLessEqual(abs(fy) + self.radius,
                                     enclosure.SKIRT_OUT_W / 2.0)

    def test_no_foot_overlaps_another_foot(self):
        for index, (au, av) in enumerate(self.feet):
            for bu, bv in self.feet[index + 1:]:
                with self.subTest(a=(au, av), b=(bu, bv)):
                    self.assertGreater(math.hypot(au - bu, av - bv),
                                       enclosure.PEDESTAL_FOOT_BODY_D)
            for bu, bv in self.floor:
                with self.subTest(a=(au, av), floor=(bu, bv)):
                    self.assertGreater(
                        math.hypot(au - bu, av - bv),
                        (enclosure.PEDESTAL_FOOT_BODY_D + enclosure.FOOT_BODY_D) / 2.0)

    def test_no_foot_sits_over_an_intake_vent_slot(self):
        vents = [c for c in enclosure._bottom_vents_local(
            enclosure.W - 2 * enclosure.T, enclosure.D - 2 * enclosure.T)
            if c.get('kind') == 'rect']
        self.assertGreater(len(vents), 0)
        for au, av in self.feet:
            for cut in vents:
                b = enclosure._bbox(cut)
                with self.subTest(foot=(au, av), vent=b):
                    self.assertFalse(b[0] < au + self.radius and au - self.radius < b[2]
                                     and b[1] < av + self.radius and av - self.radius < b[3])


if __name__ == '__main__':
    unittest.main()
