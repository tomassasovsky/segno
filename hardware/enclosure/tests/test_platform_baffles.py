"""Console collar wall and mating geometry; these are not strength tests."""
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

import cadquery as cq
from OCP.BRepAdaptor import BRepAdaptor_Surface

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import segno_enclosure as enclosure


# Existing assembly datums, independent of the collar's enlarged outside.
SEATS = {'front': 2.043139371686, 'mid': 38.345008866405}
ANCHORS = {(x, y) for x in (-48.685, 48.685)
           for y in (-22.1875, 22.1875)}


class PlatformBaffleTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.output = tempfile.TemporaryDirectory(prefix='segno-platform-baffles-')
        cls.addClassCleanup(cls.output.cleanup)
        with patch.object(enclosure, 'OUT', cls.output.name):
            enclosure.build_platform_steps()
        cls.parts = {
            path.stem: cq.importers.importStep(str(path)).val()
            for path in Path(cls.output.name).glob('*.step')
        }
        cls.collars = {tag: cls.parts['segno_platform_'+tag+'_ring']
                       for tag in SEATS}
        cls.sleds = {'front': cls.parts['segno_platform_sled'],
                     'mid': cls.parts['segno_platform_mid_sled']}

    def test_front_and_rear_walls_are_2_4_mm_without_shrinking_the_opening(self):
        for tag, collar in self.collars.items():
            with self.subTest(collar=tag):
                self.assertTrue(collar.isValid())
                self.assertEqual(len(collar.Solids()), 1)
                bounds = collar.BoundingBox()
                self.assertAlmostEqual(bounds.xlen, 118.47, places=6)
                self.assertAlmostEqual(bounds.ylen, 88.75, places=6)
                # Cut across both depth walls above the sled seat and away
                # from the rear cable notch. Measuring solid sections catches
                # a wall enlarged inward or left at the old 0.85 mm thickness.
                probe = cq.Solid.makeBox(
                    120, 1, 1, cq.Vector(-60, 10, SEATS[tag]+5))
                section = collar.intersect(probe)
                self.assertTrue(section.isValid())
                walls = sorted(section.Solids(), key=lambda wall: wall.Center().x)
                self.assertEqual(len(walls), 2)
                for wall, limits in zip(walls, ((-59.235, -56.835),
                                               (56.835, 59.235))):
                    self.assertAlmostEqual(wall.BoundingBox().xmin, limits[0], places=6)
                    self.assertAlmostEqual(wall.BoundingBox().xmax, limits[1], places=6)
                    self.assertAlmostEqual(wall.Volume(), 2.4, places=6)

    def test_cable_hole_is_a_closed_8_6_by_13_5_mm_vertical_stadium(self):
        for tag, collar in self.collars.items():
            with self.subTest(collar=tag):
                # The bare pedal case rests on the sled, without its bottom
                # pad. Keep this physical datum independent of the generator's
                # cable-cut constants so an offset from the collar floor fails.
                case_bottom = SEATS[tag]+12.633
                hole_bottom = case_bottom+6.95
                hole_top = case_bottom+20.45
                # An independent capsule made from cylinders and a box checks
                # the exact R4.3 ends and 4.9 mm straight sides, not merely a
                # bounding rectangle that could hide a different corner radius.
                passage = cq.Solid.makeBox(
                    4, 8.6, 4.9,
                    cq.Vector(56, -4.3, hole_bottom+4.3))
                for z in (hole_bottom+4.3, hole_top-4.3):
                    passage = passage.fuse(cq.Solid.makeCylinder(
                        4.3, 4, cq.Vector(56, 0, z), cq.Vector(1, 0, 0)))
                self.assertLess(collar.intersect(passage).Volume(), 1e-7)
                wall_box = cq.Solid.makeBox(
                    2.4, 8.6, 13.5,
                    cq.Vector(56.835, -4.3, hole_bottom))
                actual_void = wall_box.cut(collar)
                expected_void = wall_box.intersect(passage)
                self.assertLess(actual_void.cut(expected_void).Volume(), 1e-7)
                self.assertLess(expected_void.cut(actual_void).Volume(), 1e-7)
                # Check the whole 2.4 mm wall thickness. Both bridges and
                # side edges must exist: an open-top slot, removed wall or
                # oversized hole must not pass an empty-volume check.
                for z in (hole_bottom-.1, hole_top):
                    bridge = cq.Solid.makeBox(
                        2.4, 8.6, .1,
                        cq.Vector(56.835, -4.3, z))
                    self.assertAlmostEqual(
                        collar.intersect(bridge).Volume(), 2.4*8.6*.1, places=6)
                for y in (-4.4, 4.3):
                    edge = cq.Solid.makeBox(
                        2.4, .1, 13.5,
                        cq.Vector(56.835, y, hole_bottom))
                    self.assertAlmostEqual(
                        collar.intersect(edge).Volume(), 2.4*.1*13.5, places=6)
                for y in (-4.3, 4.2):
                    for z in (hole_bottom, hole_top-.1):
                        corner = cq.Solid.makeBox(
                            2.4, .1, .1, cq.Vector(56.835, y, z))
                        self.assertAlmostEqual(
                            collar.intersect(corner).Volume(), .024, places=6)

    def test_stadium_cable_can_thread_with_0_5_mm_clearance_at_both_heights(self):
        for tag, collar in self.collars.items():
            for lower_offset in (7.45, 8.5):
                with self.subTest(collar=tag, cable_bottom=lower_offset):
                    # The approximate top/bottom measurements imply two
                    # possible positions for the same 7.6 x 11.45 mm feature,
                    # assumed to have the user's requested stadium profile.
                    # Offset that profile by 0.5 mm and sweep horizontally
                    # through the whole rear wall. This does not qualify an
                    # unmeasured physical profile or a rectangular fitting.
                    z = SEATS[tag]+12.633+lower_offset-.5
                    envelope = cq.Solid.makeBox(
                        4, 8.6, 3.85, cq.Vector(56, -4.3, z+4.3))
                    for center_z in (z+4.3, z+12.45-4.3):
                        envelope = envelope.fuse(cq.Solid.makeCylinder(
                            4.3, 4, cq.Vector(56, 0, center_z), cq.Vector(1, 0, 0)))
                    self.assertLess(collar.intersect(envelope).Volume(), 1e-7)

    def test_front_through_holes_keep_the_existing_base_and_sled_stations(self):
        collar = self.collars['front']
        measured = []
        for face in collar.Faces():
            if face.geomType() != 'CYLINDER':
                continue
            cylinder = BRepAdaptor_Surface(face.wrapped).Cylinder()
            if abs(cylinder.Radius()-1.85) > 1e-7:
                continue
            self.assertGreater(abs(cylinder.Axis().Direction().Z()), .999999)
            center = cylinder.Location()
            measured.append((round(center.X(), 6), round(center.Y(), 6)))
            bounds = face.BoundingBox()
            self.assertAlmostEqual(bounds.zmin, 0, places=6)
            self.assertAlmostEqual(bounds.zmax, SEATS['front'], places=6)
        self.assertCountEqual(measured, ANCHORS)
        assembly = collar.fuse(self.sleds['front'].translate((0, 0, SEATS['front'])))
        for x, y in ANCHORS:
            # The front-row M3 shaft still passes through the collar and into
            # its sled. The tall assembly now has a separate mounting test.
            shaft = cq.Solid.makeCylinder(
                1.5, SEATS['front']+5, cq.Vector(x, y, 0))
            self.assertLess(assembly.intersect(shaft).Volume(), 1e-7)

    def test_row_sleds_seat_and_retain_0_2_mm_sliding_clearance(self):
        for tag, collar in self.collars.items():
            with self.subTest(collar=tag):
                sled = self.sleds[tag]
                bounds = sled.BoundingBox()
                self.assertAlmostEqual(bounds.xlen, 113.27, places=6)
                self.assertAlmostEqual(bounds.ylen, 78.75, places=6)
                self.assertAlmostEqual(bounds.zlen, 12.633, places=6)
                seated = sled.translate((0, 0, SEATS[tag]))
                self.assertLess(collar.intersect(seated).Volume(), 1e-7)
                self.assertLess(collar.distance(seated), 1e-6)
                # A short horizontal slice avoids the seat contact and toe
                # relief. The resulting side gap is the actual fit clearance.
                slab = cq.Solid.makeBox(
                    130, 100, 1, cq.Vector(-65, -50, SEATS[tag]+1))
                ring_slice = collar.intersect(slab)
                sled_slice = seated.intersect(slab)
                self.assertAlmostEqual(ring_slice.distance(sled_slice), .2, places=6)


if __name__ == '__main__':
    unittest.main()
