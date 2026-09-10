"""Floor rails — the supports that carry a stomp (issue #1019).

THREE printed PETG rails, each holding a self-adhesive solid neoprene strip, on
screw rows the floor already had. 96 MPa and 3.3 mm at a 1 kN stomp, against a
Boss RC-600's 401 MPa and 1.8 mm measured in the same model.

Those numbers come from a LARGE-DEFLECTION shell model, not from `_stomp_fea.py`.
The linear model in that file is right to 0.3% against Timoshenko while a plate
stays inside small-deflection theory and useless outside it: at w/t = 10 it
overstates deflection sixfold, which is why it once said an RC-600 yields at
42 kg. Treat its absolute numbers as superseded and its rankings as sound.

Three of these guard mistakes that were actually made and caught here: the rear
anchors sat inside the buck converters, which no plan view shows; and the intake
vent field collapsed 72% when the posts spread, because the all-vents gate sums
intake and exhaust.
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

    def test_three_rails_on_rows_the_floor_already_had(self):
        self.assertEqual([r[0] for r in self.rails], ['front_a', 'front_b', 'rear'])
        for name, _v, u0, u1, screws in self.rails:
            with self.subTest(rail=name):
                self.assertGreaterEqual(len([s for s in screws if u0 <= s <= u1]), 2)

    def test_every_row_clears_every_bore_that_is_not_its_own(self):
        """The check that was missing. dxf_base_bores() listed 82 of the plate's
        114 bores -- it never included board_mounts() -- and a middle row was
        proposed straight over the console board's rear standoffs on the strength
        of it. Assert the bore list is complete, then assert the rows clear it."""
        bores = enclosure.dxf_base_bores()
        self.assertTrue(any(c['ref'] == 'BOARD' for c in bores),
                        'the board standoffs are missing from the bore list again')
        half = enclosure.RAIL_W / 2.0
        own = {(round(x, 3), round(v + enclosure._rail_screw_dy(n), 3))
               for n, v, u0, u1, sc in self.rails for x in sc if u0 <= x <= u1}
        for name, v, u0, u1, _s in self.rails:
            for c in bores:
                if not (u0 <= c['u'] <= u1):
                    continue
                if (round(c['u'], 3), round(c['v'], 3)) in own:
                    continue
                with self.subTest(rail=name, bore=c['ref']):
                    self.assertGreater(abs(c['v'] - v), half + 1.8,
                                       f"{name} sits on the {c['ref']} bore at "
                                       f"({c['u']:.1f}, {c['v']:.1f})")

    def test_the_middle_of_the_plate_has_only_two_narrow_lanes(self):
        """Why there are three rows and not more. Recorded rather than forbidden:
        a fourth row IS geometrically possible at v 162.3-167.9 or v 259.5-265.3,
        both about 5 mm wide, and both would need new bores whose heads have to
        clear whatever stands on the floor above them. Everything between them is
        blocked by pedestal screws, stand anchors, the lid prop and the board."""
        bores = enclosure.dxf_base_bores()
        half = enclosure.RAIL_W / 2.0
        free = [v/10.0 for v in range(1500, 3200)
                if all(abs(c['v'] - v/10.0) > half + 2.8 for c in bores)]
        runs, start = [], free[0]
        for a, b in zip(free, free[1:]):
            if b - a > 0.15:
                runs.append((start, a))
                start = b
        runs.append((start, free[-1]))
        wide = [r for r in runs if r[1] - r[0] > 0.4]
        self.assertEqual(len(wide), 2, f'the lane map changed: {wide}')
        for a, b in wide:
            self.assertLess(b - a, 8.0, 'a lane widened; re-check the bore list')

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

    def test_no_segment_is_left_turning_about_one_screw(self):
        """An equal split gives every front and mid segment four screws, and the
        rear anchors are ours to place, so they go two to a segment."""
        for name, k, _a, _b, on in self.segments:
            with self.subTest(rail=name, seg=k):
                self.assertGreaterEqual(len(on), 2)

    def test_the_rear_anchor_heads_stay_out_of_the_buck_converters(self):
        """The bores are cheap under the floor and expensive above it. An even
        45 mm inset put four of the eight heads inside a brick, and the plan view
        showed nothing -- the converters are 22 mm of solid body standing on the
        floor exactly where the rear rail runs.
        """
        half_head = enclosure.RAIL_HEAD_D / 2.0
        for name, u, v, _spacing in enclosure.buck_mounts():
            for au, av in enclosure.base_foot_xy():
                with self.subTest(brick=name, anchor=(round(au, 2), av)):
                    self.assertFalse(
                        abs(au - u) < enclosure.BUCK_BODY[0]/2.0 + half_head
                        and abs(av - v) < enclosure.BUCK_BODY[1]/2.0 + half_head)

    def test_the_rear_anchors_repeat_and_stay_off_the_segment_tips(self):
        """Same two offsets in every segment, or the segments are not one part;
        and far enough in that the screw has wall around it, which is what the
        45 mm inset was for before the converters took those offsets away."""
        rear = [(a, b, on) for n, _k, a, b, on in self.segments if n == 'rear']
        self.assertEqual(len(rear), enclosure.RAIL_SEGMENTS)
        for a, b, on in rear:
            start, length = enclosure._rail_print(a, b)
            self.assertEqual([round(x - a, 6) for x in on],
                             [round(o, 6) for o in enclosure.RAIL_REAR_ANCHORS])
            for x in on:
                self.assertGreater(x - start, enclosure.RAIL_W)
                self.assertLess(x - start, length - enclosure.RAIL_W)

    def test_every_segment_fits_the_bed(self):
        for name, k, a, b, _on in self.segments:
            with self.subTest(rail=name, seg=k):
                self.assertLessEqual(b - a, enclosure.RAIL_MAXLEN)

    def test_the_split_is_even(self):
        """Even segments, as many as the bed needs. Cutting on screw stations
        instead gave five uneven ones per rail to fix a problem three of the
        five rails did not have."""
        self.assertEqual(len(self.segments), 12)
        for name in ("front_a", "front_b", "rear"):
            lengths = [round(b - a, 6) for n, _k, a, b, _o in self.segments if n == name]
            self.assertEqual(len(set(lengths)), 1, f"{name} segments are uneven")

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
        """Quoted to the CHANNEL, not to the segment's span: the span over-orders
        by one joint per segment."""
        need = sum(enclosure._rail_print(a, b)[1] - 2 * enclosure.RAIL_END_INSET
                   for _n, _k, a, b, _o in enclosure.floor_rail_segments())
        self.assertLess(need, 20 * 304.8)
        self.assertGreater(need, 6 * 304.8,
                           'this got much shorter when the rails went to three rows; '
                           'check the roll length is still the right thing to buy')


class NoBottomVents(unittest.TestCase):
    """The bottom plate is solid (owner call). It carried 3,840 mm2 of intake at
    v 134..162, which sat 112 mm forward of the console board and breathed through
    the 7.7 mm under-plate gap. The openings are in the side and rear WALLS now."""

    def test_the_generator_has_no_bottom_vent_field_left(self):
        for gone in ('_bottom_vents', '_bottom_vents_local',
                     'VENT_INTAKE_MIN', 'VENT_RAIL_CLR'):
            self.assertFalse(hasattr(enclosure, gone),
                             f'{gone} came back; the floor is meant to be solid')

    def test_the_cut_file_puts_no_vent_inside_the_floor(self):
        """Read it out of a fresh DXF: the side and rear walls are part of the same
        flat pattern, so it is not enough to check that VENT geometry exists."""
        bw, bd = enclosure.W - 2*enclosure.T, enclosure.D - 2*enclosure.T
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'segno_base.dxf'
            enclosure.dxf_base(str(path))
            inside = []
            for e in ezdxf.readfile(path).modelspace():
                if e.dxf.layer != 'VENT':
                    continue
                pts = ([(p[0], p[1]) for p in e.get_points()]
                       if e.dxftype() == 'LWPOLYLINE' else [])
                if pts and all(0 <= x <= bw and 0 <= y <= bd for x, y in pts):
                    inside.append(pts[0])
        self.assertEqual(inside, [], 'vent geometry is back inside the floor')

    def test_the_air_still_has_a_way_out(self):
        sv = sum(c['w'] * c['h'] for f in ('L', 'R')
                 for c in enclosure.side_vents(f, enclosure.W - 2*enclosure.T)
                 if c.get('kind') == 'rect')
        free = (enclosure._vent_free_area(enclosure.rear_holes())
                + sv * enclosure.FOAM_OPEN_FRACTION)
        self.assertGreaterEqual(free, enclosure.VENT_FREE_AREA_MIN)


class Solid(unittest.TestCase):

    def test_a_segment_is_one_valid_printable_solid(self):
        for name, _k, a, b, on in enclosure.floor_rail_segments():
            dy = enclosure._rail_screw_dy(name)
            with self.subTest(rail=name):
                solid = enclosure._rail_solid(b - a, [(x - a, dy) for x in on])
                self.assertTrue(solid.isValid())
                self.assertEqual(len(solid.Solids()), 1)
                box = solid.BoundingBox()
                self.assertAlmostEqual(box.zmin, 0.0, places=6)
                self.assertAlmostEqual(box.zmax, enclosure.RAIL_T, places=6)
                self.assertAlmostEqual(box.ylen, enclosure.RAIL_W, places=6)
                self.assertAlmostEqual(box.xlen, b - a, places=6)

    def test_the_ends_are_square_and_the_segments_butt(self):
        """Reversing an earlier call: full-round stadium ends became square with a
        corner break, and the 3 mm joint became print tolerance, because a row of
        four gapped lozenges read as sixteen objects rather than four lines."""
        name, _k, a, b, on = enclosure.floor_rail_segments()[0]
        start, length = enclosure._rail_print(a, b)
        solid = enclosure._rail_solid(length, [(x - start, enclosure._rail_screw_dy(name))
                                               for x in on])
        gross = length * enclosure.RAIL_W * enclosure.RAIL_T
        corners = (4 - math.pi) * enclosure.RAIL_END_R**2 * enclosure.RAIL_T
        self.assertLess(solid.Volume(), gross - corners)
        self.assertGreater(solid.Volume(), gross * 0.70,
                           'a square end should lose its corner break and the '
                           'channel, and nothing else')
        self.assertLessEqual(enclosure.RAIL_END_R, 2.0)
        self.assertLessEqual(enclosure.RAIL_JOINT, 1.0,
                             'the joint is print tolerance, not a design feature')

    def test_every_segment_of_a_rail_is_the_same_printed_part(self):
        """The owner asked for four identical strips, not four that tile. Taking
        the joint gap off only the shared ends left the first and last of each
        rail 1.5 mm longer, and the span-based check could not see it."""
        for name, _v, _u0, _u1, _s in enclosure.floor_rail_lines():
            parts = {(round(enclosure._rail_print(a, b)[1], 6),
                      tuple(round(x - enclosure._rail_print(a, b)[0], 6) for x in on))
                     for n, _k, a, b, on in enclosure.floor_rail_segments()
                     if n == name}
            with self.subTest(rail=name):
                self.assertEqual(len(parts), 1)


if __name__ == '__main__':
    unittest.main()
