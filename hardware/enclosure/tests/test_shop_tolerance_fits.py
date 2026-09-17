"""Laser/coating fit envelopes against purchased and native reference geometry.

These checks use the proposed +/-0.20 mm laser dimensions. Printed dimensions
are nominal: the remaining physical print/registration allowance still needs
measurement before manufacturing release.
"""
import itertools
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

import cadquery as cq
import ezdxf

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import segno_enclosure as enclosure


class ShopToleranceFitsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.output = tempfile.TemporaryDirectory(prefix='segno-shop-fit-')
        with patch.object(enclosure, 'OUT', cls.output.name):
            cls.holder = cq.importers.importStep(
                enclosure.build_ring_diffuser_step()).val()
        cls.encoder = json.loads((Path(enclosure.HERE)/'reference'/
                                  'ec11_disc_interface.json').read_text())
        path = Path(cls.output.name)/'disc.dxf'
        enclosure.dxf_ring_disc(str(path))
        cls.disc_circles = sorted(
            (e.dxf.radius*2 for e in ezdxf.readfile(path).modelspace()
             if e.dxftype() == 'CIRCLE' and e.dxf.layer == 'CUT'))

    @classmethod
    def tearDownClass(cls):
        cls.output.cleanup()

    def test_disc_can_seat_with_size_coating_and_bore_eccentricity_together(self):
        self.assertEqual(len(self.disc_circles), 2)
        bore, outside = self.disc_circles
        finished_outside = outside + .20 + 2*.10
        finished_bore = bore - .20 - 2*.10
        root_radius = self.encoder['modeled_mount']['root_max_diameter_mm']/2
        # The unchanged printed pocket is independently recorded as O51.70.
        pocket_movement = (51.70-finished_outside)/2
        root_movement = finished_bore/2-root_radius
        self.assertGreater(pocket_movement, 0)
        self.assertGreater(root_movement, 0)
        root = cq.Workplane('XY').circle(root_radius).extrude(2.2).val()
        # +/-0.20 applies relative to the disc OD centre, not twice against an
        # arbitrary global origin. The disc may settle before its nut is tight.
        for ex, ey in itertools.product((-.20, .20), repeat=2):
            with self.subTest(eccentricity=(ex, ey)):
                eccentricity = (ex*ex+ey*ey)**.5
                self.assertLess(eccentricity, pocket_movement+root_movement)
                movement = max(0, min(eccentricity,
                    (eccentricity+pocket_movement-root_movement)/2))
                dx, dy = -ex*movement/eccentricity, -ey*movement/eccentricity
                disc = (cq.Workplane('XY').circle(finished_outside/2)
                        .center(ex, ey).circle(finished_bore/2).extrude(2.2)
                        .val().translate((dx, dy, 0)))
                self.assertLess(disc.intersect(root).Volume(), 1e-7)
                self.assertLess(disc.intersect(self.holder).Volume(), 1e-7)

    def test_measured_washer_covers_maximum_bore_with_opposite_float(self):
        bore, _ = self.disc_circles
        washer = self.encoder['washer']
        bush = self.encoder['modeled_mount']['bushing_diameter_mm']
        # Check bare handling as well as the thinnest coating in the hole.
        for film in (0, .06):
            diameter = bore+.20-2*film
            offset = (diameter-bush)/2+(washer['inside_diameter_mm']-bush)/2
            aperture = cq.Workplane('XY').circle(diameter/2).extrude(.1).val()
            cover = (cq.Workplane('XY').circle(washer['outside_diameter_mm']/2)
                     .extrude(.1).val().translate((offset, 0, 0)))
            with self.subTest(film=film):
                self.assertLess(aperture.cut(cover).Volume(), 1e-7)

    def test_usb_four_flat_barrel_fits_the_smallest_finished_profiles(self):
        # Owner-supplied reference/usb3_dimensions.png, not generator constants.
        barrel = (cq.Workplane('XY').rect(22.1, 22.1).extrude(1).val()
                  .intersect(cq.Workplane('XY').circle(24.1/2).extrude(1).val()))
        openings = [f for f in enclosure.rear_io_cutouts()
                    if f['ref'] in ('USB3_1', 'USB3_2')]
        self.assertEqual(len(openings), 2)
        for feature in openings:
            with self.subTest(ref=feature['ref']):
                opening = (cq.Workplane('XY')
                           .rect(feature['w']-.40, feature['h']-.40)
                           .extrude(1).val().intersect(
                               cq.Workplane('XY').circle((feature['clip_d']-.40)/2)
                               .extrude(1).val()))
                self.assertLess(barrel.cut(opening).Volume(), 1e-7)
                # A nominal-size, unadjusted barrel cutout must fail after paint.
                undersize = (cq.Workplane('XY').rect(21.7, 21.7).extrude(1).val()
                             .intersect(cq.Workplane('XY').circle(23.7/2)
                                        .extrude(1).val()))
                self.assertGreater(barrel.cut(undersize).Volume(), 1)


if __name__ == '__main__':
    unittest.main()
