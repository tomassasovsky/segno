"""Section calculations for the lid's manufacturing allowance review.

The reference section comes from the placed native STEP at 43c94a27. The fold
calculation holds the floor and main lid nominal; the seat calculation instead
solves one rigid lid pose. Neither models weld distortion, elastic clamping or
the bearing of nonparallel faces. Do not add a finished dimensional envelope to
the fold result when that envelope already includes angle/development errors.

Dimensions passed to ``evaluate_rear_joint`` are explicit design inputs, not
selected manufacturing dimensions or qualified hardware specifications.
"""

from dataclasses import dataclass
from itertools import product
import json
import math
from pathlib import Path


def _add(a, b):
    return (a[0] + b[0], a[1] + b[1])


def _sub(a, b):
    return (a[0] - b[0], a[1] - b[1])


def _dot(a, b):
    return a[0] * b[0] + a[1] * b[1]


def _rotate(point, radians):
    c, s = math.cos(radians), math.sin(radians)
    return (c * point[0] - s * point[1], s * point[0] + c * point[1])


def _solve_normals(first, second, a, b):
    determinant = first[0] * second[1] - first[1] * second[0]
    return ((a * second[1] - first[1] * b) / determinant,
            (first[0] * b - a * second[0]) / determinant)


# World Y/Z, mm. These are bend-cylinder centers, not developed bend lines.
BASE_FLOOR_BEND = (416.910840921, 4.0)
BASE_LAP_BEND = (416.91084310302, 85.434180784746)
LID_LAP_BEND = (394.4955374523191, 97.81959860504513)
BASE_PILOT_POINT = (405.998427204581, 92.5912881357312)
LID_OUTER_HOLE = (407.65363452743367, 96.23247978138657)
REAR_NORMAL = (0.41380297756786516, 0.9103664623413854)
REAR_TANGENT = (REAR_NORMAL[1], -REAR_NORMAL[0])
LID_THICKNESS = 2.0


def rear_fold_offset(base_floor_deg, base_lap_deg, lid_lap_deg, depth=0.0):
    """Screw-axis intercept relative to the lid hole, along the actual lap.

    ``depth=0`` is the outer bearing surface; ``depth=2`` is the inner surface.
    Rotations are independent errors about the three reference bend cylinders.
    """
    a, b, c = map(math.radians, (base_floor_deg, base_lap_deg, lid_lap_deg))
    pilot = _add(BASE_LAP_BEND, _rotate(_sub(BASE_PILOT_POINT, BASE_LAP_BEND), b))
    pilot = _add(BASE_FLOOR_BEND, _rotate(_sub(pilot, BASE_FLOOR_BEND), a))
    screw_normal = _rotate(REAR_NORMAL, a + b)
    hole = _add(LID_LAP_BEND, _rotate(_sub(LID_OUTER_HOLE, LID_LAP_BEND), c))
    normal = _rotate(REAR_NORMAL, c)
    hole = _sub(hole, (depth * normal[0], depth * normal[1]))
    distance = _dot(normal, _sub(hole, pilot)) / _dot(normal, screw_normal)
    intercept = _add(pilot, (distance * screw_normal[0], distance * screw_normal[1]))
    return _dot((normal[1], -normal[0]), _sub(intercept, hole))


def rear_fold_envelope(limit_deg=1.0):
    """Return certified extrema over all three independent +/- angle limits.

    Analytical derivative bounds certify monotonicity over the whole angle box;
    then its corners contain the extrema. This deliberately refuses a larger
    angle box if those derivative bounds cannot establish that conclusion.
    """
    if not 0 <= limit_deg < 30:
        raise ValueError('Angle limit must be between 0 and 30 degrees.')
    angle = math.radians(limit_deg)
    chord = lambda value: 2 * math.sin(value / 2)
    u = _sub(BASE_LAP_BEND, BASE_FLOOR_BEND)
    v = _sub(LID_LAP_BEND, BASE_FLOOR_BEND)
    cos_min, sin_max = math.cos(3 * angle), math.sin(3 * angle)
    values = []
    for depth in (0.0, LID_THICKNESS):
        r = _sub(_sub(LID_OUTER_HOLE, LID_LAP_BEND),
                 (depth * REAR_NORMAL[0], depth * REAR_NORMAL[1]))
        # N/cos(a+b-c) is the intercept. Bound the numerator and each
        # derivative using |R(theta)v-v| <= 2|v|sin(|theta|/2).
        change = (math.hypot(*_sub(u, v)) * chord(angle)
                  + math.hypot(*v) * chord(angle)
                  + math.hypot(*r) * chord(3 * angle))
        numerator_max = abs(rear_fold_offset(0, 0, 0, depth)) + change
        derivatives = (-_dot(REAR_NORMAL, _add(v, r)),
                       _dot(REAR_NORMAL, _sub(_sub(u, v), r)),
                       _dot(REAR_NORMAL, r))
        errors = (math.hypot(*v) * chord(2 * angle)
                  + math.hypot(*r) * chord(3 * angle),
                  change, math.hypot(*r) * chord(3 * angle))
        if any((abs(derivative) - error) * cos_min <= numerator_max * sin_max
               for derivative, error in zip(derivatives, errors)):
            raise ValueError('The derivative bounds do not certify this angle envelope.')
        for angles in product((-limit_deg, limit_deg), repeat=3):
            values.append(rear_fold_offset(*angles, depth))
    return min(values), max(values)


