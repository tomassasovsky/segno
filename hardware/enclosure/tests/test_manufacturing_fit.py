"""Regressions against measured assembly datums and supplier mounting data."""
import shutil
import json
import hashlib
import re
import math
import itertools
from copy import deepcopy
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

import cadquery as cq
import ezdxf
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import segno_enclosure as enclosure
import flat_pattern_check
from fusion_export_formed import _validate_forming


class ManufacturingFitTest(unittest.TestCase):
    def test_rear_joint_line_matches_both_source_and_folded_side_edges(self):
        width = enclosure.W - 2*enclosure.T
        rear_inside_y = enclosure.D - 3*enclosure.T + enclosure.DEV90
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)/'base.dxf'; enclosure.dxf_base(str(path))
            contour = max((e for e in ezdxf.readfile(path).modelspace().query('LWPOLYLINE')
                           if e.dxf.layer == 'CUT'),key=lambda e:len(e))
            points = list(contour.get_points('xyb')); side_edges = []
            for a,b in zip(points,points[1:]+points[:1]):
                if a[2] or abs(a[1]-b[1]) > 1e-7 or abs(a[0]-b[0]) < 70:
                    continue
                if a[1] > 400 and (max(a[0],b[0]) < 0 or min(a[0],b[0]) > width):
                    side_edges.append(a[1])
            self.assertEqual(len(side_edges),2)
            for y in side_edges:
                self.assertAlmostEqual(rear_inside_y-y,.05,places=7)
        base = cq.importers.importStep(str(Path(enclosure.HERE)/'formed/segno_base.step')).val()
        straight_faces = [f for f in base.Faces() if f.geomType() == 'PLANE'
                          and abs(f.normalAt().y) > .999999
                          and abs(f.BoundingBox().xlen-2) < .001
                          and 70 < f.BoundingBox().zlen < 90 and f.Center().y > 400]
        self.assertEqual(len(straight_faces),2)
        for face in straight_faces:
            gap = rear_inside_y-face.Center().y
            self.assertAlmostEqual(gap,.05,places=4)
            self.assertGreater(gap,0)
            self.assertLessEqual(gap,.10)

    def test_rear_panel_allows_coating_within_ctrl_jack_range(self):
        enclosure._check()
        self.assertAlmostEqual(enclosure.REAR_PANEL_T + 2*enclosure.COAT_MIN,1.32)
        self.assertAlmostEqual(enclosure.REAR_PANEL_T + 2*enclosure.COAT_MAX,1.40)
        for thickness in (1.0,1.5):
            with self.subTest(thickness=thickness), patch.object(enclosure,'REAR_PANEL_T',thickness):
                with self.assertRaisesRegex(AssertionError,'finished rear panel'):
                    enclosure._check()

    def test_usb_openings_clear_the_supplier_four_flat_barrel(self):
        from flat_pattern_check import _face
        # Owner's dimensioned drawing: four flats 22.1 x 22.1, thread Ø24.1.
        body = (cq.Workplane('XY').rect(22.1,22.1).extrude(1).val()
                .intersect(cq.Workplane('XY').circle(12.05).extrude(1).val()))
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)/'panel.dxf'; enclosure.dxf_rear_panel(str(path))
            holes = []
            for e in ezdxf.readfile(path).modelspace().query('LWPOLYLINE'):
                if e.dxf.layer != 'CUT': continue
                face = _face(e); bb = face.BoundingBox()
                if abs(bb.xlen-22.8)<1e-6 and abs(bb.ylen-22.8)<1e-6:
                    holes.append(face)
            self.assertEqual(len(holes),2)
            for face in holes:
                center = face.Center()
                # Maximum machining undersize and maximum film leave the
                # intersection of a 22.50 square with a Ø24.50 circle.
                opening = (cq.Workplane('XY').rect(face.BoundingBox().xlen-.3,
                                                 face.BoundingBox().ylen-.3).extrude(1).val()
                           .intersect(cq.Workplane('XY').circle(12.25).extrude(1).val())
                           .translate((center.x,center.y,0)))
                actual = body.translate((center.x,center.y,0))
                self.assertLess(actual.cut(opening).Volume(),1e-7)
            # The removed tangent-fillet construction must fail this fit test.
            old = cq.Workplane('XY').rect(22.5,22.5).extrude(1).edges('|Z').fillet(8.8357864376269).val()
            self.assertGreater(body.cut(old).Volume(),.7)

    def test_straight_ring_disc_clears_root_and_is_covered_by_measured_washer(self):
        fixture = json.loads((Path(enclosure.HERE)/'reference'/
                              'ec11_disc_interface.json').read_text())
        # Independent existing EC11 root section, not derived from the new bore.
        root = (cq.Workplane('XZ').moveTo(0,0).lineTo(4,0)
                .threePointArc((3.6464466094,.1464466094),(3.5,.5))
                .lineTo(3.5,8).lineTo(0,8).close().revolve(360,(0,0),(0,1)).val())
        with tempfile.TemporaryDirectory() as tmp, patch.object(enclosure,'OUT',tmp):
            disc = cq.importers.importStep(enclosure.build_ring_disc_step()).val()
            self.assertTrue(disc.isValid())
            self.assertEqual(len(disc.Solids()),1)
            self.assertLess(disc.intersect(root).Volume(),1e-7)
            self.assertFalse(any(f.geomType()=='CONE' for f in disc.Faces()))
            bore = min((f for f in disc.Faces() if f.geomType()=='CYLINDER'),
                       key=lambda f:f._geomAdaptor().Radius())
            self.assertAlmostEqual(bore.BoundingBox().zlen,2.0,places=6)
            self.assertAlmostEqual(bore._geomAdaptor().Radius()*2,8.5,places=6)
        # Minimum raw hole with maximum local paint; OD at largest coated size.
        coated = cq.Workplane('XY').circle(25.725).circle(8.25/2).extrude(2.2).val()
        self.assertLess(coated.intersect(root).Volume(),1e-7)
        washer = fixture['washer']; shaft = fixture['modeled_mount']['bushing_diameter_mm']
        # Even allow the bore and washer to move in opposite directions around
        # the bushing. This is more severe than the intended centered assembly.
        for diameter, minimum_edge in ((8.55,.74),(8.43,.86)):
            offset = (diameter-shaft)/2+(washer['inside_diameter_mm']-shaft)/2
            edge = (washer['outside_diameter_mm']-diameter)/2-offset
            self.assertGreater(edge,minimum_edge)
            aperture = cq.Workplane('XY').circle(diameter/2).extrude(.1).val()
            coverage = (cq.Workplane('XY').circle(washer['outside_diameter_mm']/2)
                        .extrude(.1).val().translate((offset,0,0)))
            self.assertLess(aperture.cut(coverage).Volume(),1e-7)
        # Merely deleting the old relief without enlarging its hole still clashes.
        old_straight = cq.Workplane('XY').circle(25.75).circle(3.625).extrude(2).val()
        self.assertGreater(old_straight.intersect(root).Volume(),.1)

    def test_ring_holder_clears_selected_module_and_allows_bottom_insertion(self):
        # Independent numeric envelopes captured from the selected PR #990
        # module, including the actual header height and small centre offset.
        fixture = json.loads((Path(enclosure.HERE)/'reference'/
                              'ring24_interface.json').read_text())
        module = []
        for item in fixture['components']:
            lo, hi = item['z_mm']
            if item['kind'] == 'annulus':
                part = (cq.Workplane('XY').center(*item['center_mm'])
                        .circle(item['outer_radius_mm'])
                        .circle(item['inner_radius_mm']).extrude(hi-lo))
            else:
                part = (cq.Workplane('XY').polyline(item['outline_mm'])
                        .close().extrude(hi-lo))
            module.append(part.translate((0,0,lo)).val())
        self.assertEqual(len(module),41)
        with tempfile.TemporaryDirectory() as tmp, patch.object(enclosure,'OUT',tmp):
            holder = cq.importers.importStep(enclosure.build_ring_diffuser_step()).val()
        self.assertTrue(holder.isValid())
        self.assertEqual(len(holder.Solids()),1)
        self.assertGreater(min(part.distance(holder) for part in module),.13)
        for dz in (0,-.5,-2,-5):
            with self.subTest(insertion_offset_mm=dz):
                self.assertLess(sum(part.translate((0,0,dz)).intersect(holder).Volume()
                                    for part in module),1e-6)
        # Filling the LED relief restores the original functional failure.
        closed_lens = cq.Workplane('XY').circle(33.4).circle(25.85).extrude(2.4).val()
        self.assertGreater(sum(part.intersect(closed_lens).Volume()
                               for part in module),500)
        # A continuous lower support can clear the final position yet trap the
        # PCB during assembly. Reject that failure independently of final fit.
        lower_bridge = (cq.Workplane('XY').circle(37.5).circle(24.2)
                        .extrude(.75).translate((0,0,-3)).val())
        self.assertLess(sum(part.intersect(lower_bridge).Volume()
                            for part in module),1e-6)
        self.assertGreater(sum(part.translate((0,0,-1)).intersect(lower_bridge).Volume()
                               for part in module),500)

    def test_finished_disc_outer_diameter_preserves_holder_clearance(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(enclosure,'OUT',tmp):
            holder = cq.importers.importStep(enclosure.build_ring_diffuser_step()).val()
        # Saved disc/holder registration, independent of the generator. The
        # Bare Ø51.20±0.05 plus 60–100 µm per side yields Ø51.27..51.45;
        # no perimeter mask is used. Retain the original too-large control.
        offset = (-.00143,-.00364390070516,.00012873401494)
        for diameter in (51.27,51.45):
            disc = (cq.Workplane('XY').circle(diameter/2).circle(4.1)
                    .extrude(2).translate(offset).val())
            self.assertLess(disc.intersect(holder).Volume(),1e-7)
        coated = (cq.Workplane('XY').circle(51.7/2).circle(4.1)
                  .extrude(2).translate(offset).val())
        self.assertGreater(coated.intersect(holder).Volume(),.3)

    def test_every_corner_rivet_in_the_base_has_its_mate_in_a_bracket(self):
        """Ten rivets, drilled twice from two different developments.

        The base draws them from ITS bend lines and the bracket from its own, so
        the only thing making them meet is the pair of relations in dxf_base:
        along the wall s = CORNER_RO + T, up the wall s = T + RI + z - DEV90.
        An audit in 2026-09-04 found every one of them 2.0 mm off along the wall
        and 1.9 mm low (#992). This rebuilds both flats and pairs them up.
        """
        radius = enclosure.D_RIVET/2.0

        def circles(path):
            return [(e.dxf.center.x, e.dxf.center.y)
                    for e in ezdxf.readfile(path).modelspace()
                    if e.dxftype() == 'CIRCLE' and abs(e.dxf.radius-radius) < 1e-9]

        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)/'segno_base.dxf'
            enclosure.dxf_base(str(base))
            base_holes = circles(str(base))
            bracket = Path(tmp)/'b.dxf'
            enclosure.dxf_corner_bracket(str(bracket))
            bracket_holes = circles(str(bracket))
        self.assertEqual(len(base_holes), 10)
        self.assertEqual(len(bracket_holes), 5)

        bw, bd = enclosure.W-2*enclosure.T, enclosure.D-2*enclosure.T
        along = enclosure.CORNER_RO + enclosure.T
        up = lambda z: enclosure.T + enclosure.RI + z - enclosure.DEV90
        want = set()
        for sign, xc in ((+1, 0.0), (-1, bw)):
            for z in enclosure.CORNER_ZR_WALL:          # rear-wall face
                want.add((round(xc + sign*along, 6), round(bd + up(z), 6)))
            for z in enclosure.CORNER_ZR_SIDE:          # side-wall face
                want.add((round(xc - sign*up(z), 6), round(bd - along, 6)))
        self.assertEqual({(round(x, 6), round(y, 6)) for x, y in base_holes}, want)

        # the bracket's own five, measured from ITS bend line at CORNER_LEG
        self.assertEqual(
            sorted((round(x, 6), round(y, 6)) for x, y in bracket_holes),
            sorted([(enclosure.CORNER_LEG-enclosure.CORNER_RO, float(z))
                    for z in enclosure.CORNER_ZR_WALL]
                   + [(enclosure.CORNER_LEG+enclosure.CORNER_RO, float(z))
                      for z in enclosure.CORNER_ZR_SIDE]))

    def test_the_mirrored_bracket_reuses_one_flat_and_still_lands(self):
        """Both hands ship the same hole pattern; only the outline is mirrored.

        That is sound only while the rivet heights are symmetric about
        CORNER_HT/2, because the mirrored bracket's flat y reads as
        CORNER_HT - y in the world. Break the symmetry and the left corner's
        rivets miss the base by twice the asymmetry.
        """
        with tempfile.TemporaryDirectory() as tmp:
            paths = []
            for mirrored in (False, True):
                path = Path(tmp)/('m.dxf' if mirrored else 'd.dxf')
                enclosure.dxf_corner_bracket(str(path), mirrored=mirrored)
                paths.append([(e.dxf.center.x, e.dxf.center.y)
                              for e in ezdxf.readfile(str(path)).modelspace()
                              if e.dxftype() == 'CIRCLE'
                              and abs(e.dxf.radius-enclosure.D_RIVET/2.0) < 1e-9])
        self.assertEqual(sorted(paths[0]), sorted(paths[1]))
        for row in (enclosure.CORNER_ZR_WALL, enclosure.CORNER_ZR_SIDE):
            self.assertEqual(sorted(row),
                             sorted(enclosure.CORNER_HT-z for z in row))
        # and no rivet from one leg shares a height with one from the other
        self.assertFalse(set(enclosure.CORNER_ZR_WALL) & set(enclosure.CORNER_ZR_SIDE))

    def test_rivet_edge_distances_are_the_ones_the_shop_was_asked_to_qualify(self):
        """The base is comfortable; the bracket leg is the tight part.

        Recorded rather than silently tolerated: 4.0 mm to the leg's free edge
        is 1.25 x rivet diameter, under the usual 2 x rule of thumb, which is why
        MANUFACTURING.md asks the shop to qualify it. If the leg or the offset
        ever moves, this says which way it moved.
        """
        radius = enclosure.D_RIVET/2.0
        free_edge = enclosure.CORNER_LEG - enclosure.CORNER_RO
        self.assertAlmostEqual(free_edge, 4.0, places=6)
        self.assertAlmostEqual(free_edge - radius, 2.35, places=6)
        # the bend side has to clear the deformation zone, and does
        self.assertGreaterEqual(enclosure.CORNER_RO,
                                enclosure.RI + enclosure.T + radius)
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)/'segno_base.dxf'
            enclosure.dxf_base(str(path))
            document = ezdxf.readfile(str(path))
            holes = [(e.dxf.center.x, e.dxf.center.y) for e in document.modelspace()
                     if e.dxftype() == 'CIRCLE' and abs(e.dxf.radius-radius) < 1e-9]
            outline = max((flat_pattern_check._face(e) for e in document.modelspace()
                           if e.dxftype() == 'LWPOLYLINE' and e.dxf.layer == 'CUT'),
                          key=lambda f: f.Area()).outerWire()
        worst = min(outline.distance(cq.Vertex.makeVertex(x, y, 0)) for x, y in holes)
        self.assertGreater(worst - radius, 8.0)     # 8.211 mm as drawn

    def test_formed_beam_clears_measured_lid_with_coating_allowance(self):
        beam = enclosure._beam_solid().translate((
            enclosure.BEAM_U0,
            enclosure._BEAM_VP-enclosure.BEAM_FOOTL, 2.0))
        # Independent live Fusion probe, September 4: actual underside plane.
        normal = cq.Vector(0, -0.21640965505268422, 0.9763026483626777)
        point = cq.Vector(423, 196.8595704517108, 56.059667385991496)
        pad = max((f for f in beam.Faces() if f.geomType() == 'PLANE'
                   and f.normalAt().dot(normal) > .999999), key=lambda f:f.Area())
        gap = normal.dot(point-pad.Center())
        self.assertAlmostEqual(gap, 1.2, places=6)
        self.assertAlmostEqual(beam.BoundingBox().zmin, 2.0, places=6)
        # Both bends must have real concentric inner/outer radii, not a joining cube.
        # The two LONG bends must have real concentric inner/outer radii, not a
        # joining cube. (The two wall ears bend about vertical axes and are
        # filtered out here; the assembly test counts all four.)
        bends = [f for f in beam.Faces() if f.geomType() == 'CYLINDER'
                 and abs(f._geomAdaptor().Axis().Direction().X()) > .999
                 and round(f._geomAdaptor().Radius(), 6) in (1.6, 3.2)]
        self.assertEqual(len(bends), 4)
        self.assertEqual(sorted(round(f._geomAdaptor().Radius(), 6) for f in bends),
                         [1.6, 1.6, 3.2, 3.2])

    def test_front_holes_are_secondary_drilling_and_bucks_follow_image(self):
        with tempfile.TemporaryDirectory() as tmp:
            for stem, writer, diameter in [('base', enclosure.dxf_base, 2.5),
                                           ('faceplate', enclosure.dxf_faceplate, 4.5)]:
                path = Path(tmp)/f'{stem}.dxf'; writer(str(path))
                entities = list(ezdxf.readfile(path).modelspace())
                drills = [e for e in entities if e.dxf.layer == 'DRILL']
                self.assertEqual(len(drills), 9 if stem == 'base' else 18)
                self.assertTrue(all(e.dxftype() == 'CIRCLE' and
                                    abs(2*e.dxf.radius-diameter) < 1e-8 for e in drills))
                cuts = [e for e in entities if e.dxf.layer == 'CUT' and e.dxftype() == 'CIRCLE']
                self.assertFalse(any(e.dxf.center.distance(d.dxf.center) < .01
                                     for e in cuts for d in drills))
                if stem == 'base':
                    # 53.9 pitch; hole row 31.3 from the forward edge of 57.6 body.
                    actual = [(e.dxf.center.x,e.dxf.center.y) for e in cuts
                              if abs(2*e.dxf.radius-4.6) < .001 and
                              320 < e.dxf.center.x < 490 and 350 < e.dxf.center.y < 370]
                    self.assertEqual(len(actual), 4)
                    expected = [(u+du, 367.5) for u in (372.15,447.85) for du in (-26.95,26.95)]
                    for a,b in zip(sorted(actual),sorted(expected)):
                        self.assertAlmostEqual(a[0],b[0],places=6)
                        self.assertAlmostEqual(a[1],b[1],places=6)

    def test_measured_monitor_and_stands_seat_on_floor_and_each_other(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(enclosure, 'OUT', tmp):
            paths = enclosure.build_screen16_stand_steps()
            enclosure.build_screen16_monitor_step()  # solid contact/interference checks
            display, body, block = enclosure._s16_monitor_solids()
            self.assertAlmostEqual(body.val().BoundingBox().xlen,354.0,places=6)
            self.assertGreater(display.val().Area(), 100000)
            for path in paths:
                shape = cq.importers.importStep(path).val()
                self.assertTrue(shape.isValid())
                self.assertEqual(len(shape.Solids()),1)
                self.assertAlmostEqual(shape.BoundingBox().zmin,2.0,places=6)
                self.assertLess(shape.intersect(body.val().fuse(block.val())).Volume(),1.0)

    @staticmethod
    def _fully_coated_seat_cases():
        fixture = json.loads((Path(enclosure.HERE)/'reference/coated_seat_datums.json').read_text())
        main = np.array(fixture['main_normal_yz'])
        rear = np.array(fixture['rear_normal_yz'])
        pivot = np.array(fixture['main_rear_yz'])
        cross = np.array([[0,-1],[1,0]])
        constraints = [(main,fixture['main_front_yz']),
                       (main,fixture['main_rear_yz']),
                       (rear,fixture['rear_bore_yz'])]
        matrix = np.array([[*normal,normal@(cross@(np.array(point)-pivot))]
                           for normal,point in constraints])
        front = np.array([fixture['front_lid_bore_y'],6.455420469476287])
        lap = np.array(fixture['rear_bore_yz'])
        cases = []
        # Independent film at both ends of the main seat and at the rear lap.
        # This includes pitch caused by a thickness gradient, not just a
        # uniform translation that would understate front-axis movement.
        for film_pairs in itertools.product((.12,.20),repeat=3):
            dy,dz,pitch = np.linalg.solve(matrix,np.array(film_pairs))
            front_delta = np.array([dy,dz])+pitch*(cross@(front-pivot))
            rear_delta = np.array([dy,dz])+pitch*(cross@(lap-pivot))
            tangent = np.array([rear[1],-rear[0]])@rear_delta
            cases.append((front_delta,tangent))
        return cases

    def test_fully_coated_lid_holes_allow_seat_motion_and_assembly_variation(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)/'lid.dxf'; enclosure.dxf_faceplate(str(path))
            drills = [e for e in ezdxf.readfile(path).modelspace()
                      if e.dxf.layer == 'DRILL' and e.dxftype() == 'CIRCLE']
        self.assertEqual(len(drills),18)
        clearance = min(e.dxf.radius for e in drills)-.10-1.50
        # ±.15 centering at each assembly, asymmetric coated edge datums,
        # local angular residue, and ±.10 opening/transfer position per axis.
        horizontal = .30+.04+.01+.10
        cases = self._fully_coated_seat_cases()
        front = max(math.hypot(horizontal,abs(d[1])+.10)for d,_ in cases)
        rear = max(math.hypot(horizontal,abs(t)+.10)for _,t in cases)
        self.assertGreater(clearance-front,.08)
        self.assertGreater(clearance-rear,.12)
        self.assertGreater(front,(3.4-.20-3.0)/2)  # former bore cannot meet it
        gaps = [bare-delta[0]-film for delta,_ in cases
                for bare,film in itertools.product((.50,.60),(.12,.20))]
        self.assertGreater(min(gaps),.15)
        self.assertLess(max(gaps),.60)

    def test_painted_light_apertures_clear_existing_printed_lenses(self):
        from flat_pattern_check import _face
        with tempfile.TemporaryDirectory() as tmp, patch.object(enclosure,'OUT',tmp):
            path = Path(tmp)/'lid.dxf'; enclosure.dxf_faceplate(str(path))
            doc = ezdxf.readfile(path)
            diffuser = cq.importers.importStep(enclosure.build_diffuser_step()).val()
            section = diffuser.intersect(cq.Workplane('XY').box(90,20,.1)
                                          .translate((0,0,.5)).val()).BoundingBox()
            self.assertAlmostEqual(section.xlen,59.8,places=6)
            self.assertAlmostEqual(section.ylen,5.8,places=6)
            # Include +0.20 mm overall printed size, independently of the
            # source's own clearances. The physical lens must not grow merely
            # because its metal aperture gained a coating allowance.
            largest_lens = cq.Workplane('XY').slot2D(section.xlen+.2,section.ylen+.2).extrude(1).val()
            pills = []
            for entity in doc.modelspace().query('LWPOLYLINE'):
                if entity.dxf.layer != 'CUT':continue
                face = _face(entity);bb = face.BoundingBox()
                if 59 < bb.xlen < 62 and 5 < bb.ylen < 8:pills.append(face)
            self.assertEqual(len(pills),10)
            for face in pills:
                bb = face.BoundingBox()
                aperture = cq.Workplane('XY').slot2D(bb.xlen-.20,bb.ylen-.20).extrude(1).val()
                material = cq.Workplane('XY').box(90,20,1,centered=(True,True,False)).val().cut(aperture)
                self.assertLess(largest_lens.cut(aperture).Volume(),1e-7)
                self.assertGreater(largest_lens.distance(material),.099)
            old = cq.Workplane('XY').slot2D(59.8,5.8).extrude(1).val()
            self.assertGreater(largest_lens.cut(old).Volume(),10)
            holder = cq.importers.importStep(enclosure.build_ring_diffuser_step()).val()
            lens_radius = max(f._geomAdaptor().Radius()for f in holder.Faces()
                              if f.geomType()=='CYLINDER' and f.BoundingBox().zmax>.1)
            self.assertAlmostEqual(lens_radius,33.4,places=6)
            rings = [e for e in doc.modelspace().query('CIRCLE')
                     if e.dxf.layer=='CUT' and 33<e.dxf.radius<35]
            self.assertEqual(len(rings),1)
            self.assertGreater(rings[0].dxf.radius-.1-(lens_radius+.1),.099)

    def test_converter_reference_matches_supplier_mounts_and_clearance_envelope(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(enclosure, 'OUT', tmp):
            shape = cq.importers.importStep(enclosure.build_buck_reference_step()).val()
            envelope = cq.importers.importStep(str(Path(tmp)/'segno_buck_envelope.step')).val()
            self.assertTrue(shape.isValid())
            self.assertEqual(len(shape.Solids()),1)
            bounds = shape.BoundingBox()
            for actual, expected in zip((bounds.xlen,bounds.ylen,bounds.zlen),
                                        (63.7,57.6,22.0)):
                self.assertAlmostEqual(actual,expected,places=5)
            self.assertAlmostEqual(bounds.zmin,0,places=6)
            self.assertLess(shape.cut(envelope).Volume(),.001)
            axes = self._cylinder_axes(shape,3.25)
            self.assertEqual(len(axes),2)
            for axis, x in zip(sorted(axes,key=lambda a:a.Location().X()),(-26.95,26.95)):
                self.assertAlmostEqual(axis.Location().X(),x,places=6)
                self.assertAlmostEqual(axis.Location().Y(),2.5,places=6)
                self.assertGreater(abs(axis.Direction().Z()),.99999)
            # The mounting ears are accessible above their low bosses; this
            # rejects the previous full-height block with two drilled holes.
            for x in (-26.95,26.95):
                access = cq.Workplane('XY').workplane(offset=3.21).center(x,2.5).circle(4.5).extrude(19)
                self.assertLess(shape.intersect(access.val()).Volume(),.001)


    def test_native_cache_rejects_changed_cut_geometry_and_altered_step(self):
        source = Path(enclosure.HERE)
        stem = 'segno_corner_bracket_rear'
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); out = root/'out'; out.mkdir()
            shutil.copytree(source/'formed', root/'formed')
            flat = out/(stem+'.dxf')
            shutil.copyfile(source/'out'/(stem+'.dxf'), flat)
            with patch.object(enclosure, 'HERE', str(root)), patch.object(enclosure, 'OUT', str(out)):
                path, _ = enclosure._formed_record(stem)
                # Moving an actual mounting hole must invalidate the formed model.
                doc = ezdxf.readfile(flat)
                circle = next(e for e in doc.modelspace()
                              if e.dxf.layer == 'CUT' and e.dxftype() == 'CIRCLE')
                circle.dxf.center = circle.dxf.center + (1,0,0)
                doc.saveas(flat)
                with self.assertRaisesRegex(AssertionError, 'stale'):
                    enclosure._formed_record(stem)
                shutil.copyfile(source/'out'/(stem+'.dxf'), flat)
                with open(path, 'a') as file:
                    file.write('altered after native verification')
                with self.assertRaisesRegex(AssertionError, 'differs from its verified export'):
                    enclosure._formed_record(stem)

    def test_assembly_has_every_made_part_and_twenty_seven_purchased_references(self):
        source = Path(enclosure.HERE)/'out'
        with tempfile.TemporaryDirectory() as tmp, patch.object(enclosure, 'OUT', tmp):
            for stem in (*enclosure.FORMED_PARTS,'segno_rear_panel'):
                shutil.copyfile(source/(stem+'.dxf'),Path(tmp)/(stem+'.dxf'))
            enclosure.build_ring_disc_step()
            path = enclosure.build_step()
            assembly = cq.importers.importStep(path).val()
            self.assertTrue(assembly.isValid())
            solids = assembly.Solids()
            self.assertEqual(len(solids),34)       # 33 + the one support beam (#1019)
            names = re.findall(r"NEXT_ASSEMBLY_USAGE_OCCURRENCE\('[^']*',\s*'([^']*)'",
                               Path(path).read_text())
            purchased = {f'PURCHASED_FITTED_FRONT_SHIM_PACK_{i}' for i in range(1,10)}
            purchased |= {f'PURCHASED_M3_WASHER_{end}_{i}'
                          for end in ('FRONT','REAR')for i in range(1,10)}
            self.assertEqual(set(names),purchased | {
                'segno_base_1','segno_faceplate_1','segno_corner_bracket_rear_1',
                'segno_corner_bracket_rear_mirrored_1','segno_rear_panel',
                'segno_ring_disc', 'segno_beam'})
            self.assertEqual(len(names),34)
            shims = [s for s in solids if len(self._cylinder_axes(s,2.05)) == 1
                     and s.BoundingBox().xlen < 10]
            washers = [s for s in solids if len(self._cylinder_axes(s,1.6)) == 1
                       and len(self._cylinder_axes(s,3.5)) == 1]
            self.assertEqual(len(shims),9)
            self.assertEqual(len(washers),18)
            self.assertEqual(len(solids)-len(shims)-len(washers),7)
            base, lid = sorted(solids,key=lambda s:s.Volume(),reverse=True)[:2]
            self.assertAlmostEqual(base.BoundingBox().zmin,0.0,places=5)
            self.assertAlmostEqual(lid.BoundingBox().ymin,-4.4108425,places=4)
            self.assertLess(abs(lid.BoundingBox().zmin),.001)
            # the support beam is the only part with the steel bend radii: four
            # inside (1.6) and four outside (3.2) -- the two long folds and the
            # two wall ears
            beam_solids = [s for s in solids if len(self._cylinder_axes(s,1.6)) == 4
                           and len(self._cylinder_axes(s,3.2)) == 4]
            self.assertEqual(len(beam_solids),1)
            self._assert_remaining_seats(solids,base,lid)
            self._assert_front_shim_seats(shims,base,lid)
            self._assert_lid_washer_seats(washers,lid)
            unsupported = [shims[0].translate((0,-.05,0))]+shims[1:]
            with self.assertRaises(AssertionError):
                self._assert_front_shim_seats(unsupported,base,lid)
            displaced = [s.translate((100,0,0)) if len(self._cylinder_axes(s,1.65)) == 5
                         else s for s in solids]
            with self.assertRaises(AssertionError):
                self._assert_remaining_seats(displaced,base,lid)
            for solid in beam_solids:
                self.assertAlmostEqual(solid.BoundingBox().zmin,2.0,places=5)
                self.assertLess(solid.intersect(lid).Volume(),.001)
                # The foot lies ON the floor top over its whole 845 mm, and a
                # coincident-face intersection leaves a sliver that grows with
                # contact length (the seven 30 mm posts left almost none). A real
                # clash even 0.01 mm deep would be 183 mm3 here, so 0.05 still
                # separates the two by three orders of magnitude.
                self.assertLess(solid.intersect(base).Volume(),.05)
                self.assertAlmostEqual(solid.BoundingBox().ymin,138.996937,places=5)
                # wall to wall, not seven pads over a quarter of the panel
                self.assertGreater(solid.BoundingBox().xlen,800.0)


    @staticmethod
    def _cylinder_axes(solid, radius):
        return [face._geomAdaptor().Axis() for face in solid.Faces()
                if face.geomType() == 'CYLINDER'
                and abs(face._geomAdaptor().Radius()-radius)<.001]

    def _assert_front_shim_seats(self, shims, base, lid):
        # Inspect the actual exported body planes and drilled axes. The nominal
        # pads must bridge these faces at all nine stations without moving the
        # lid. These are bare geometry references; physical pack thickness is
        # selected from the painted gap after curing.
        self.assertEqual(len(shims),9)
        holes = sorted((axis for axis in self._cylinder_axes(base,1.25)
                        if abs(axis.Direction().Y())>.999999 and axis.Location().Y()<0),
                       key=lambda axis:axis.Location().X())
        self.assertEqual(len(holes),9)
        base_plane = max((f for f in base.Faces() if f.geomType()=='PLANE'
                          and f.normalAt().y<-.999999 and f.Center().y<0),key=lambda f:f.Area())
        lid_plane = max((f for f in lid.Faces() if f.geomType()=='PLANE'
                         and f.normalAt().y>.999999 and f.Center().y<0),key=lambda f:f.Area())
        for shim, hole in zip(sorted(shims,key=lambda s:s.Center().x),holes):
            self.assertTrue(shim.isValid())
            self.assertEqual(len(shim.Solids()),1)
            bb = shim.BoundingBox()
            self.assertAlmostEqual(bb.xlen,7,places=5)
            self.assertAlmostEqual(bb.zlen,7,places=5)
            self.assertAlmostEqual(hole.Location().Z(),6.45542044,places=5)
            bore = self._cylinder_axes(shim,2.05)
            self.assertEqual(len(bore),1)
            self.assertGreater(abs(bore[0].Direction().Dot(hole.Direction())),.999999)
            offset = cq.Vector(bore[0].Location()).sub(cq.Vector(hole.Location()))
            self.assertLess(offset.cross(cq.Vector(hole.Direction())).Length,.005)
            self.assertAlmostEqual(bb.ymax,base_plane.Center().y,places=5)
            self.assertAlmostEqual(bb.ymin,lid_plane.Center().y,places=5)
            ends = sorted((f for f in shim.Faces() if f.geomType()=='PLANE'),
                          key=lambda f:f.Center().y)
            self.assertEqual(len(ends),2)
            for face, body, direction in ((ends[0],lid,-1),(ends[1],base,1)):
                # The Ø7 shim reaches over the receding lower bend. Full-ring
                # support is no longer claimed; require actual planar bearing
                # exceeding the independently bounded coated minimum16mm².
                # Translating a pack into the gap still fails this probe.
                probe = cq.Solid.extrudeLinear(face.outerWire(),face.innerWires(),
                                              cq.Vector(0,direction*.01,0))
                self.assertGreater(probe.intersect(body).Volume()/.01,16)
                self.assertLess(shim.intersect(body).Volume(),.0001)

    def _assert_lid_washer_seats(self, washers, lid):
        self.assertEqual(len(washers),18)
        holes = self._cylinder_axes(lid,2.25)
        self.assertEqual(len(holes),18)
        for washer in washers:
            self.assertTrue(washer.isValid())
            axis = self._cylinder_axes(washer,1.6)[0]
            same_direction = [h for h in holes if abs(axis.Direction().Dot(h.Direction()))>.999999]
            self.assertEqual(len(same_direction),9)
            distance = min(cq.Vector(axis.Location()).sub(cq.Vector(h.Location()))
                           .cross(cq.Vector(h.Direction())).Length for h in same_direction)
            self.assertLess(distance,.00001)
            self.assertLess(washer.intersect(lid).Volume(),.000001)
            planes = [f for f in washer.Faces()if f.geomType()=='PLANE']
            bearing = min(planes,key=lambda f:f.distance(lid))
            self.assertLess(bearing.distance(lid),.00001)
            probe = cq.Solid.extrudeLinear(bearing.outerWire(),bearing.innerWires(),
                                          bearing.normalAt()*.01)
            self.assertGreater(probe.intersect(lid).Volume()/.01,18)

    def _assert_remaining_seats(self, solids, base, lid):
        # Independent assembled Fusion measurements, September 4, mm.
        brackets = sorted((s for s in solids if len(self._cylinder_axes(s,1.65)) == 5),
                          key=lambda s:s.BoundingBox().xmin)
        self.assertEqual(len(brackets),2)
        for bracket, xmin in zip(brackets,(.1,831.989159)):
            bb = bracket.BoundingBox()
            self.assertAlmostEqual(bb.xmin,xmin,places=4)
            self.assertAlmostEqual(bb.ymax,418.900841,places=4)
            self.assertAlmostEqual(bb.zmin,4,places=4)
            holes = self._cylinder_axes(bracket,1.65)
            self.assertEqual(len(holes),5)
            for hole in holes:
                # Coaxial through-rivet holes on the rear and side faces.
                candidates = [axis for axis in self._cylinder_axes(base,1.65)
                              if abs(axis.Direction().Dot(hole.Direction()))>.999999]
                offset = min(cq.Vector(axis.Location()).sub(cq.Vector(hole.Location()))
                             .cross(cq.Vector(hole.Direction())).Length for axis in candidates)
                self.assertLess(offset,.02)
        panel = next(s for s in solids if abs(s.BoundingBox().xlen-402)<.001
                     and abs(s.BoundingBox().zlen-76)<.001)
        bb = panel.BoundingBox()
        self.assertAlmostEqual(bb.ylen,1.2,places=6)
        self.assertAlmostEqual(bb.ymin,417.710841,places=4)
        self.assertAlmostEqual(bb.ymax,418.910841,places=4)
        self.assertAlmostEqual(bb.xmin,424.285714,places=4)
        holes = [axis for axis in self._cylinder_axes(panel,1.8)
                 if abs(axis.Location().X()-430.285714)<.01
                 or abs(axis.Location().X()-820.285714)<.01]
        self.assertEqual(len(holes),4)
        for hole in holes:
            candidates = [axis for axis in self._cylinder_axes(base,1.8)
                          if abs(axis.Direction().Dot(hole.Direction()))>.999999]
            offset = min(cq.Vector(axis.Location()).sub(cq.Vector(hole.Location()))
                         .cross(cq.Vector(hole.Direction())).Length for axis in candidates)
            self.assertLess(offset,.02)
        ring = next(s for s in solids if abs(s.BoundingBox().xlen-51.2)<.001)
        shaft = self._cylinder_axes(ring,4.25)[0]
        aperture = self._cylinder_axes(lid,33.7)[0]
        self.assertGreater(abs(shaft.Direction().Dot(aperture.Direction())),.999999)
        offset = cq.Vector(shaft.Location()).sub(cq.Vector(aperture.Location()))
        self.assertLess(offset.cross(cq.Vector(shaft.Direction())).Length,.02)
        normal = cq.Vector(0,-.21640965505268422,.9763026483626777)
        planes = sorted(normal.dot(f.Center()) for f in ring.Faces()
                        if f.geomType() == 'PLANE')
        self.assertAlmostEqual(planes[0],12.12889,places=5)
        self.assertAlmostEqual(planes[-1],14.12889,places=5)

    def test_native_base_flat_matches_all_cut_and_deferred_drill_geometry(self):
        from flat_pattern_check import compare_flat_pattern
        source = Path(enclosure.HERE)/'out/segno_base.dxf'
        native = Path(enclosure.HERE)/'formed/segno_base_flat.dxf'
        result = compare_flat_pattern(source, native)
        self.assertGreater(result['matched_reference_holes'], 100)
        self.assertLessEqual(result['missing_area_mm2'], .01)
        self.assertLessEqual(result['extra_area_mm2'], .01)
        with tempfile.TemporaryDirectory() as tmp:
            altered = Path(tmp)/'wrong.dxf'
            for name in ('relief', 'front trim', 'hole', 'extra material'):
                with self.subTest(name=name):
                    doc = ezdxf.readfile(source)
                    if name == 'relief':
                        with patch.object(enclosure, 'BASE_CORNER_RELIEF_D', 6.7):
                            enclosure.dxf_base(str(altered))
                        doc = ezdxf.readfile(altered)
                    elif name == 'front trim':
                        with patch.object(enclosure, 'BASE_FRONT_END_CLEAR', 0.0):
                            enclosure.dxf_base(str(altered))
                        doc = ezdxf.readfile(altered)
                    elif name == 'hole':
                        e = next(e for e in doc.modelspace().query('CIRCLE')
                                 if e.dxf.layer == 'CUT' and abs(e.dxf.radius-1.65)<.001)
                        e.dxf.center += (1,0,0)
                    else:
                        e = next(e for e in doc.modelspace().query('CIRCLE')
                                 if e.dxf.layer == 'DRILL')
                        doc.modelspace().delete_entity(e)
                    doc.saveas(altered)
                    with self.assertRaisesRegex(AssertionError, 'flat-pattern mismatch'):
                        compare_flat_pattern(altered,native)
            doc = ezdxf.readfile(source)
            doc.modelspace().add_lwpolyline(
                [(1200,0),(1210,0),(1210,10),(1200,10)], close=True,
                dxfattribs={'layer':'CUT'})
            doc.saveas(altered)
            with self.assertRaisesRegex(AssertionError, 'contour lies outside the sheet'):
                compare_flat_pattern(altered,native)

    def test_generator_rejects_altered_or_geometrically_wrong_native_flat(self):
        source = Path(enclosure.HERE)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); out = root/'out'; out.mkdir()
            shutil.copytree(source/'formed', root/'formed')
            shutil.copyfile(source/'out/segno_base.dxf', out/'segno_base.dxf')
            with patch.object(enclosure, 'HERE', str(root)), patch.object(enclosure, 'OUT', str(out)):
                enclosure._formed_record('segno_base')
                flat = root/'formed/segno_base_flat.dxf'
                doc = ezdxf.readfile(flat)
                hole = next(e for e in doc.modelspace().query('CIRCLE')
                            if e.dxf.layer == 'INTERIOR_PROFILES' and abs(e.dxf.radius-1.65)<.001)
                hole.dxf.center += (1,0,0)
                doc.saveas(flat)
                with self.assertRaisesRegex(AssertionError, 'flat pattern differs'):
                    enclosure._formed_record('segno_base')
                manifest = root/'formed/manifest.json'
                data = json.loads(manifest.read_text())
                data['segno_base']['flat_pattern_sha256'] = hashlib.sha256(flat.read_bytes()).hexdigest()
                manifest.write_text(json.dumps(data))
                with self.assertRaisesRegex(AssertionError, 'flat-pattern mismatch'):
                    enclosure._formed_record('segno_base')

    def test_native_verification_rejects_wrong_rules_bends_and_drilling(self):
        root = Path(enclosure.HERE)
        expected = json.loads((root/'out/fusion_formed_input.json').read_text())['segno_base']
        captured = json.loads((root/'formed/manifest.json').read_text())['segno_base']['forming']
        _validate_forming(expected,captured)  # actual native capture, not mocked API calls
        mutations = [
            ('sheet rule', lambda data: data['rule'].update(thickness_mm=1.5)),
            ('angle', lambda data: data['folds'][0].update(angle_deg=1.0)),
            ('direction', lambda data: data['folds'][0].update(angle_deg=-90.0)),
            ('fold source line', lambda data: data['folds'][0]['line'][1][0].__setitem__(0,1.0)),
            ('hole position', lambda data: data['front_drill'][0].__setitem__(0,300.0)),
            ('hole radius', lambda data: data['front_drill'][0].__setitem__(2,2.0)),
            ('blind hole', lambda data: data['front_drill'][0].__setitem__(4,-1.0)),
        ]
        for name, mutate in mutations:
            with self.subTest(name=name):
                changed = deepcopy(captured); mutate(changed)
                with self.assertRaises(AssertionError):
                    _validate_forming(expected,changed)


if __name__ == '__main__':
    unittest.main()
