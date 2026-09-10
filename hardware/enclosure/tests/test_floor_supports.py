"""Twenty floor supports: cutting and nominal assembly-clearance regressions.

These checks do not establish strength or load sharing; the rated-load
answer lives in _stomp_fea.py and test_pedestal_feet.py. The purchased foot is
modelled as Ø18 x 5 mm; Ø9 x 5 mm top hardware and Ø9 existing underside hardware
are conservative design envelopes, not verified measurements of every screw.
The converter washers use the separately specified Ø12 mm envelope.
"""
from contextlib import redirect_stdout
import io
import itertools
import json
import math
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

import cadquery as cq
import ezdxf
from OCP.gp import gp_Trsf

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import segno_enclosure as enclosure


# Selected floor coordinates, frozen independently of base_foot_xy(). The
# original four locations remain; every front pair gains one support, and the
# rear row matches it. The other three follow CLEAR/BANK and the steel posts.
ORIGINAL = ((14.3, 45.0), (14.3, 374.0),
            (831.7, 45.0), (831.7, 374.0))
ADDED = ((119.571429, 66.198026), (321.857143, 66.198026),
         (524.142857, 66.198026), (726.428571, 66.198026),
         (119.571429, 374.0), (321.857143, 374.0),
         (524.142857, 374.0), (726.428571, 374.0),
         (321.857143, 229.968960),
         # one forward of every steel-post foot -- this row follows POST_U, so
         # it went from two to seven when the posts spread across the band (#1019)
         (119.571429, 131.44), (220.714286, 131.44), (321.857143, 131.44),
         (423.0, 131.44), (524.142857, 131.44),
         (625.285714, 131.44), (726.428571, 131.44))
FOOT_RADIUS = 9.0
HEAD_RADIUS = 4.5
HEAD_HEIGHT = 5.0
BUCK_WASHERS = ((345.2, 367.5), (399.1, 367.5),
                (420.9, 367.5), (474.8, 367.5))


def rounded(point):
    return tuple(round(value, 3) for value in point)


def moved(shape, matrix):
    transform = gp_Trsf()
    transform.SetValues(*(value for row in matrix[:3] for value in row))
    return shape.moved(cq.Location(transform))


def box_distance(first, second):
    return math.sqrt(sum(max(a0-b1, b0-a1, 0.0)**2
                         for a0, a1, b0, b1 in zip(
                             (first.xmin, first.ymin, first.zmin),
                             (first.xmax, first.ymax, first.zmax),
                             (second.xmin, second.ymin, second.zmin),
                             (second.xmax, second.ymax, second.zmax))))


def point_rectangle_distance(x, y, bounds):
    return math.hypot(max(bounds[0]-x, x-bounds[2], 0.0),
                      max(bounds[1]-y, y-bounds[3], 0.0))


class FloorSupportTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.output = tempfile.TemporaryDirectory(prefix='segno-floor-supports-')
        cls.addClassCleanup(cls.output.cleanup)
        output = Path(cls.output.name)
        with patch.object(enclosure, 'OUT', str(output)), redirect_stdout(io.StringIO()):
            enclosure.dxf_base(str(output/'segno_base.dxf'))
            enclosure.build_platform_steps()
            enclosure.build_screen7_tower_step()
            enclosure.build_screen16_stand_steps()
            enclosure.build_post_step()
        parts = {path.stem: cq.importers.importStep(str(path)).val()
                 for path in output.glob('*.step')}
        cls.reference = json.loads((Path(enclosure.HERE)/
                                    'reference/coated_support_datums.json').read_text())
        cls.obstacles = {}
        for occurrence in cls.reference['support_occurrences']:
            stem = occurrence['part']
            if stem == 'segno_platform_sled' and occurrence['matrix_mm'][2][3] > 20:
                stem = 'segno_platform_mid_sled'
            cls.obstacles[occurrence['path']] = moved(parts[stem], occurrence['matrix_mm'])
        # Independent assembly placement: local anchor (-93.775,-42.196681)
        # mates to the captured floor station (25.8,279.5); floor top is z=2.
        cls.tower = parts['segno_screen7_tower'].translate((119.575, 321.69668095881, 2.0))
        cls.obstacles['7-inch tower'] = cls.tower
        for side in ('L', 'R'):
            cls.obstacles['16-inch stand '+side] = parts['segno_screen16_stand_'+side]
        # one steel post per POST_U station (#1019); the placement follows the
        # generator so the obstacle set cannot drift from the shipped geometry
        for index, u in enumerate(enclosure.POST_U):
            cls.obstacles['steel post '+str(index)] = parts['segno_post'].translate(
                (u - enclosure.POST_PW/2.0, 138.99693697984182, 2.0))
        # Supplier image envelope at the two recorded floor placements. Using
        # its full rectangular volume is conservative around the mounting ears.
        for name, x in (('left converter', 372.15), ('right converter', 447.85)):
            cls.obstacles[name] = cq.Solid.makeBox(
                63.7, 57.6, 22.0, cq.Vector(x-31.85, 336.2, 2.0))
        cls.floor_holes = []
        cls.vents = []
        for entity in ezdxf.readfile(output/'segno_base.dxf').modelspace():
            if entity.dxftype() == 'CIRCLE' and entity.dxf.layer == 'CUT':
                x, y = entity.dxf.center.x, entity.dxf.center.y
                if 0 <= x <= 846 and 0 <= y <= 419:
                    cls.floor_holes.append((x, y, entity.dxf.radius))
            if entity.dxftype() == 'LWPOLYLINE' and entity.dxf.layer == 'VENT':
                points = list(entity.get_points())
                bounds = (min(p[0] for p in points), min(p[1] for p in points),
                          max(p[0] for p in points), max(p[1] for p in points))
                if bounds[0] >= 0 and bounds[2] <= 846 and bounds[1] >= 0 and bounds[3] <= 419:
                    cls.vents.append(bounds)
        cls.feet = [(x, y) for x, y, radius in cls.floor_holes
                    if abs(radius-2.4) < 1e-7]
        cls.other_holes = [(x, y, radius) for x, y, radius in cls.floor_holes
                           if abs(radius-2.4) >= 1e-7]

    def head(self, point):
        return cq.Solid.makeCylinder(HEAD_RADIUS, HEAD_HEIGHT,
                                     cq.Vector(*point, 2.0))

    def assert_head_clear(self, point):
        head = self.head(point)
        for name, obstacle in self.obstacles.items():
            self.assertTrue(obstacle.isValid(), name)
            # Disjoint bounding boxes provide a valid lower bound. The
            # rear-left support is INSIDE the tower bounding box, so its
            # actual hollow/flange geometry must pass the distance check.
            if box_distance(head.BoundingBox(), obstacle.BoundingBox()) <= .25:
                self.assertGreater(head.distance(obstacle), .25, name)

    def underside_clearance(self, point):
        clearances = []
        for x, y, _ in self.other_holes:
            hardware_radius = 6.0 if rounded((x, y)) in BUCK_WASHERS else 4.5
            clearances.append(math.dist(point, (x, y))-FOOT_RADIUS-hardware_radius)
        return min(clearances)

    def assert_underside_clear(self, point):
        self.assertGreater(self.underside_clearance(point), .25,
                           'Foot overlaps existing underside hardware')

    def test_fresh_cut_dxf_contains_all_twenty_unique_clearance_holes(self):
        self.assertEqual(len(self.feet), 20)
        self.assertEqual(len(set(map(rounded, self.feet))), 20)
        self.assertCountEqual(list(map(rounded, self.feet)),
                              list(map(rounded, ORIGINAL+ADDED)))
        self.assertTrue(set(map(rounded, ORIGINAL)).issubset(map(rounded, self.feet)))

    def test_heads_clear_independently_placed_printed_and_metal_parts(self):
        for point in self.feet:
            with self.subTest(point=point):
                self.assert_head_clear(point)

    def test_feet_clear_vents_other_feet_and_existing_underfloor_hardware(self):
        self.assertGreater(len(self.vents), 0)
        for point in self.feet:
            with self.subTest(point=point):
                self.assert_underside_clear(point)
                for vent in self.vents:
                    self.assertGreater(point_rectangle_distance(*point, vent)-FOOT_RADIUS, .25)
        for first, second in itertools.combinations(self.feet, 2):
            self.assertGreater(math.dist(first, second)-2*FOOT_RADIUS, .25)

    def test_rear_left_uses_tower_hollow_without_hitting_flange_or_anchor(self):
        point = (119.571429, 374.0)
        head = self.head(point)
        self.assertEqual(box_distance(head.BoundingBox(), self.tower.BoundingBox()), 0.0)
        self.assertLess(head.intersect(self.tower).Volume(), 1e-7)
        self.assertGreater(head.distance(self.tower), 4.0)
        self.assertGreater(self.underside_clearance(point), 5.4)
        self.assertGreater(self.underside_clearance((321.857143, 374.0)), 9.2)

    def test_collision_checks_reject_bad_board_and_tower_positions(self):
        # Repeating a regular row at the CLEAR/BANK depth hits the console
        # board's fixing. This must fail despite the new hole itself being
        # separated from every existing hole edge.
        bad = (524.142857, 229.968960)
        self.assertGreater(min(math.dist(bad, (x, y))-radius-2.4
                               for x, y, radius in self.other_holes), 4.0)
        self.assertLess(self.underside_clearance(bad), -4.5)
        with self.assertRaisesRegex(AssertionError, 'underside hardware'):
            self.assert_underside_clear(bad)
        # A rear support moved into the tower's flange is a real solid clash,
        # even though the tower's large bounding box already contains the
        # correct rear support too.
        blocked = self.head((150.0, 390.0))
        self.assertGreater(blocked.intersect(self.tower).Volume(), 100.0)
        with self.assertRaises(AssertionError):
            self.assert_head_clear((150.0, 390.0))


if __name__ == '__main__':
    unittest.main()
