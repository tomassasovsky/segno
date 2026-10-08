"""Check emitted lid geometry against the conditional manufacturing fit budget.

These checks establish geometric passage and available flat land. They do not
qualify weld distortion, nonparallel clamp faces, screw torque or coating load.
"""

import itertools
import json
import math
from pathlib import Path
import sys
import tempfile
import unittest

import cadquery as cq
import ezdxf

HERE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HERE))
from flat_pattern_check import _face
import lid_fit
import segno_enclosure as enclosure


class RearJointFitsTest(unittest.TestCase):
    def test_emitted_cut_slots_have_the_budgeted_shape_and_front_drills_remain(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'lid.dxf'
            enclosure.dxf_faceplate(str(path))
            model = ezdxf.readfile(path).modelspace()
            cuts = [_face(entity) for entity in model if entity.dxf.layer == 'CUT']
        slots = [face for face in cuts
                 if abs(face.Center().y - enclosure.SEAM_LAP_V) < .001]
        self.assertEqual(len(slots), 9)
        for face, station in zip(sorted(slots, key=lambda face: face.Center().x),
                                 enclosure.FRONT_SCREW_U):
            expected = cq.Face.makeFromWires(cq.Workplane('XY').slot2D(
                10, 6, angle=90).val()).translate(
                    (enclosure.LID_OX + station, enclosure.SEAM_LAP_V, 0))
            self.assertLess(face.cut(expected).Area() + expected.cut(face).Area(), 1e-6)
        drills = list(model.query('CIRCLE[layer=="DRILL"]'))
        self.assertEqual(len(drills), 9)
        for hole in drills:
            self.assertAlmostEqual(hole.dxf.radius, 2.25)
            self.assertAlmostEqual(hole.dxf.center.y,
                                   enclosure.FRONT_SCREW_Z + enclosure.DEV90)

    def test_emitted_washer_and_slot_dimensions_satisfy_the_screening_envelope(self):
        washer = enclosure._lid_washer_solid('REAR')
        box = washer.BoundingBox()
        self.assertAlmostEqual(box.xlen, 12)
        self.assertAlmostEqual(box.ylen, 12)
        self.assertAlmostEqual(box.zlen, 1)
        expected_volume = math.pi * (6**2 - 1.6**2)
        self.assertAlmostEqual(washer.Volume(), expected_volume, places=6)
        self.assertAlmostEqual(enclosure.LID_REAR_SLOT_L
                               - enclosure.LID_REAR_SLOT_TOL - .20, 9.6)
        self.assertAlmostEqual(enclosure.LID_REAR_SLOT_W
                               - enclosure.LID_REAR_SLOT_TOL - .20, 5.6)
        check = self._joint(nearest_edge=11.27158)
        self.assertGreater(check.screw_clearance_mm, .30)
        self.assertGreaterEqual(check.centerline_side_bridge_mm, 1.8)
        self.assertGreater(check.bearing_area_lower_bound_mm2, 45.2)
        self.assertLess(check.perimeter_coverage_mm, -2.0)

    @staticmethod
    def _joint(nearest_edge):
        # Purchase acceptance bounds, not a claim about a catalog tolerance.
        return lid_fit.evaluate_rear_joint(
            slot_length=enclosure.LID_REAR_SLOT_L,
            slot_width=enclosure.LID_REAR_SLOT_W,
            size_tolerance=enclosure.LID_REAR_SLOT_TOL,
            axial_offset=2.567, transverse_offset=.800, axis_angle_deg=3,
            washer_od_min=11.8, washer_od_max=12.2, washer_id_max=3.4,
            nearest_flat_edge_min=nearest_edge,
        )

    def test_native_lap_has_flat_land_and_neighbor_clearance_for_all_nine_washers(self):
        manifest = json.loads((HERE / 'formed/manifest.json').read_text())
        shape = cq.importers.importStep(str(HERE / 'formed/segno_faceplate.step')).val()
        shape = shape.moved(enclosure._metal_location(
            manifest['segno_faceplate']['placements_mm'][0]))
        normal = cq.Vector(0, *lid_fit.REAR_NORMAL)
        lap = max((face for face in shape.Faces() if face.geomType() == 'PLANE'
                   and face.normalAt().dot(normal) > .99999), key=lambda face: face.Area())
        perimeter = lap.outerWire()
        self.assertEqual(len(perimeter.Edges()), 4)
        self.assertTrue(all(edge.geomType() == 'LINE' for edge in perimeter.Edges()))
        vertices = [vertex.toTuple() for vertex in perimeter.Vertices()]
        axial = [sum(t * (v - h) for t, v, h in zip(
            lid_fit.REAR_TANGENT, vertex[1:], lid_fit.LID_OUTER_HOLE))
                 for vertex in vertices]
        axial_edge = min(-min(axial), max(axial))
        self.assertGreater(axial_edge, 11.97)
        # Independent .40 hole-location and .30 flat-edge allowances. These
        # are not added to the screw/slot displacement again.
        check = self._joint(nearest_edge=axial_edge - .70)
        self.assertGreater(check.flat_land_mm, 2.40)
        self.assertGreater(axial_edge - .70
                           - (enclosure.LID_REAR_SLOT_L + .20) / 2, 6.17)
        x_min, x_max = min(v[0] for v in vertices), max(v[0] for v in vertices)
        side_edge = min(min(station - x_min, x_max - station)
                        for station in enclosure.FRONT_SCREW_U)
        self.assertGreater(side_edge - .70 - .800 - .20 - 6.10, 12.52)
        pitch = min(b - a for a, b in zip(enclosure.FRONT_SCREW_U,
                                         enclosure.FRONT_SCREW_U[1:]))
        self.assertGreater(pitch - 12.2 - 2 * (.800 + .20), 86.94)

    def test_front_plane_shift_preserves_the_conditional_finished_gap(self):
        self.assertAlmostEqual(enclosure.LIP_BARE_CLEAR - .50, .60)
        fixture = json.loads((HERE / 'reference/coated_seat_datums.json').read_text())
        front = (fixture['front_lid_bore_y'] - (enclosure.LIP_BARE_CLEAR - .50),
                 enclosure.FRONT_SCREW_Z + enclosure.DEV90)
        gaps = []
        for films in itertools.product((.12, .20), repeat=3):
            shift = lid_fit.seated_lid_pose(*films).displacement(front)[0]
            for bare, front_film in itertools.product(
                    (enclosure.FRONT_BARE_GAP_MIN, enclosure.FRONT_BARE_GAP_MAX),
                    (.12, .20)):
                gaps.append(bare - shift - front_film)
        # The measured bare assembly band already contains forming/fixture
        # variation. This screen adds coating, not another forming allowance.
        self.assertGreater(min(gaps), .35)
        self.assertLess(max(gaps), 1.50)


if __name__ == '__main__':
    unittest.main()
