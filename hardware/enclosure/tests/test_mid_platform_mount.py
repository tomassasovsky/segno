"""Two independent short-screw joints for CLEAR/BANK; nominal fit, not strength.

The screw and driver envelopes are explicit hardware design requirements. The
printed insert fit and loaded PETG assembly still need physical verification.
"""
import math
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

import cadquery as cq
from OCP.BRepAdaptor import BRepAdaptor_Surface

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import segno_enclosure as enclosure
import _fold_from_dxf as folded


# Approved assembly datums, independent of the station helpers under test.
SEAT = 38.345008866405
CEILING = 30.345008866405
BASE_AXES = {(x, y) for x in (-48.685, 48.685)
             for y in (-22.1875, 22.1875)}
DECK_AXES = {(x, y) for x in (-30.0, 30.0) for y in (-18.0, 18.0)}
PEDAL_AXES = {(35.695, -27.875), (35.695, 27.875),
              (-44.305, -26.5), (-44.305, 26.5)}


def cylinder(radius, height, x, y, z):
    return cq.Solid.makeCylinder(radius, height, cq.Vector(x, y, z))


def bore_spans(shape, radius):
    """Read real cylindrical faces, including intact area and axial extent."""
    result = []
    for face in shape.Faces():
        if face.geomType() != 'CYLINDER':
            continue
        surface = BRepAdaptor_Surface(face.wrapped).Cylinder()
        if abs(surface.Radius()-radius) > 1e-7:
            continue
        axis = surface.Axis()
        if abs(axis.Direction().Z()) < .999999:
            continue
        bounds = face.BoundingBox()
        point = surface.Location()
        result.append(tuple(round(v, 6) for v in (
            point.X(), point.Y(), bounds.zmin, bounds.zmax, face.Area())))
    return result


class MidPlatformMountTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.output = tempfile.TemporaryDirectory(prefix='segno-mid-mount-')
        cls.addClassCleanup(cls.output.cleanup)
        with patch.object(enclosure, 'OUT', cls.output.name):
            enclosure.build_platform_steps()
        parts = {path.stem: cq.importers.importStep(str(path)).val()
                 for path in Path(cls.output.name).glob('*.step')}
        cls.collar = parts['segno_platform_mid_ring']
        cls.sled = parts['segno_platform_mid_sled']
        cls.front_collar = parts['segno_platform_front_ring']
        cls.front_sled = parts['segno_platform_sled']

    def assert_clear(self, first, second):
        overlap = first.intersect(second)
        self.assertTrue(overlap.isValid(), 'Intersection operation failed')
        self.assertLess(overlap.Volume(), 1e-7)

    def assert_inside(self, probe, part):
        missing = probe.cut(part)
        self.assertTrue(missing.isValid(), 'Containment operation failed')
        self.assertLess(missing.Volume(), 1e-7)

    def test_floor_pockets_are_blind_and_keep_the_existing_column_axes(self):
        self.assertTrue(self.collar.isValid())
        self.assertEqual(len(self.collar.Solids()), 1)
        self.assertCountEqual(bore_spans(self.collar, 2.25), [
            (x, y, 0.0, 6.0, round(2*math.pi*2.25*6, 6))
            for x, y in BASE_AXES])
        for x, y in BASE_AXES:
            with self.subTest(axis=(x, y)):
                self.assert_clear(cylinder(2.25, 6, x, y, 0), self.collar)
                # The lower pilot has a solid roof, and the rest of the old
                # long passage is filled right through the column and deck.
                self.assert_inside(cylinder(2.2, SEAT-6.1, x, y, 6.1), self.collar)
                # A real Ø5 insert leaves 3.5 mm nominal radial column wall.
                # Test its whole support annulus, not just the outside bounds.
                shell = cylinder(5.99, 5.8, x, y, .1).cut(
                    cylinder(2.5, 5.8, x, y, .1))
                self.assert_inside(shell, self.collar)

    def test_m3_by_6_base_screws_have_reach_and_blind_tip_clearance(self):
        for x, y in BASE_AXES:
            with self.subTest(axis=(x, y)):
                # Local Z=0 is the platform floor. A 2 mm metal sheet plus
                # up to 0.2 mm total coating leaves 3.8–4 mm screw insertion.
                for grip in (2.0, 2.2):
                    shaft = cylinder(1.5, 6.0, x, y, -grip)
                    head = cylinder(3.0, 3.0, x, y, -grip-3.0)
                    self.assert_clear(shaft.fuse(head), self.collar)
                    insertion = 6.0-grip
                    self.assertGreaterEqual(insertion, 3.8)
                    # A 5 mm insert does not bottom the screw; the 6 mm pilot
                    # also retains at least 2 mm of tip room to its blind roof.
                    self.assertLessEqual(insertion, 4.0)
                    self.assert_inside(cylinder(1.5, insertion, x, y, 0),
                                       cylinder(2.25, 6.0, x, y, 0))
                    self.assertGreaterEqual(6.0-insertion, 2.0)

    def test_independent_deck_pattern_allows_short_screws_and_straight_tools(self):
        self.assertCountEqual(bore_spans(self.collar, 1.85), [
            (x, y, round(CEILING, 6), round(SEAT, 6),
             round(2*math.pi*1.85*8, 6)) for x, y in DECK_AXES])
        seated = self.sled.translate((0, 0, SEAT))
        assembly = self.collar.fuse(seated)
        for x, y in DECK_AXES:
            with self.subTest(axis=(x, y)):
                # The M3×12 head bears on the underside of an intact 8 mm
                # deck; its shaft enters the matching sled insert by 4 mm.
                shaft = cylinder(1.5, 12, x, y, CEILING)
                head = cylinder(3.0, 3.0, x, y, CEILING-3.0)
                driver = cylinder(4.0, CEILING+7.0, x, y, -10.0)
                self.assert_clear(shaft.fuse(head), assembly)
                self.assert_clear(driver, self.collar)
                self.assertLess(head.distance(self.collar), 1e-6)
                self.assert_inside(cylinder(1.5, 4, x, y, SEAT),
                                   cylinder(2.25, 6, x, y, SEAT))
                # A missing or shifted hole cannot pass merely because the
                # screw happened to be placed in the empty underside cavity.
                self.assertGreater(shaft.translate((6, 0, 0)).intersect(
                    self.collar).Volume(), 20.0)
                bearing = cylinder(3, .2, x, y, CEILING).cut(
                    cylinder(1.85, .2, x, y, CEILING))
                self.assert_inside(bearing, self.collar)

    def test_mid_sled_changes_only_the_bottom_insert_pattern(self):
        self.assertTrue(self.sled.isValid())
        self.assertEqual(len(self.sled.Solids()), 1)
        area = round(2*math.pi*2.25*6, 6)
        self.assertCountEqual(bore_spans(self.sled, 2.25), [
            (x, y, 6.633, 12.633, area) for x, y in PEDAL_AXES
        ]+[(x, y, 0.0, 6.0, area) for x, y in DECK_AXES])
        lower_envelopes = []
        for x, y in DECK_AXES:
            # The bottom insert has a closed roof, ample radial material,
            # and no intersection with the pedal inserts from the other face.
            self.assert_inside(cylinder(2.25, .5, x, y, 6.0), self.sled)
            shell = cylinder(5, 5.8, x, y, .1).cut(
                cylinder(2.5, 5.8, x, y, .1))
            self.assert_inside(shell, self.sled)
            lower_envelopes.append(cylinder(2.5, 5, x, y, 0))
        top_envelopes = [cylinder(2.5, 5, x, y, 7.633) for x, y in PEDAL_AXES]
        self.assertGreater(min(a.distance(b) for a in lower_envelopes
                               for b in top_envelopes), 6.3)
        for x, y in BASE_AXES:
            self.assert_inside(cylinder(2.25, 5.8, x, y, .1), self.sled)
        # Changes outside the eight old/new lower pocket volumes would move
        # the seating outline, toe relief or top pedal mounting interface.
        pocket_regions = cq.Compound.makeCompound([
            cylinder(2.3, 6.01, x, y, 0) for x, y in BASE_AXES | DECK_AXES])
        self.assert_inside(self.sled.cut(self.front_sled), pocket_regions)
        self.assert_inside(self.front_sled.cut(self.sled), pocket_regions)

    def test_sled_can_be_lowered_and_removed_without_hitting_the_collar(self):
        for lift in (0, 1, 4, 12, 50):
            with self.subTest(lift=lift):
                self.assert_clear(self.sled.translate((0, 0, SEAT+lift)), self.collar)
        self.assertLess(self.sled.translate((0, 0, SEAT)).distance(self.collar), 1e-6)

    def test_dxf_validator_assembles_the_exported_front_and_mid_parts(self):
        # Exercise the validator's real platform-building path. Its independent
        # metal and electronics builders are excluded: reconstructing those
        # DXFs is unrelated to whether it picks the right printed variants.
        omitted = {name: Mock(return_value=[]) for name in (
            'fold_base', 'corner_joins', 'pcb_parts', 'rear_panels', 'fold_faceplate')}
        with patch.multiple(folded, **omitted):
            parts = dict(folded.build())
        self.assertCountEqual(parts, [f'{kind}{i}' for kind in ('ring', 'sled', 'pedal')
                                      for i in range(10)])
        # Frozen physical placements in the bottom-base frame. Matching the
        # exported solids in both Boolean directions detects a stale sled,
        # old 0.85 mm baffle, wrong row height, or wrong assembly rotation.
        positions = [(u, 66.198026483627) for u in (
            69.0, 170.142857142857, 271.285714285714, 372.428571428571,
            473.571428571429, 574.714285714286, 675.857142857143, 777.0)]
        positions += [(271.285714285714, 229.968960454124),
                      (372.428571428571, 229.968960454124)]
        for i, (u, v) in enumerate(positions):
            mid = i >= 8
            seat = SEAT if mid else 2.043139371686
            expected = {'ring': (self.collar if mid else self.front_collar, 2.0),
                        'sled': (self.sled if mid else self.front_sled, 2.0+seat)}
            for kind, (exported, z) in expected.items():
                with self.subTest(part=f'{kind}{i}'):
                    local = parts[f'{kind}{i}'].translate((-u, -v, -z)).rotate(
                        (0, 0, 0), (0, 0, 1), -90)
                    self.assertTrue(local.isValid())
                    self.assertEqual(len(local.Solids()), 1)
                    self.assertLess(local.cut(exported).Volume(), 1e-6)
                    self.assertLess(exported.cut(local).Volume(), 1e-6)


if __name__ == '__main__':
    unittest.main()
