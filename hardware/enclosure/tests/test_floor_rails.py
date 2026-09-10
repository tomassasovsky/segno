"""Floor rails — the supports that carry a stomp (issue #1019).

Five printed PETG rails, each holding a self-adhesive solid neoprene strip, on
screw rows the floor already had. 52 MPa and 0.23 mm at a 1 kN stomp against
353 MPa and 23 mm for the plate as drawn. `_stomp_fea.py` is the model; these
are the regressions that keep the fix intact.

Three of these guard mistakes that were actually made and caught here:
a segment left holding one screw pivots about it, an equal-length split makes
those, and the intake vent field collapsed 72% when the posts spread without
anyone noticing, because the all-vents gate sums intake and exhaust.
"""
import math
from pathlib import Path
import sys
import tempfile
import unittest

import ezdxf

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import segno_enclosure as enclosure


class RailLayout(unittest.TestCase):

    def setUp(self):
        self.rails = enclosure.floor_rail_lines()
        self.segments = enclosure.floor_rail_segments()

    def test_five_rails_on_rows_the_floor_already_had(self):
        self.assertEqual([r[0] for r in self.rails],
                         ['front_a', 'front_b', 'mid_a', 'mid_b', 'rear'])
        for name, _v, u0, u1, screws in self.rails:
            with self.subTest(rail=name):
                self.assertGreaterEqual(len([s for s in screws if u0 <= s <= u1]), 2)

    def test_no_rail_adds_a_bore_to_the_cut_file(self):
        """The whole economy of this fix. Read it back out of a fresh DXF."""
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'segno_base.dxf'
            enclosure.dxf_base(str(path))
            bores = {(round(e.dxf.center.x, 3), round(e.dxf.center.y, 3))
                     for e in ezdxf.readfile(path).modelspace()
                     if e.dxftype() == 'CIRCLE' and e.dxf.layer == 'CUT'}
        for name, v, u0, u1, screws in self.rails:
            for s in (x for x in screws if u0 <= x <= u1):
                hit = any(abs(bx - s) < 0.01 and abs(by - v) < 60.0
                          for bx, by in bores)
                with self.subTest(rail=name, screw=round(s, 2)):
                    self.assertTrue(hit, 'rail screw is not on an existing bore')

    def test_every_segment_holds_two_screws(self):
        """A segment on one screw pivots about it. The equal split made two."""
        for name, k, _a, _b, on in self.segments:
            with self.subTest(rail=name, seg=k):
                self.assertGreaterEqual(len(on), 2)

    def test_every_segment_fits_the_bed(self):
        for name, k, a, b, _on in self.segments:
            with self.subTest(rail=name, seg=k):
                self.assertLessEqual(b - a, enclosure.RAIL_MAXLEN)

    def test_the_split_takes_the_fewest_segments_not_the_shortest(self):
        """Optimising length alone chopped the rail into 40 mm confetti."""
        self.assertEqual(len(self.segments), 17)

    def test_rails_clear_the_bend_relief_and_each_other(self):
        BD = enclosure.D - 2 * enclosure.T
        half = enclosure.RAIL_W / 2.0
        for name, v, _u0, _u1, _s in self.rails:
            with self.subTest(rail=name):
                self.assertGreaterEqual(v - half, enclosure.RAIL_EDGE_MIN)
                self.assertLessEqual(v + half, BD - enclosure.RAIL_EDGE_MIN)
        for i, (na, va, a0, a1, _s) in enumerate(self.rails):
            for nb, vb, b0, b1, _t in self.rails[i + 1:]:
                with self.subTest(a=na, b=nb):
                    self.assertTrue(abs(va - vb) > enclosure.RAIL_W
                                    or a1 < b0 or b1 < a0)


class Strip(unittest.TestCase):

    def test_the_strip_reaches_the_floor(self):
        proud = enclosure.TAPE_T - enclosure.RAIL_CH_D
        self.assertGreater(proud, 0.5, 'the rubber has to touch the ground')
        self.assertAlmostEqual(enclosure.RIDE_H, enclosure.RAIL_T + proud, places=9)

    def test_the_channel_captures_the_strip_rather_than_gluing_it(self):
        self.assertLess(enclosure.RAIL_CH_W, enclosure.TAPE_W)
        self.assertGreaterEqual((enclosure.RAIL_W - enclosure.RAIL_CH_W) / 2.0, 0.8)

    def test_the_screw_head_stays_out_of_the_channel(self):
        """So the strip runs over it unbroken and never needs punching."""
        over = enclosure.RAIL_T - enclosure.RAIL_CH_D - enclosure.RAIL_CBORE_H
        self.assertGreaterEqual(over, 1.5)
        self.assertGreater(enclosure.RAIL_CBORE_D, enclosure.D_M3_METAL)

    def test_one_twenty_foot_roll_covers_the_set(self):
        need = sum((b - a) - 2 * enclosure.RAIL_END_INSET
                   for _n, _k, a, b, _o in enclosure.floor_rail_segments())
        self.assertLess(need, 20 * 304.8)
        self.assertGreater(need, 10 * 304.8 * 0.9,
                           'a 10 ft roll would be uncomfortably tight; keep this honest')


class Intake(unittest.TestCase):
    """The posts ate 72% of the intake and the all-vents gate did not notice."""

    def test_intake_is_gated_on_its_own(self):
        area = enclosure._vent_free_area(enclosure._bottom_vents())
        self.assertGreaterEqual(area, enclosure.VENT_INTAKE_MIN)

    def test_columns_sit_in_the_gaps_between_post_feet(self):
        raw = 4 * (len(enclosure._ROW1) - 2)
        kept = [c for c in enclosure._bottom_vents_local(
            enclosure.W - 2 * enclosure.T, enclosure.D - 2 * enclosure.T)
            if c.get('kind') == 'rect']
        self.assertEqual(len(kept), raw,
                         'the post keep-out is dropping slots again')

    def test_intake_clears_the_rails_with_a_real_margin(self):
        """It used to clear by 0.11 mm, which is a coincidence, not a clearance."""
        slots = [enclosure._bbox(c) for c in enclosure._bottom_vents_local(
            enclosure.W - 2 * enclosure.T, enclosure.D - 2 * enclosure.T)
            if c.get('kind') == 'rect']
        half = enclosure.RAIL_W / 2.0
        for name, v, u0, u1, _s in enclosure.floor_rail_lines():
            for b in slots:
                if not (b[0] < u1 and u0 < b[2]):
                    continue
                gap = min(abs((v - half) - b[3]), abs(b[1] - (v + half)))
                with self.subTest(rail=name):
                    self.assertGreaterEqual(gap, enclosure.VENT_RAIL_CLR - 1e-6)


class Solid(unittest.TestCase):

    def test_a_segment_is_one_valid_printable_solid(self):
        name, _k, a, b, on = enclosure.floor_rail_segments()[0]
        dy = enclosure._rail_screw_dy(name)
        solid = enclosure._rail_solid(b - a, [(x - a, dy) for x in on])
        self.assertTrue(solid.isValid())
        box = solid.BoundingBox()
        self.assertAlmostEqual(box.zmin, 0.0, places=6)
        self.assertAlmostEqual(box.zmax, enclosure.RAIL_T, places=6)
        self.assertAlmostEqual(box.ylen, enclosure.RAIL_W, places=6)


if __name__ == '__main__':
    unittest.main()