_SEATS = json.loads((Path(__file__).parent / 'reference/coated_seat_datums.json').read_text())


@dataclass(frozen=True)
class SeatPose:
    translation_yz: tuple[float, float]
    pitch_radians: float

    def displacement(self, point):
        relative = _sub(point, _SEATS['main_rear_yz'])
        return _add(self.translation_yz,
                    _sub(_rotate(relative, self.pitch_radians), relative))


def seated_lid_pose(main_front_lift, main_rear_lift, rear_lap_lift):
    """Solve one exact rigid pose against the three existing section contacts.

    Lifts are signed finished seat-normal displacements, or sums of opposed paint
    films. They are not additional independent tolerances when a stated finished
    dimension already contains them. This point-contact model does not prove full
    face contact, transverse fit, stiffness or flatness between the contacts.
    """
    main, rear = _SEATS['main_normal_yz'], _SEATS['rear_normal_yz']
    span = _sub(_SEATS['main_rear_yz'], _SEATS['main_front_yz'])
    tangent = (main[1], -main[0])
    pitch = (math.asin((_dot(main, span) + main_rear_lift - main_front_lift)
                       / math.hypot(*span))
             - math.atan2(_dot(main, span), _dot(tangent, span)))
    lap = _sub(_SEATS['rear_bore_yz'], _SEATS['main_rear_yz'])
    rotation_lift = _dot(rear, _sub(_rotate(lap, pitch), lap))
    translation = _solve_normals(main, rear, main_rear_lift,
                                 rear_lap_lift - rotation_lift)
    return SeatPose(translation, pitch)


@dataclass(frozen=True)
class RearJointCheck:
    screw_clearance_mm: float
    centerline_side_bridge_mm: float
    bearing_area_lower_bound_mm2: float | None
    perimeter_coverage_mm: float
    flat_land_mm: float


def evaluate_rear_joint(*, slot_length, slot_width, axial_offset, transverse_offset,
                        washer_od_min, washer_od_max, washer_id_max,
                        nearest_flat_edge_min, size_tolerance=0.20,
                        coat_max=0.10, screw_diameter=3.0, axis_angle_deg=0.0):
    """Bound screw fit and distinguish washer bearing from full slot coverage.

    Offsets bound the screw relative to the actual slot center at BOTH sheet faces.
    The flat-edge distance is the minimum to the four rectangular lap edges;
    it must already include slot/edge location allowances.
    Positive screw clearance proves the swept screw fits using a conservative
    circular bound on its tilted section. A positive side bridge describes the
    cross-slot centerline, not an allowable clamp load. Bearing area conservatively
    subtracts the entire largest bare slot and washer bore from the smallest washer
    disc. It is returned only when that washer is entirely on the planar lap.
    """
    if not (slot_length >= slot_width > size_tolerance + 2 * coat_max
            and 0 < screw_diameter <= washer_id_max < washer_od_min <= washer_od_max
            and 0 <= axis_angle_deg < 90
            and min(axial_offset, transverse_offset, nearest_flat_edge_min,
                    size_tolerance, coat_max) >= 0):
        raise ValueError('Invalid joint dimensions or displacement bounds.')
    straight_half = (slot_length - slot_width) / 2
    coated_radius = (slot_width - size_tolerance) / 2 - coat_max
    screw_radius = screw_diameter / (2 * math.cos(math.radians(axis_angle_deg)))
    corner_distance = math.hypot(max(0.0, axial_offset - straight_half), transverse_offset)
    clearance = coated_radius - screw_radius - corner_distance
    bare_radius = (slot_width + size_tolerance) / 2
    washer_float = (washer_id_max - screw_diameter) / 2
    outer_min = washer_od_min / 2
    coverage = outer_min - (bare_radius + math.hypot(straight_half + axial_offset,
                                                   transverse_offset) + washer_float)
    bridge = outer_min - bare_radius - transverse_offset - washer_float
    land = (nearest_flat_edge_min - max(axial_offset, transverse_offset)
            - washer_float - washer_od_max / 2)
    slot_area = math.pi * bare_radius**2 + 2 * straight_half * (2 * bare_radius)
    bearing = max(0.0, math.pi * (outer_min**2 - (washer_id_max / 2)**2) - slot_area)
    return RearJointCheck(clearance, bridge, bearing if land >= 0 else None, coverage, land)
