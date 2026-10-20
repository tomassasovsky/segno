"""Independent solids and contact checks for the lid allowance calculations."""

import itertools
import json
import math
from pathlib import Path
import sys
import unittest

import cadquery as cq

HERE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HERE))
import lid_fit


class LidToleranceBudgetTest(unittest.TestCase):
    def test_reference_bend_centers_still_match_the_native_parts(self):
        import segno_enclosure as enclosure
        manifest = json.loads((HERE / 'formed/manifest.json').read_text())
        for stem, points in (
            ('segno_base', (lid_fit.BASE_FLOOR_BEND, lid_fit.BASE_LAP_BEND)),
            ('segno_faceplate', (lid_fit.LID_LAP_BEND,)),
        ):
            shape = cq.importers.importStep(str(HERE / 'formed' / (stem + '.step'))).val()
            shape = shape.moved(enclosure._metal_location(manifest[stem]['placements_mm'][0]))
            centers = []
            for face in shape.Faces():
                if face.geomType() != 'CYLINDER':
                    continue
                cylinder = face._geomAdaptor()
                axis = cylinder.Axis()
                if abs(cylinder.Radius() - 4) < .001 and abs(axis.Direction().X()) > .999999:
                    centers.append((axis.Location().Y(), axis.Location().Z()))
            for y, z in points:
                self.assertLess(min(math.hypot(y - cy, z - cz) for cy, cz in centers), .001)

    def test_fold_bound_covers_interior_angles_and_both_lid_surfaces(self):
        low, high = lid_fit.rear_fold_envelope(1)
        self.assertLess(low, -1.58)
        self.assertGreater(high, 1.56)
        for angles in itertools.product((-.8, -.3, 0, .4, .9), repeat=3):
            for depth in (0, 1, 2):
                offset = lid_fit.rear_fold_offset(*angles, depth)
                self.assertGreaterEqual(offset, low)
                self.assertLessEqual(offset, high)
        # Larger boxes require a new derivative argument, not blind corners.
        with self.assertRaisesRegex(ValueError, 'do not certify'):
            lid_fit.rear_fold_envelope(1.5)

    @staticmethod
    def _joint(length=10, width=6, axial=2.567, transverse=.8, edge=11.27):
        return lid_fit.evaluate_rear_joint(
            slot_length=length, slot_width=width,
            axial_offset=axial, transverse_offset=transverse,
            washer_od_min=11.8, washer_od_max=12.2, washer_id_max=3.4,
            nearest_flat_edge_min=edge, axis_angle_deg=3,
        )

    def test_coated_slot_clears_a_real_tilted_screw_at_displacement_corners(self):
        result = self._joint()
        self.assertGreater(result.screw_clearance_mm, .30)
        plate = (cq.Workplane('XY').rect(30, 30).extrude(2)
                 .cut(cq.Workplane('XY').slot2D(9.6, 5.6).extrude(2))).val()
        for axial, transverse, angle in itertools.product((-2.567, 2.567), (-.8, .8), (0, 3)):
            angle = math.radians(angle)
            # Both sheet-face axis intercepts stay within the declared bound.
            slope = math.copysign(abs(math.tan(angle)), axial)
            start = cq.Vector(axial - 4 * slope, transverse, -2)
            direction = cq.Vector(slope, 0, 1).normalized()
            screw = cq.Solid.makeCylinder(1.5, 7, start, direction)
            self.assertLess(screw.intersect(plate).Volume(), 1e-7)

    def test_original_slot_fails_simultaneous_position_and_paint(self):
        self.assertLess(self._joint(length=7, width=4.5, axial=1.83).screw_clearance_mm, 0)
        plate = (cq.Workplane('XY').rect(30, 30).extrude(2)
                 .cut(cq.Workplane('XY').slot2D(6.6, 4.1).extrude(2))).val()
        screw = cq.Solid.makeCylinder(1.5, 4, cq.Vector(1.83, .8, -1))
        self.assertGreater(screw.intersect(plate).Volume(), .1)

    def test_washer_bearing_can_pass_without_covering_the_whole_slot(self):
        result = self._joint()
        self.assertGreater(result.centerline_side_bridge_mm, 1.79)
        self.assertGreater(result.bearing_area_lower_bound_mm2, 45.2)
        self.assertLess(result.perimeter_coverage_mm, 0)
        self.assertGreater(result.flat_land_mm, 2.4)
        opening = cq.Workplane('XY').slot2D(10.2, 6.2).extrude(.1).val()
        washer = cq.Workplane('XY').circle(5.9).circle(1.7).extrude(.1).val()
        for axial, transverse in itertools.product((-2.567, 0, 2.567), (-.8, 0, .8)):
            for float_x, float_y in ((.2, 0), (-.2, 0), (0, .2), (0, -.2)):
                actual = washer.translate((axial + float_x, transverse + float_y, 0))
                bearing = actual.cut(opening).Volume() / .1
                self.assertGreaterEqual(bearing, result.bearing_area_lower_bound_mm2 - 1e-6)
        # No planar-bearing claim survives running off the lap's free edge.
        self.assertIsNone(self._joint(edge=8).bearing_area_lower_bound_mm2)

    def test_one_rigid_pose_satisfies_all_three_contact_equations(self):
        fixture = json.loads((HERE / 'reference/coated_seat_datums.json').read_text())
        contacts = ((fixture['main_normal_yz'], fixture['main_front_yz']),
                    (fixture['main_normal_yz'], fixture['main_rear_yz']),
                    (fixture['rear_normal_yz'], fixture['rear_bore_yz']))
        for lifts in itertools.product((-.8, .8), repeat=3):
            pose = lid_fit.seated_lid_pose(*lifts)
            for lift, (normal, point) in zip(lifts, contacts):
                delta = pose.displacement(point)
                measured = sum(n * d for n, d in zip(normal, delta))
                self.assertAlmostEqual(measured, lift, places=9)

    def test_broad_seat_dimensions_do_not_imply_a_small_front_gap(self):
        front = (-3.410842379, 6.455420469476287)
        motion = [lid_fit.seated_lid_pose(*lifts).displacement(front)[0]
                  for lifts in itertools.product((-.8, .8), repeat=3)]
        self.assertLess(min(motion), -2.51)
        self.assertGreater(max(motion), 2.51)

    def test_conditionally_accepted_bare_gap_survives_the_existing_coating_range(self):
        # This is a finished bare-assembly acceptance input. It already
        # contains forming/fixture variation, so those are not added again.
        front = (-4.010842379, 6.455420469476287)  # nominal bare gap 1.10
        gaps = []
        for seat_films in itertools.product((.12, .20), repeat=3):
            delta = lid_fit.seated_lid_pose(*seat_films).displacement(front)
            for bare_gap, front_films in itertools.product((.70, 1.50), (.12, .20)):
                gaps.append(bare_gap - delta[0] - front_films)
        self.assertGreater(min(gaps), .35)
        self.assertLess(max(gaps), 1.50)


if __name__ == '__main__':
    unittest.main()
