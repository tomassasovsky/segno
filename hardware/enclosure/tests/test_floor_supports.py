"""The rear rail's eight floor anchors: cutting and clearance regressions.

These checks do not establish strength or load sharing; the rated-load
answer lives in _stomp_fea.py and test_floor_rails.py. The purchased foot is
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


# The rear rail's anchors, frozen independently of base_foot_xy(). Twenty rubber
# feet became five printed rails (#1019); four of the five ride screw rows the
# floor already had, so the only bores the floor still needs are these eight --
# two per rear segment, at the same pair of offsets in each, because the four
# segments are one printed part.
#
# They are NOT where the feet were. The old row at v=374 sat on the buck
# converters' floor-side washer-and-nut stack, and an even inset along this row
# put four of the eight screw HEADS inside a converter body. Both moves are
# gated in the generator; these are the stations that come out of it.
REAR_V = 343.25
ANCHORS = ((83.428571, REAR_V), (129.428571, REAR_V),
           (285.714286, REAR_V), (331.714286, REAR_V),
           (488.0, REAR_V), (534.0, REAR_V),
           (690.285714, REAR_V), (736.285714, REAR_V))
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

    def test_fresh_cut_dxf_contains_the_eight_rear_rail_anchors(self):
        self.assertEqual(len(self.feet), 8)
        self.assertEqual(len(set(map(rounded, self.feet))), 8)
        self.assertCountEqual(list(map(rounded, self.feet)),
                              list(map(rounded, ANCHORS)))

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

    def test_two_anchors_sit_inside_the_tower_bounding_box(self):
        """Which is why assert_head_clear() may only use the box to skip work,
        never to pass a point. The 7in tower is an L in plan; its box covers a
        third of the rear rail, and the two left anchors fall inside it."""
        inside = [p for p in ANCHORS
                  if box_distance(self.head(p).BoundingBox(),
                                  self.tower.BoundingBox()) == 0.0]
        self.assertEqual(list(map(rounded, inside)),
                         list(map(rounded, ANCHORS[:2])))
        for point in inside:
            head = self.head(point)
            self.assertLess(head.intersect(self.tower).Volume(), 1e-7)
            self.assertGreater(head.distance(self.tower), 4.0)

    def test_the_tightest_anchor_is_the_one_beside_the_16in_stand(self):
        """(488, 343.25) passes 4.6 mm from the stand's rear anchor at (480, 327).
        It is the closest of the eight and the one to re-check if either moves."""
        clearances = sorted((self.underside_clearance(p), rounded(p)) for p in ANCHORS)
        self.assertEqual(clearances[0][1], (488.0, 343.25))
        self.assertGreater(clearances[0][0], 4.0)

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
