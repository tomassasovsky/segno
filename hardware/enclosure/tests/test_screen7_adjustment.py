"""The measured screen correction must reach both printed mounting patterns."""
import math
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

import cadquery as cq

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import segno_enclosure as enclosure


class ScreenAdjustmentTest(unittest.TestCase):
    def test_tower_and_fit_jig_follow_module_without_moving_floor_anchors(self):
        # Independent nominal stations after the owner's 0.50 mm frontward move.
        tabs = ((-76.8, 54.75), (80.3, 54.75),
                (-76.8, -60.25), (80.3, -60.25))
        c = math.cos(math.radians(enclosure.SLOPE_ANGLE))
        s = math.sin(math.radians(enclosure.SLOPE_ANGLE))
        with tempfile.TemporaryDirectory() as tmp, patch.object(enclosure, 'OUT', tmp):
            tower = cq.importers.importStep(enclosure.build_screen7_tower_step()).val()
            jig = cq.importers.importStep(enclosure.build_screen7_fit_test()).val()
        for solid in (tower, jig):
            self.assertTrue(solid.isValid())
            self.assertEqual(len(solid.Solids()), 1)
        for x, y in tabs:
            # Test empty insertion space and surrounding load-bearing boss metal
            # in the sloped tower frame; a moved hole without its boss fails.
            # The 0.20 mm coated-lid setback shortens only the boss, retaining
            # the measured in-plane mounting stations and the floor interface.
            plane = cq.Plane(origin=(x, c*y-s*7.8, 66.06+s*y+c*7.8),
                             xDir=(1, 0, 0), normal=(0, -s, c))
            bore = cq.Workplane(plane).circle(1.99).extrude(-4.99).val()
            seat = cq.Workplane(plane).circle(4.49).circle(2.01).extrude(-.1).val()
            self.assertLess(tower.intersect(bore).Volume(), 1e-7)
            self.assertLess(seat.cut(tower).Volume(), 1e-7)
            jig_bore = cq.Workplane('XY').center(x, y).circle(1.29).extrude(-5.4).val()
            self.assertLess(jig.intersect(jig_bore).Volume(), 1e-7)
        expected_floor = ((-93.775, -42.19668095881), (-93.775, 37.803319041184),
                          (98.225, -42.19668095881), (98.225, 37.803319041184),
                          (2.225, -75.56156369584), (2.225, 71.168201778209))
        for x, y in expected_floor:
            bore = cq.Workplane('XY').center(x, y).circle(1.59).extrude(5).val()
            seat = cq.Workplane('XY').center(x, y).circle(3).circle(1.61).extrude(1).val()
            self.assertLess(tower.intersect(bore).Volume(), 1e-7)
            self.assertLess(seat.cut(tower).Volume(), 1e-7)


if __name__ == '__main__':
    unittest.main()
