"""The console strip ring's limits (#1075, #1088): run with the enclosure venv,
`python -m unittest hardware/strip_ring/test_console_ring.py`."""
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import console_ring as ring


class ConsoleRingTest(unittest.TestCase):

    def test_limits_hold_and_every_part_is_one_solid(self):
        info = ring.check()
        self.assertEqual(info["leds"], 34)

    def test_cup_clears_the_7in_module(self):
        self.assertLessEqual(ring.CUP_R, ring.SCREEN7_CLEAR_R - 2.0)

    def test_34_keeps_the_leds_close_to_the_lens(self):
        """Why 34 (owner's call, #1090): the LED faces sit about 3 mm outside the
        lens, which keeps one LED's spot narrow and the comet head sharp. A
        40-LED strip would put them 9.6 mm out."""
        self.assertLess(ring.LED_FACE_R - ring.LENS_R, 3.5)

    def test_lens_face_is_flush_and_the_carrier_sits_one_light_lift_down(self):
        self.assertAlmostEqual(ring.diffuser().BoundingBox().zmax, 0.0, places=6)
        # the cap sits one disc thickness down; the glued aluminium disc is flush
        self.assertAlmostEqual(ring.centre_cap().BoundingBox().zmax, -ring.DISC_T, places=6)
        self.assertLess(ring.cup().BoundingBox().zmax, -ring.FACEPLATE_T + 1e-6)

    def test_snap_arms_hold_the_carrier_without_clamping_it(self):
        """The carrier snap-mounts (#1090): at its nominal height the board
        touches nothing of the cup, and if it drops the catches stop it."""
        import cadquery as cq
        from math import atan2, degrees, hypot
        cup = ring.cup()

        def board(dz):
            return (cq.Workplane("XY").workplane(offset=ring.PCB_BOTTOM + dz)
                    .circle(ring.PCB_R).extrude(ring.PCB_T).val())
        self.assertLess(cup.intersect(board(0.0)).Volume(), 1e-6)
        self.assertLess(cup.intersect(board(-ring.CLIP_PLAY + 0.01)).Volume(), 1e-6)
        self.assertGreater(cup.intersect(board(-ring.CLIP_PLAY - 0.2)).Volume(), 1.0)
        # nothing of the cup reaches the 7in tower's clearance cylinder
        far = max(hypot(v.X, v.Y) for v in cup.Vertices())
        self.assertLess(far, ring.TOWER_CLEAR_R)
        # three arms, none on the strip seam
        lows = {round(degrees(atan2(v.Y, v.X))) % 360 for v in cup.Vertices()
                if v.Z < ring.PCB_BOTTOM - ring.CLIP_PLAY - 0.5}
        for a in lows:
            self.assertGreater(min(a, 360 - a), 15)

    def test_relief_opens_the_gap_behind_every_arm(self):
        """Behind each arm, from the wall's foot to the roof, the half millimetre
        next to the arm's inner face is air, so the print cannot fuse arm and
        wall. Control: the plain wall does fill that zone."""
        r_in = ring.CUP_R + ring.CLIP_GAP
        cup = ring.cup()
        plain_wall = ring.annulus(ring.CUP_R, ring.GLUE_R, ring.STRIP_BOTTOM, ring.UNDER)
        for a in ring.CLIP_ANGLES:
            zone = ring._sector(r_in, r_in - 0.5, ring.STRIP_BOTTOM, ring.UNDER - 1.2,
                                a, ring.CLIP_W)
            self.assertLess(cup.intersect(zone).Volume(), 1e-6, f"arm at {a}")
            self.assertGreater(plain_wall.intersect(zone).Volume(), 1.0, f"control at {a}")

    def test_flexed_arms_clear_the_printed_7in_tower(self):
        """While the board's edge pushes the catches out, the arms sweep 1 mm
        further out; that sweep stays TOWER_FLEX_AIR clear of the printed tower,
        so no notch is needed. Control: an arm turned to 90 deg, the tower's
        nearest bearing, would not clear it."""
        import cadquery as cq
        enclosure_dir = Path(__file__).resolve().parents[1] / "enclosure"
        sys.path.insert(0, str(enclosure_dir))
        import segno_enclosure as enclosure
        tower = cq.importers.importStep(
            str(enclosure_dir / "out" / "segno_screen7_tower.step")).val()
        under, n = enclosure.screen7_tower_encoder_axis()
        n = cq.Vector(*n).normalized()
        x = cq.Vector(1, 0, 0)
        y = n.cross(x)
        o = cq.Vector(*under) + n * ring.FACEPLATE_T  # ring z = 0: faceplate top
        to_tower = cq.Matrix([[x.x, y.x, n.x, o.x], [x.y, y.y, n.y, o.y],
                              [x.z, y.z, n.z, o.z]])

        def gap(shape):
            return shape.transformGeometry(to_tower).distance(tower)
        for a in ring.CLIP_ANGLES:
            self.assertGreater(gap(ring.clip_flex_envelope(a)), ring.TOWER_FLEX_AIR, f"arm at {a}")
        self.assertLess(gap(ring.clip_flex_envelope(90.0)), ring.TOWER_FLEX_AIR)

    def test_bench_plate_is_the_faceplate_where_it_matters(self):
        bench = ring.bench_faceplate()
        self.assertTrue(bench.isValid())
        # the window is the faceplate's, and the cup's glue face meets the
        # plate underside exactly where it meets the metal
        self.assertEqual(ring.BENCH_WINDOW_R, 33.5)
        self.assertAlmostEqual(ring.cup().BoundingBox().zmax, -ring.FACEPLATE_T, places=6)
        self.assertLess(ring.cup().BoundingBox().zmin, 0)
        self.assertGreater(ring.BENCH_LEG_H, 26.0)


if __name__ == "__main__":
    unittest.main()
