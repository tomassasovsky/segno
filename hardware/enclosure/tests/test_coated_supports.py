"""Printed interfaces against independent pre-coating assembly measurements."""
import itertools
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

import cadquery as cq
import numpy as np
from OCP.BRepAdaptor import BRepAdaptor_Surface
from OCP.gp import gp_Trsf

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import segno_enclosure as enclosure


def moved(shape, matrix):
    transform = gp_Trsf()
    transform.SetValues(*(v for row in matrix[:3] for v in row))
    return shape.moved(cq.Location(transform))


def floor_faces(shape):
    return sorted([
        round(face.Area(), 6),
        sorted([round(value, 6) for value in vertex.Center().toTuple()]
               for vertex in face.Vertices()),
    ] for face in shape.Faces() if face.geomType() == 'PLANE'
        and face.normalAt().z < -.99999 and face.Center().z < 2.01)


def cylinders(shape, radius, floor_only=False):
    rows = []
    for face in shape.Faces():
        if face.geomType() != 'CYLINDER':
            continue
        cylinder = BRepAdaptor_Surface(face.wrapped).Cylinder()
        if abs(cylinder.Radius()-radius) > 1e-7:
            continue
        bounds = face.BoundingBox()
        if floor_only and not (abs(cylinder.Axis().Direction().Z()) > .99999
                               and bounds.zmax <= 7.001):
            continue
        center = cylinder.Location()
        rows.append([round(value, 6) for value in (
            center.X(), center.Y(), bounds.zmin, bounds.zmax, face.Area())])
    return sorted(rows)


class CoatedSupportTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        here = Path(enclosure.HERE)
        cls.reference = json.loads((here/'reference/coated_support_datums.json').read_text())
        seats = json.loads((here/'reference/coated_seat_datums.json').read_text())
        cls.normal = cq.Vector(0, *seats['main_normal_yz'])
        cls.seat_equations = np.array([
            seats['main_normal_yz'], seats['rear_normal_yz']])
        cls.output = tempfile.TemporaryDirectory(prefix='segno-coated-supports-')
        with patch.object(enclosure, 'OUT', cls.output.name):
            enclosure.build_platform_steps()
            enclosure.build_screen7_tower_step()
            enclosure.build_screen16_stand_steps()
            enclosure.build_screen16_monitor_step()
        cls.parts = {
            file.stem: cq.importers.importStep(str(file)).val()
            for file in Path(cls.output.name).glob('*.step')
        }
        cls.lid = moved(cq.importers.importStep(str(
            here/'formed/segno_faceplate.step')).val(), cls.reference['lid_matrix_mm'])

    @classmethod
    def tearDownClass(cls):
        cls.output.cleanup()

    def assert_clear(self, first, second, minimum_distance):
        contact = first.intersect(second)
        self.assertTrue(contact.isValid(), 'Intersection operation failed')
        self.assertLess(contact.Volume(), 1e-6)
        self.assertGreater(first.distance(second), minimum_distance)

    def painted_lids(self):
        # Side/rear seat films are independent of the local film under a
        # printed support. Maximum local lid and floor films are 0.10 mm.
        # Cancelling those local terms with remote seat film hides a clash.
        for side, rear in itertools.product((.12, .20), repeat=2):
            dy, dz = np.linalg.solve(self.seat_equations, [side, rear])
            yield self.lid.translate((
                0, float(dy)-.10*self.normal.y,
                float(dz)-.10*self.normal.z))

    def test_all_twenty_console_supports_clear_independent_coating_extremes(self):
        occurrences = self.reference['support_occurrences']
        self.assertEqual(len(occurrences), 20)
        painted = list(self.painted_lids())
        for occurrence in occurrences:
            with self.subTest(occurrence=occurrence['path']):
                stem = occurrence['part']
                # The captured CLEAR/BANK sleds retain their old transforms;
                # their new lower pattern belongs to the dedicated mid part.
                if stem == 'segno_platform_sled' and occurrence['matrix_mm'][2][3] > 20:
                    stem = 'segno_platform_mid_sled'
                part = moved(self.parts[stem], occurrence['matrix_mm']).translate((0, 0, .10))
                self.assertTrue(part.isValid())
                for lid in painted:
                    # The minimum observed with all remote/local extrema is
                    # 0.10194 mm. A missing relief fails by actual overlap.
                    self.assert_clear(part, lid, .10)

    def test_all_floor_interfaces_and_eight_full_insert_walls_survive(self):
        anchor_count = 0
        for stem, expected in self.reference['screen_floor_interfaces'].items():
            with self.subTest(part=stem):
                part = self.parts[stem]
                self.assertTrue(part.isValid())
                self.assertEqual(len(part.Solids()), 1)
                self.assertEqual(floor_faces(part), expected['floor_faces'])
                measured = cylinders(part, 1.6, floor_only=True)
                self.assertEqual(measured, expected['anchor_cylinders'])
                anchor_count += len(measured)
        self.assertEqual(anchor_count, 14)
        inserts = cylinders(self.parts['segno_platform_sled'], 2.25)
        self.assertEqual(len(inserts), 8)
        # Includes full surface area, so a lower cut clipping the front pilot
        # mouths cannot pass merely because its axis and bounding span remain.
        self.assertEqual(inserts, self.reference['sled_insert_cylinders'])

    def test_screen16_remains_seated_on_both_stands_and_clears_coated_lid(self):
        monitor = self.parts['segno_screen16_monitor']
        for side in ('L', 'R'):
            stand = self.parts['segno_screen16_stand_'+side]
            contact = stand.intersect(monitor)
            self.assertTrue(contact.isValid())
            self.assertLess(contact.Volume(), 1e-6)
            self.assertLess(stand.distance(monitor), 1e-6)
        for lid in self.painted_lids():
            self.assert_clear(monitor.translate((0, 0, .10)), lid, .12)


if __name__ == '__main__':
    unittest.main()
