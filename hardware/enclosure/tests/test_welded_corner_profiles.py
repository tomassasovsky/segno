"""Check the four weld-preparation corners against the supplier's folded sample."""
from collections import Counter
import hashlib
import json
import math
from pathlib import Path
import sys
import tempfile
import unittest

import ezdxf

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import segno_enclosure as enclosure
from flat_pattern_check import _face, validate_cut_contours


# Geometry-only records from the September 14 base, before corner preparation.
# These pin every mounting hole, ventilation opening, deferred drill and fold
# datum without retaining a second manufacturing DXF or its GUID/timestamp noise.
UNCHANGED_FEATURES = {
    # #1088 re-froze CUT on purpose: seven beam floor holes instead of fourteen,
    # every connector cutout in the rear wall instead of the panel window, the
    # earth stud centred between the vents and PD_IN, and the power group behind
    # the CLEAR/BANK pedals (both bucks moved, eight standoff holes for the
    # screen-power and PD boards), and the right 15.6in stand's four holes
    # mirrored with the left (#1070). #1090: the beam's two side-wall tie holes
    # are gone and each of the nine front stations gains its Ø1.0 laser pilot;
    # the PD coupler's M3 pair moves to the CTRL plates' diagonal; fuse, MIDI
    # and D-flange openings resized for the shop's ±0.20; two outboard beam
    # bolts so the beam takes all nine front screw stations (#1090). Later in
    # #1090 the nine front-wall pilots went again: with conventional ±0.7 bends
    # the wall holes are drilled through the seated lid's pilots instead.
    'CUT': (136, '16683ffa0fd926353ba8f5f64cbca78c81e08dc89362f49d62b5620a4ce7e127'),
    'VENT': (570, 'ddec63663b8c2670400d01a6431b1ff677d8574ec2cb33b2e0d91362fb5ab681'),
    'BEND': (5, 'ebc80b8fa031008706f13bae4e9e4fc5d213aab31402eb04c449ad7a128c3991'),
    'DRILL': (9, '034f8f332d55ffc49090ff7030430b4e375578c61a97c88984c200c48e312b60'),
}


def _number(value):
    rounded = round(float(value), 6)
    return 0.0 if rounded == 0 else rounded


def _feature_signature(entities):
    records = []
    for entity in entities:
        curves = (entity.virtual_entities()
                  if entity.dxftype() == 'LWPOLYLINE' else [entity])
        for curve in curves:
            data, kind = curve.dxf, curve.dxftype()
            if kind == 'LINE':
                ends = sorted([tuple(map(_number, (data.start.x, data.start.y))),
                               tuple(map(_number, (data.end.x, data.end.y)))])
                record = [kind, *ends]
            elif kind == 'CIRCLE':
                record = [kind, *map(_number, (data.center.x, data.center.y,
                                               data.radius))]
            elif kind == 'ARC':
                record = [kind, *map(_number, (data.center.x, data.center.y,
                                               data.radius, data.start_angle % 360,
                                               data.end_angle % 360))]
            else:
                raise AssertionError(f'Unexpected manufacturing curve: {kind}')
            records.append(record)
    records.sort(key=repr)
    encoded = json.dumps(records, separators=(',', ':')).encode()
    return len(records), hashlib.sha256(encoded).hexdigest()


class WeldedCornerProfilesTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.directory.cleanup)
        cls.path = Path(cls.directory.name) / 'base.dxf'
        enclosure.dxf_base(str(cls.path))
        cls.doc = ezdxf.readfile(cls.path)
        cls.entities = list(cls.doc.modelspace())
        outlines = [entity for entity in cls.entities
                    if entity.dxftype() == 'LWPOLYLINE'
                    and entity.dxf.layer == 'CUT']
        cls.outline = max(outlines, key=lambda entity: _face(entity).Area())
        cls.points = [tuple(map(float, point))
                      for point in cls.outline.get_points('xyb')]
        cls.curves = list(cls.outline.virtual_entities())

    def test_cut_paths_form_one_connected_sheet_without_retraced_reliefs(self):
        self.assertEqual(self.doc.units, 4)
        self.assertTrue(self.outline.closed)
        validate_cut_contours(self.path)
        self.assertEqual(len(_face(self.outline).Wires()), 1)
        # Two separate CUT polylines are internal openings (the USB four-flat
        # holes, #1088); neither may be mistaken for a second exterior or
        # silently discarded.
        counts = Counter((entity.dxf.layer, entity.dxftype())
                         for entity in self.entities
                         if entity.dxf.layer in UNCHANGED_FEATURES)
        self.assertEqual(counts, {
            ('CUT', 'LWPOLYLINE'): 3, ('CUT', 'CIRCLE'): 120,
            ('VENT', 'LWPOLYLINE'): 95, ('BEND', 'LWPOLYLINE'): 5,
            ('DRILL', 'CIRCLE'): 9,
        })

    def test_each_relief_meets_at_both_floor_bend_tangencies(self):
        # Independent neutral-axis development of the supplier's T2/R2 sample.
        # The four local frames all point into the floor, so one geometric
        # condition covers the mirrored corners without mirroring source code.
        half_bend = math.pi / 4 * (2.0 + 0.33 * 2.0)
        for corner, origin_x, origin_y, sign_x, sign_y in (
                ('front left', 0, 0, 1, 1),
                ('front right', 846, 0, -1, 1),
                ('rear left', 0, 419, 1, -1),
                ('rear right', 846, 419, -1, -1)):
            with self.subTest(corner=corner):
                local = [((x-origin_x)*sign_x, (y-origin_y)*sign_y, bulge)
                         for x, y, bulge in self.points]
                roots = [i for i, (x, y, _bulge) in enumerate(local)
                         if math.dist((x, y), (half_bend, half_bend)) < 1e-7]
                self.assertEqual(len(roots), 1)
                index = roots[0]
                before, root, after = (local[(index-1) % len(local)],
                                       local[index], local[(index+1) % len(local)])
                self.assertEqual(before[2], 0)
                self.assertEqual(root[2], 0)
                neighbours = sorted((before[:2], after[:2]))
                side_end, web_end = neighbours
                self.assertAlmostEqual(side_end[0], -half_bend, places=7)
                self.assertAlmostEqual(web_end[1], -half_bend, places=7)
                # Folding puts the inner wall at half allowance minus Ri.
                # Measure the specified gap and projected overlap from the
                # actual cut edges, not from the generator's new parameters.
                inner_plane = half_bend - 2.0
                self.assertAlmostEqual(side_end[1] - inner_plane, 0.5, places=7)
                self.assertAlmostEqual(inner_plane - web_end[0], 1.0, places=7)

    def test_front_lid_coves_keep_the_original_circle_and_upper_tangent(self):
        coves = [curve for curve in self.curves if curve.dxftype() == 'ARC'
                 and abs(curve.dxf.radius-3.0) < 1e-7
                 and curve.dxf.center.y < 10]
        self.assertEqual(len(coves), 2)
        for cove in coves:
            with self.subTest(center=cove.dxf.center):
                # September 14 lid-clearance circle and upper tangent. Moving
                # the whole cove with the side edge would encroach on the lid.
                expected_x = (-8.104890587629825 if cove.dxf.center.x < 0
                              else 854.1048905876298)
                self.assertAlmostEqual(cove.dxf.center.x, expected_x, places=7)
                self.assertAlmostEqual(cove.dxf.center.y, 3.0, places=7)
                ends = sorted((cove.start_point, cove.end_point), key=lambda p: p.y)
                self.assertAlmostEqual(ends[0].y, 0.589159114637213, places=7)
                self.assertAlmostEqual(ends[1].y, 2.35077103484194, places=7)
                self.assertAlmostEqual(abs(ends[1].x-(0 if expected_x < 0 else 846)),
                                       11.03379853271799, places=7)
        # The front wall must keep its existing top, despite the sample having
        # taller flanges. Its first/last drill remains in the original material.
        self.assertAlmostEqual(min(y for _x, y, _b in self.points),
                               -8.183938958241146, places=7)

    def test_rear_web_widens_only_through_the_upper_bend_band(self):
        hinge = 504.04508436774597  # Saved upper-fold datum; lid seat is unchanged.
        half_bend = math.radians(90-enclosure.TRANS_ANGLE) * (2+0.33*2) / 2
        transitions = [curve for curve in self.curves
                       if curve.dxftype() == 'LINE'
                       and abs((curve.dxf.start.y+curve.dxf.end.y)/2-hinge) < 1e-7
                       and abs(curve.dxf.start.x-curve.dxf.end.x) > 0.1]
        self.assertEqual(len(transitions), 2)
        for line in transitions:
            lower, upper = sorted((line.dxf.start, line.dxf.end), key=lambda p: p.y)
            self.assertAlmostEqual(lower.y, hinge-half_bend, places=7)
            self.assertAlmostEqual(upper.y, hinge+half_bend, places=7)
            origin, sign = (0, 1) if lower.x < 0 else (846, -1)
            self.assertAlmostEqual((lower.x-origin)*sign, -0.910840885362787,
                                   places=7)
            self.assertAlmostEqual((upper.x-origin)*sign, -1.9, places=7)
        tip_y = max(y for _x, y, _b in self.points)
        tip = [x for x, y, _b in self.points if abs(y-tip_y) < 1e-7]
        self.assertEqual(len(tip), 2)
        self.assertAlmostEqual(max(tip)-min(tip), 849.8, places=7)
        # Once outside the bend band, the return must be straight and full width.
        for curve in self.curves:
            if curve.dxftype() != 'LINE':
                continue
            start, end = curve.dxf.start, curve.dxf.end
            if min(start.y, end.y) >= hinge+half_bend-1e-7:
                if abs(start.y-end.y) > 1e-7:
                    self.assertAlmostEqual(start.x, end.x, places=7)
                    self.assertTrue(abs(start.x+1.9) < 1e-7
                                    or abs(start.x-847.9) < 1e-7)

    def test_every_existing_functional_cut_drill_and_fold_is_preserved(self):
        for layer, expected in UNCHANGED_FEATURES.items():
            with self.subTest(layer=layer):
                actual = _feature_signature(entity for entity in self.entities
                                            if entity is not self.outline
                                            and entity.dxf.layer == layer)
                self.assertEqual(actual, expected,
                                 f'{layer} geometry changed beyond the four corners')


if __name__ == '__main__':
    unittest.main()
