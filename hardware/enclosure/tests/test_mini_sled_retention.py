"""Two-point mini sled retention, checked on the generated mating solids."""
import math
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

import cadquery as cq

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import segno_enclosure as enclosure


class MiniSledRetentionTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.output = tempfile.TemporaryDirectory(prefix='segno-mini-retention-')
        with patch.object(enclosure, 'OUT', cls.output.name):
            enclosure.build_mini_console()
            enclosure.build_diffuser_step()
        cls.tray = cq.importers.importStep(str(
            Path(cls.output.name)/'segno_mini_console_tray.step')).val()
        cls.sled = cq.importers.importStep(str(
            Path(cls.output.name)/'segno_mini_console_sled.step')).val()
        cls.diffuser = cq.importers.importStep(str(
            Path(cls.output.name)/'segno_led_diffuser.step')).val()
        cls.assembly = cq.importers.importStep(str(
            Path(cls.output.name)/'segno_mini_console_assembly.step')).val()

    @classmethod
    def tearDownClass(cls):
        cls.output.cleanup()

    def assert_no_intersection(self, first, second, tolerance=1e-6):
        result = first.intersect(second)
        self.assertTrue(result.isValid(), 'Boolean intersection failed')
        self.assertLess(result.Volume(), tolerance)

    def test_two_blind_bottom_inserts_preserve_pedal_holes_and_roofs(self):
        self.assertTrue(self.sled.isValid())
        self.assertEqual(len(self.sled.Solids()), 1)
        axes = []
        for face in self.sled.Faces():
            if face.geomType() != 'CYLINDER':
                continue
            geom = face._geomAdaptor()
            if abs(geom.Radius()-2.25) > 1e-6:
                continue
            center = geom.Axis().Location()
            bb = face.BoundingBox()
            axes.append((round(center.X(), 3), round(center.Y(), 3),
                         round(bb.zmin, 3), round(bb.zmax, 3)))
        # Literal caliper-derived top pattern and the new separated lower pair.
        self.assertCountEqual(axes, [
            (35.695, -27.875, 1.0, 7.0), (35.695, 27.875, 1.0, 7.0),
            (-44.305, -26.5, 1.0, 7.0), (-44.305, 26.5, 1.0, 7.0),
            (-30.0, 0.0, 0.0, 6.0), (30.0, 0.0, 0.0, 6.0),
        ])
        for x in (-30, 30):
            roof = cq.Solid.makeCylinder(2.25, .8, cq.Vector(x, 0, 6.1))
            self.assertLess(roof.cut(self.sled).Volume(), 1e-7)
        # The obsolete central pilot must be filled, not retained as a third
        # hole or substituted for one of the two requested retention stations.
        center_web = cq.Solid.makeCylinder(2.2, 5.8, cq.Vector(0, 0, .1))
        self.assertLess(center_web.cut(self.sled).Volume(), 1e-7)
        top = [(35.695, -27.875), (35.695, 27.875),
               (-44.305, -26.5), (-44.305, 26.5)]
        self.assertGreater(min(math.dist((x, 0), h)-5
                               for x in (-30, 30) for h in top), 23.4)

    def test_both_tray_stations_have_head_access_and_screw_reach(self):
        # Positions independently read from the tray's two full tub bores;
        # source station-list agreement alone cannot establish the matching cut.
        bores = []
        for face in self.tray.Faces():
            if face.geomType() != 'CYLINDER':
                continue
            geom = face._geomAdaptor()
            if abs(geom.Radius()-1.75) > 1e-6:
                continue
            loc = geom.Axis().Location()
            if abs(abs(geom.Axis().Direction().Z())-1) < 1e-6:
                bores.append((round(loc.X(), 6), round(loc.Y(), 6)))
        bores = sorted(set(bores))
        self.assertEqual(len(bores), 4)
        xs = sorted({x for x, _ in bores})
        ys = sorted({y for _, y in bores})
        self.assertEqual(len(xs), 2)
        self.assertEqual(len(ys), 2)
        self.assertAlmostEqual(ys[1]-ys[0], 60.0, places=5)
        self.assertAlmostEqual((ys[0]+ys[1])/2, 66.19802648362678, places=5)
        self.assertEqual(bores, [(x, y) for x in xs for y in ys])
        for x, y in bores:
            # 8 mm tool through an 8.5 mm pocket from beneath the table plane.
            tool = cq.Solid.makeCylinder(4.0, 24.69, cq.Vector(x, y, -20))
            self.assert_no_intersection(tool, self.tray)
            head = cq.Solid.makeCylinder(2.85, 1.65, cq.Vector(x, y, 3.05))
            shaft = cq.Solid.makeCylinder(1.5, 10.0, cq.Vector(x, y, 4.7))
            self.assert_no_intersection(head.fuse(shaft), self.tray)
            seated_sled = self.sled.rotate((0, 0, 0), (0, 0, 1), 90).translate(
                (x, 66.19802648362678, 10.876139371685532))
            self.assert_no_intersection(shaft, seated_sled)
            # The screw must actually enter the matching lower pilot: just
            # missing both parts would otherwise pass a no-overlap test.
            inserted = cq.Solid.makeCylinder(1.5, 3.8,
                cq.Vector(x, y, 10.876139371685532))
            pilot = cq.Solid.makeCylinder(2.25, 6.0,
                cq.Vector(x, y, 10.876139371685532))
            self.assertLess(inserted.cut(pilot).Volume(), 1e-7)
            self.assert_no_intersection(pilot, seated_sled, 1e-5)
            # A stale/omitted station or displaced floor passage is observable.
            blocked = shaft.translate((6, 0, 0))
            self.assertGreater(blocked.intersect(self.tray).Volume(), 20)

    def test_reference_contains_both_sleds_and_allows_vertical_insertion(self):
        solids = self.assembly.Solids()
        self.assertEqual(len(solids), 4)
        sleds = [s for s in solids if abs(s.Volume()-self.sled.Volume()) < .001]
        self.assertEqual(len(sleds), 2)
        for sled in sleds:
            self.assertAlmostEqual(sled.BoundingBox().zmin, 10.876139371685532,
                                   places=6)
            for dz in (0, 1, 4, 8, 15):
                self.assert_no_intersection(sled.translate((0, 0, dz)), self.tray)


    def test_lid_clears_sleds_and_current_pill_diffusers(self):
        solids = self.assembly.Solids()
        lid = min(solids, key=lambda part: part.Volume())
        for i, first in enumerate(solids):
            for second in solids[i+1:]:
                self.assert_no_intersection(first, second)
        c = math.cos(math.radians(12.498241812070852))
        sn = math.sin(math.radians(12.498241812070852))
        # Current shared pill dimensions and the actual mini slot centre.
        v = 141.6096423473707
        for x in (47.075, 148.2178571428571):
            for glue in (0, .2):
                pill = self.diffuser.rotate((0, 0, 0), (1, 0, 0),
                    12.498241812070852).translate(
                    (x, c*v+sn*glue, 13.593+sn*v-c*glue))
                for part in solids:
                    self.assert_no_intersection(pill, part)
        # Restoring the old rectangular toe reproduces the omitted interface.
        old_sled = (cq.Workplane('XY').box(113.27, 78.75, 7,
                    centered=(True, True, False)).edges('|Z').fillet(3)
                    .faces('<Z').chamfer(.6).val()
                    .rotate((0, 0, 0), (0, 0, 1), 90)
                    .translate((47.075, 66.19802648362678, 10.876139371685532)))
        clash = old_sled.intersect(lid)
        self.assertTrue(clash.isValid())
        self.assertGreater(clash.Volume(), 9)
        # The relocated rear tabs must also clear the existing board pocket and
        # complete USB-window bounding envelope. This checks the modeled bay;
        # an absent purchased board/plug is not invented as a proof fixture.
        cx = 195.29285714285712/2
        board_pocket = cq.Workplane('XY').box(34.2, 18.8, 3,
            centered=(True, False, False)).translate(
                (cx, 156.20842373802842-3.2-18.8, 5)).val()
        usb_window = cq.Workplane('XY').box(12, 5.2, 9.767014,
            centered=(True, False, False)).translate(
                (cx, 156.20842373802842-4.2, 5.8)).val()
        self.assert_no_intersection(lid, board_pocket)
        self.assert_no_intersection(lid, usb_window)

if __name__ == '__main__':
    unittest.main()
