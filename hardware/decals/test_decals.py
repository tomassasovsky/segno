"""Decal checks (#1090): python -m unittest hardware/decals/test_decals.py
with the enclosure venv."""
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import decals  # noqa: E402
from shapely.geometry import box  # noqa: E402


class DecalTest(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.bounds = decals.main()      # raises on any cut or placement failure

    def test_logo_sits_on_metal_clear_of_every_lid_opening(self):
        logo = decals.logo_decal()
        for c in decals.se.faceplate_holes():
            if c["kind"] == "rect":
                hole = box(c["u"], c["v"], c["u"] + c["w"], c["v"] + c["h"])
                self.assertGreater(logo.distance(hole), 3.0, c["ref"])
        x0, y0, x1, y1 = logo.bounds
        self.assertGreater(x0, 0); self.assertLess(x1, decals.se.FP_W)
        self.assertLess(y1, decals.se.FP_V)

    def test_every_connector_is_labelled_once(self):
        refs = set(decals.rear_decal())
        self.assertEqual(refs, set(decals.se.rear_io_layout()) | {"EARTH_STUD"})

    def test_rear_labels_read_from_outside(self):
        """Seen from behind, u runs right to left: the USB pair (high u) is on
        the left of the strip and the PD inlet on the right."""
        pieces = decals.rear_decal()
        x = {ref: decals._wall(cu) for ref, (cu, _g) in pieces.items()}
        self.assertLess(x["USB3_2"], x["PD_IN"])

    def test_outputs_exist_at_one_to_one(self):
        for stem in ("segno_decal_logo", "segno_decal_rear", "segno_decals_cut_sheet"):
            for ext in (".dxf", ".svg", ".pdf"):
                self.assertTrue((decals.OUT / (stem + ext)).stat().st_size > 1000, stem + ext)
        import ezdxf
        doc = ezdxf.readfile(decals.OUT / "segno_decal_logo.dxf")
        xs = [p[0] for e in doc.modelspace() for p in e.get_points()]
        self.assertAlmostEqual(max(xs) - min(xs), 125.9, delta=0.1)


if __name__ == "__main__":
    unittest.main()
