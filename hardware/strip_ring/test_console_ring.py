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
        self.assertAlmostEqual(ring.centre_cap().BoundingBox().zmax, 0.0, places=6)
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
