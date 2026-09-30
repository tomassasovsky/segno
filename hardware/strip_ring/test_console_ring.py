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

    def test_40_leds_would_not_fit(self):
        """Why 34: at 40 the strip's back alone is past the 7in module's edge."""
        from math import pi
        back_40 = (40 * ring.PITCH + ring.SEAM) / (2 * pi) + ring.FPC_T / 2
        self.assertGreater(back_40, ring.SCREEN7_CLEAR_R)

    def test_lens_face_is_flush_and_the_carrier_sits_one_light_lift_down(self):
        self.assertAlmostEqual(ring.diffuser().BoundingBox().zmax, 0.0, places=6)
        self.assertAlmostEqual(ring.centre_cap().BoundingBox().zmax, 0.0, places=6)
        self.assertLess(ring.cup().BoundingBox().zmax, -ring.FACEPLATE_T + 1e-6)


if __name__ == "__main__":
    unittest.main()
