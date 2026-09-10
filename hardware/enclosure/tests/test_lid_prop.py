"""Lid props — the seven steel posts and the one printed prop (issue #1019).

Away from a pad the 2.0 mm faceplate dents at 7-11 kg of point load; over one it
takes 170 kg. #292 put two posts in front of the 16in aperture, which covered
100 mm of an 850 mm panel. These regressions hold the spread version in place:
a post at every interior pedal gap, and one printed prop in the single clear
lane beside BANK. The ligament left of CLEAR has no lane and stays bare -- see
docs/research/2026-09-09-enclosure-stomp-load-analysis.md.
"""
import math
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import segno_enclosure as enclosure


def overlaps(box, u0, u1, v0, v1):
    return box[0] < u1 and u0 < box[2] and box[1] < v1 and v0 < box[3]


class SteelPosts(unittest.TestCase):

    def setUp(self):
        self.cuts = enclosure.faceplate_holes()

    def test_one_post_per_interior_pedal_gap(self):
        self.assertEqual(list(enclosure.POST_U),
                         list(enclosure.FRONT_SCREW_U[1:-1]))
        self.assertEqual(len(enclosure.POST_U), 7)

    def test_quantity_follows_the_stations(self):
        self.assertEqual(enclosure.PART_SPECS['segno_post'][1],
                         len(enclosure.POST_U))

    def test_every_pad_bears_on_metal_that_was_not_cut_away(self):
        v0, v1 = enclosure.POST_V - enclosure.POST_PAD, enclosure.POST_V
        for u in enclosure.POST_U:
            u0, u1 = u - enclosure.POST_PW/2.0, u + enclosure.POST_PW/2.0
            for cut in self.cuts:
                with self.subTest(post=u, cut=cut.get('ref')):
                    self.assertFalse(overlaps(enclosure._bbox(cut), u0, u1, v0, v1))

    def test_pads_stay_out_of_the_led_pill_shoulders(self):
        """POST_PW is derived for this; a literal width used to break it."""
        pills = [enclosure._bbox(c) for c in self.cuts
                 if c.get('ref', '').endswith('_LEDSLOT')]
        self.assertEqual(len(pills), 10)
        for u in enclosure.POST_U:
            for box in pills:
                with self.subTest(post=u, pill=box):
                    self.assertFalse(box[0] < u + enclosure.POST_PW/2.0
                                     and u - enclosure.POST_PW/2.0 < box[2])


class PrintedProp(unittest.TestCase):

    def test_it_fits_the_only_lane_it_could_have(self):
        bank = max(u for _l, u, v in enclosure.PEDALS
                   if v != enclosure.PEDAL_ROW1_V) + enclosure.SKIRT_OUT_W/2.0
        module = enclosure.SCREEN_16_U - enclosure.BIG_BEZEL[0]/2.0
        left = enclosure.PROP_U - enclosure.PROP_W/2.0 - bank
        right = module - (enclosure.PROP_U + enclosure.PROP_W/2.0)
        self.assertGreaterEqual(left, 2.0)
        self.assertGreaterEqual(right, 2.0)
        # the lane really is narrow: this is not a case where any width would do
        self.assertLess(module - bank, 40.0)

    def test_pad_bears_on_metal(self):
        u0, u1 = enclosure.PROP_U - enclosure.PROP_W/2.0, enclosure.PROP_U + enclosure.PROP_W/2.0
        v0, v1 = enclosure.PROP_V - enclosure.PROP_D/2.0, enclosure.PROP_V + enclosure.PROP_D/2.0
        for cut in enclosure.faceplate_holes():
            with self.subTest(cut=cut.get('ref')):
                self.assertFalse(overlaps(enclosure._bbox(cut), u0, u1, v0, v1))

    def test_height_reaches_the_lid_with_the_felt_gap(self):
        expected = enclosure.lid_under_z(enclosure.PROP_V) - enclosure.T \
            - enclosure.PROP_BARE_GAP
        self.assertAlmostEqual(enclosure.PROP_H, expected, places=9)
        self.assertGreater(enclosure.PROP_H, 10.0)

    def test_it_is_one_valid_printable_solid(self):
        solid = enclosure._prop_solid()
        self.assertTrue(solid.isValid())
        box = solid.BoundingBox()
        self.assertAlmostEqual(box.zmin, 0.0, places=6)
        self.assertAlmostEqual(box.ylen, enclosure.PROP_W, places=6)
        self.assertGreater(solid.Volume(), 0.0)

    def test_its_two_floor_bolts_are_in_the_cut_file(self):
        import tempfile
        import ezdxf
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)/'segno_base.dxf'
            enclosure.dxf_base(str(path))
            bores = [(e.dxf.center.x, e.dxf.center.y)
                     for e in ezdxf.readfile(path).modelspace()
                     if e.dxftype() == 'CIRCLE' and e.dxf.layer == 'CUT'
                     and abs(e.dxf.radius - enclosure.D_M4/2.0) < 1e-7]
        for du in (-enclosure.PROP_BOLT_DU, enclosure.PROP_BOLT_DU):
            want = (enclosure.PROP_U + du, enclosure._PROP_FOOT_VP)
            with self.subTest(bolt=want):
                self.assertTrue(any(math.hypot(x-want[0], y-want[1]) < 1e-6
                                    for x, y in bores))


if __name__ == '__main__':
    unittest.main()
