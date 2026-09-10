"""Lid props — the one steel support beam and the one printed prop (issue #1019).

Away from a pad the 2.0 mm faceplate dents at 7-11 kg of point load; over one it
takes 170 kg. #292 put two posts in front of the 16in aperture, which covered
100 mm of an 850 mm panel; #1019 spread them to seven, which covered 211 of 850.
On 2026-09-10 the seven became ONE full-width folded beam, so the pad is
continuous and there is no longer a band between pads to fall through.

These regressions hold that in place: the beam bears wall to wall on metal that
was not cut away, it clears every LED diffuser shoulder in depth (the only thing
it cannot dodge sideways any more), its web is holed wherever a cable used to
walk past a post, and the fourteen floor fixings did not move. The printed prop
in the clear lane beside BANK is unchanged; the ligament left of CLEAR has no
lane and stays bare -- see
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


class SupportBeam(unittest.TestCase):

    def setUp(self):
        self.cuts = enclosure.faceplate_holes()

    def test_it_is_one_part_that_spans_the_whole_inside_width(self):
        self.assertEqual(enclosure.PART_SPECS['segno_beam'][1], 1)
        # the clear span is not the flat's 846: a centre bend line lands each
        # wall's inner face BA90/2 - RI inboard of the edge it folds from
        self.assertAlmostEqual(enclosure.BEAM_WALL_GAP, 845.82168, places=4)
        self.assertAlmostEqual(enclosure.BEAM_LEN + 2*enclosure.BEAM_END_CLR,
                               enclosure.BEAM_WALL_GAP, places=9)
        self.assertGreater(enclosure.BEAM_END_CLR, 0.4)

    def test_the_pad_bears_on_metal_that_was_not_cut_away(self):
        v0, v1 = enclosure.BEAM_V - enclosure.BEAM_PAD, enclosure.BEAM_V
        for cut in self.cuts:
            with self.subTest(cut=cut.get('ref')):
                box = enclosure._bbox(cut)
                self.assertFalse(box[1] < v1 and v0 < box[3])

    def test_the_pad_clears_every_led_pill_shoulder_where_they_come_closest(self):
        """A continuous pad cannot dodge the shoulders in u the way a post did.

        And a plan view flatters it: the pad bears BEAM_BARE_GAP below the
        faceplate, where the shoulder's perpendicular rear face has already
        leaned back, and the pad's square-cut end reaches BEAM_T*tan further
        forward than its mould line. Measuring in plan said 1.39 mm where the
        assembled Fusion model measured 0.78.
        """
        self.assertAlmostEqual(enclosure.BEAM_LEAN, 0.6207, places=4)
        pills = [c for c in self.cuts if c.get('ref', '').endswith('_LEDSLOT')]
        self.assertEqual(len(pills), 10)
        front = [c for c in pills
                 if c['v'] + c['h'] + enclosure.LED_INS_FLANGE < enclosure.BEAM_V]
        self.assertEqual(len(front), 8)          # the eight front-row pills
        for pill in front:
            rear = pill['v'] + pill['h'] + enclosure.LED_INS_FLANGE
            gap = (enclosure.BEAM_V - enclosure.BEAM_PAD) - rear - enclosure.BEAM_LEAN
            with self.subTest(pill=pill['ref']):
                self.assertGreaterEqual(gap, enclosure.LED_BEAM_MIN)
        # room for the 0.2 mm an FDM shoulder can grow, plus a glue bead
        self.assertGreater(gap, 1.4)

    def test_the_fourteen_floor_fixings_did_not_move(self):
        """Frozen: these holes were in the base flat before the beam existed."""
        self.assertEqual([round(u, 3) for u in enclosure.beam_bolt_u()],
                         [109.5, 129.643, 210.643, 230.786, 311.786, 331.929,
                          412.929, 433.071, 514.071, 534.214, 615.214, 635.357,
                          716.357, 736.5])
        self.assertAlmostEqual(enclosure._BEAM_FOOT_VP, 148.99693697984182, places=9)

    def test_a_cable_window_sits_on_every_front_pedal_and_one_each_side(self):
        row1 = sorted(u for label, u, v in enclosure.PEDALS
                      if v == enclosure.PEDAL_ROW1_V)
        windows = enclosure.beam_cable_u()
        self.assertEqual(len(windows), 10)
        for u in row1:
            with self.subTest(pedal=u):
                self.assertTrue(any(abs(u - w) < 1e-9 for w in windows))
        led = [w for w in windows if not any(abs(u - w) < 1e-9 for u in row1)]
        self.assertEqual(len(led), 2)
        self.assertLess(led[0], row1[0])         # outboard of the outermost pedal
        self.assertGreater(led[1], row1[-1])

    def test_the_web_survives_its_windows(self):
        above = enclosure.BEAM_H - (enclosure.BEAM_H + enclosure.BEAM_CABLE_H)/2.0
        below = (enclosure.BEAM_H - enclosure.BEAM_CABLE_H)/2.0 - enclosure.BEAM_T
        self.assertGreaterEqual(above, enclosure.BEAM_WEB_MIN)
        self.assertGreaterEqual(below, enclosure.BEAM_WEB_MIN)
        windows = enclosure.beam_cable_u()
        for a, b in zip(windows, windows[1:]):
            with self.subTest(pair=(a, b)):
                self.assertGreaterEqual(b - a - enclosure.BEAM_CABLE_W,
                                        enclosure.BEAM_WEB_MIN)
        for bolt in enclosure.beam_bolt_u():     # and no window lands on a fixing
            for w in windows:
                with self.subTest(bolt=bolt, window=w):
                    self.assertGreater(abs(bolt - w),
                                       enclosure.BEAM_CABLE_W/2.0 + enclosure.D_M4)

    def test_every_window_and_every_fixing_is_actually_cut(self):
        """Both cutters missed once: the windows were extruded away from the web
        and the right ear's slot landed past the end of its own ear. The solid
        was still valid and still the right size, so only counting the geometry
        catches it."""
        solid = enclosure._beam_solid()
        radii = {}
        for face in solid.Faces():
            if face.geomType() == 'CYLINDER':
                r = round(face._geomAdaptor().Radius(), 3)
                radii[r] = radii.get(r, 0) + 1
        windows = len(enclosure.beam_cable_u())
        fixings = len(enclosure.beam_bolt_u()) + 2          # + one tie per ear
        self.assertEqual(radii.get(enclosure.BEAM_CABLE_R), 4*windows)
        self.assertEqual(radii.get(round(enclosure.D_M4/2.0, 3)), 2*fixings)
        self.assertEqual(radii.get(enclosure.BEAM_RI), 4)                    # 2 long folds
        self.assertEqual(radii.get(enclosure.BEAM_RI + enclosure.BEAM_T), 4)  # + 2 ears

    def test_the_development_composes_the_way_the_standard_rule_says(self):
        """Cross-check the per-flap deductions against the one-bend-at-a-time
        form: total flat = sum of outer mould lengths - BD per bend, where BD is
        twice what beam_deduct() returns for one flap. The four folds are two
        different angles and one of them (the ears) is a direction the posts
        never had."""
        bd90 = 2*enclosure.beam_deduct(90.0)
        bd_pad = 2*enclosure.beam_deduct(90.0 + enclosure.BEAM_TILT)
        across = (enclosure.BEAM_PAD_OUT + enclosure.BEAM_WEB_OUT
                  + enclosure.BEAM_FOOT_OUT) - bd_pad - bd90
        self.assertAlmostEqual(
            across,
            enclosure.BEAM_PAD_F + enclosure.BEAM_WEB_F + enclosure.BEAM_FOOT_F,
            places=9)
        along = (enclosure.BEAM_LEN + 2*enclosure.BEAM_EAR_OUT) - 2*bd90
        self.assertAlmostEqual(
            along, enclosure.BEAM_WEB_XF + 2*enclosure.BEAM_EAR_F, places=9)
        # and the blank is the size the shop sheet quotes
        self.assertAlmostEqual(along, 877.885, places=3)
        self.assertAlmostEqual(across, 75.461, places=3)

    def test_it_is_one_valid_solid_of_the_size_the_shell_leaves(self):
        solid = enclosure._beam_solid()
        self.assertTrue(solid.isValid())
        box = solid.BoundingBox()
        self.assertAlmostEqual(box.xlen, enclosure.BEAM_LEN, places=6)
        self.assertAlmostEqual(box.zmin, 0.0, places=6)
        # foot forward of the web, ear behind it: y runs 0 .. foot + t + ear
        self.assertAlmostEqual(box.ymax,
                               enclosure.BEAM_FOOTL + enclosure.BEAM_T
                               + enclosure.BEAM_EAR_V, places=6)

    def test_the_section_is_strong_enough_that_the_steel_grade_is_free(self):
        """No grade is called out on the drawing, and this is why.

        The beam's own worst case is its end overhang: 108.9 mm of C section
        past the outermost bolt, with the wall tie ignored. A 1 kN stomp landing
        on the very tip reads 78 MPa. The softest cold-rolled mild steel a shop
        stocks yields around 140, so any of them carries it, and E is 210 GPa
        for all of them so stiffness does not depend on the choice either.
        Everything else the beam does is bearing and short-range compression at
        under 7 MPa.
        """
        import cadquery as cq
        from OCP.BRepGProp import BRepGProp
        from OCP.GProp import GProp_GProps

        solid = enclosure._beam_solid()
        windows = enclosure.beam_cable_u()
        x = (windows[3] + windows[4])/2.0 - enclosure.BEAM_U0    # clear of every cut
        knife = cq.Workplane('YZ').rect(400, 400).extrude(0.001).val().translate((x, 0, 0))
        face = max((f for f in solid.intersect(knife).Faces()
                    if abs(f.normalAt().x) > 0.999), key=lambda f: f.Area())
        props = GProp_GProps()
        BRepGProp.SurfaceProperties_s(face.wrapped, props)
        area, centre = props.Mass(), props.CentreOfMass()
        second = props.MatrixOfInertia().Value(2, 2)             # about the horizontal axis
        box = face.BoundingBox()
        fibre = max(box.zmax - centre.Z(), centre.Z() - box.zmin)

        self.assertAlmostEqual(area, 122.2, places=1)
        self.assertAlmostEqual(second, 33097, delta=50)
        overhang = min(enclosure.beam_bolt_u()) - enclosure.BEAM_U0
        self.assertAlmostEqual(overhang, 108.9, places=1)
        tip = 1000.0*overhang*fibre/second
        self.assertLess(tip, 100.0)          # 78.2 as drawn, against a 140 floor
        self.assertLess(1000.0*overhang**3/(3*210000.0*second), 0.1)

    def test_the_fixings_are_slotted_and_the_flat_says_so(self):
        """Plain holes cost the bottom plate 147 MPa at 1 kN; slots, 135."""
        self.assertGreater(enclosure.BEAM_BOLT_SLOT, 0.0)
        self.assertGreater(enclosure.BEAM_EAR_SLOT, 0.0)
        import tempfile
        import ezdxf
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)/'segno_beam.dxf'
            enclosure.dxf_beam(str(path))
            doc = ezdxf.readfile(path)
            cuts = [e for e in doc.modelspace()
                    if e.dxftype() == 'LWPOLYLINE' and e.dxf.layer == 'CUT']
            bends = [e for e in doc.modelspace()
                     if e.dxftype() == 'LWPOLYLINE' and e.dxf.layer == 'BEND']
        # no plain circles at all: every fixing is an obround
        self.assertEqual([e for e in cuts if e.dxftype() == 'CIRCLE'], [])
        # outline + 14 foot slots + 10 cable windows + 2 ear slots
        self.assertEqual(len(cuts), 1 + 14 + 10 + 2)
        # pad, foot and one bend line per ear
        self.assertEqual(len(bends), 4)

    def test_the_wall_ties_are_in_the_base_cut_file(self):
        import tempfile
        import ezdxf
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)/'segno_base.dxf'
            enclosure.dxf_base(str(path))
            bores = [(e.dxf.center.x, e.dxf.center.y)
                     for e in ezdxf.readfile(path).modelspace()
                     if e.dxftype() == 'CIRCLE' and e.dxf.layer == 'CUT'
                     and abs(e.dxf.radius - enclosure.D_M4/2.0) < 1e-7]
        offset = enclosure.wall_flat_z(enclosure.BEAM_EAR_BOLT_Z)
        depth = enclosure._BEAM_REAR_Y + enclosure.BEAM_EAR_BOLT_V
        for want in ((-offset, depth), (enclosure.W - 2*enclosure.T + offset, depth)):
            with self.subTest(tie=want):
                self.assertTrue(any(math.hypot(x-want[0], y-want[1]) < 1e-6
                                    for x, y in bores))

    def test_the_ears_fold_into_clear_air_behind_the_web(self):
        """They fold rearward, and the 16in module body is also behind the web."""
        body0 = enclosure.SCREEN_16_U - enclosure.S16_BODY_W/2.0
        body1 = enclosure.SCREEN_16_U + enclosure.S16_BODY_W/2.0
        for u in (enclosure.BEAM_U0 + enclosure.BEAM_T,
                  enclosure.FP_W - enclosure.BEAM_U0 - enclosure.BEAM_T):
            with self.subTest(ear=u):
                self.assertTrue(u < body0 - 2.0 or u > body1 + 2.0)


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
