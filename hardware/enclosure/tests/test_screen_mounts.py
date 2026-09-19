"""The screen mounts after #1070: closed where they can be, one mirrored 15.6in
part, and adjustable on the floor.

Owner review 2026-09-18: too many openings, 15.6in halves that were not mirror
images, and no adjustment for tolerances. Each test below pins one answer.
"""
from contextlib import redirect_stdout
import io
import itertools
import json
import math
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

import cadquery as cq
from OCP.BRepAdaptor import BRepAdaptor_Surface

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import segno_enclosure as enclosure

SLOPE = math.radians(enclosure.SLOPE_ANGLE)


class ScreenMountTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.output = tempfile.TemporaryDirectory(prefix='segno-screen-mounts-')
        cls.addClassCleanup(cls.output.cleanup)
        out = Path(cls.output.name)
        with patch.object(enclosure, 'OUT', str(out)), redirect_stdout(io.StringIO()):
            enclosure.build_screen7_tower_step()
            enclosure.build_screen16_stand_steps()
            enclosure.build_screen16_monitor_step()
            enclosure.build_screen7_deck_fit_test()
            enclosure.build_screen16_vesa_fit_test()
            enclosure.build_screen16_deck_fit_test()
        cls.parts = {p.stem: cq.importers.importStep(str(p)).val()
                     for p in out.glob('*.step')}
        cls.tower = cls.parts['segno_screen7_tower']

    # --- 7in tower ---------------------------------------------------------

    def deck_point(self, x, y, depth):
        """Tower-frame point `depth` below the deck top, at in-plane (x, y)."""
        return cq.Vector(x,
                         y * math.cos(SLOPE) + depth * math.sin(SLOPE),
                         enclosure.S7T_H0 + y * math.sin(SLOPE) - depth * math.cos(SLOPE))

    def test_7in_deck_is_closed_except_the_connector_notch(self):
        """v3 had a 146 x 96 window here. Sample the deck skin every 5 mm across
        the module's footprint: every point is metal unless it lies in the notch."""
        x0, y0, x1, y1 = enclosure.S7C_MOD_BB
        ny0 = enclosure.S7C_PORTS_Y[0] - enclosure.S7T_PLUG_MARGIN
        ny1 = enclosure.S7C_PORTS_Y[1] + enclosure.S7T_PLUG_MARGIN
        nx0 = enclosure.S7C_PORTS_X0 - enclosure.S7T_PLUG_MARGIN
        open_points = []
        for i, j in itertools.product(range(int(x0) + 5, int(x1) - 4, 5),
                                      range(int(y0) + 5, int(y1) - 4, 5)):
            in_notch = i > nx0 - 0.5 and ny0 - 0.5 < j < ny1 + 0.5
            if any(math.dist((i, j), h) < 3.0 for h in enclosure.S7C_HOLES):
                continue                              # a tab boss's own pilot
            if not self.tower.isInside(self.deck_point(i, j, 1.0)):
                open_points.append((i, j))
                self.assertTrue(in_notch, f'deck open at ({i}, {j}), outside the connector notch')
        self.assertTrue(open_points, 'the connector notch is missing')

    def test_7in_tower_prints_flange_down_without_support(self):
        """Every downward face is either on the bed or leans at least 44 degrees
        from horizontal. The worst ones are the gables, where 45 degrees across the
        cell meets the 12.5 degree deck slope. A flat ceiling anywhere would need
        support inside a closed box, where nobody can remove it."""
        bed = enclosure.STAND_SHIM_NOM
        limit = math.cos(math.radians(44.0))
        for face in self.tower.Faces():
            if face.geomType() != 'PLANE':
                continue
            nz = face.normalAt().z
            if nz < -limit:
                self.assertAlmostEqual(face.BoundingBox().zmax, bed, places=6,
                                       msg=f'unsupported ceiling at {face.Center()}')

    def test_7in_connector_notch_clears_every_plug(self):
        """A plug envelope per connector, from the receptacle out past the tower,
        4 mm either side of its centre height and widened by the plug margin:
        nothing of the tower may be in it."""
        glass = (enclosure.S7C_MOD_DEPTH + enclosure.S7C_GAP
                 - enclosure.SCREEN_COATED_SETBACK)     # glass front above the deck top
        ports = ((30.95, 45.95), (16.85, 24.75), (3.75, 11.65), (-7.75, 1.25))
        m = enclosure.S7T_PLUG_MARGIN
        plane = (cq.Workplane('XY').workplane(offset=enclosure.S7T_H0)
                 .transformed(rotate=(enclosure.SLOPE_ANGLE, 0, 0)))
        for py0, py1 in ports:
            plug = (plane.workplane(offset=glass - 3.0)
                    .center((enclosure.S7C_PORTS_X0 + 120.0) / 2.0, (py0 + py1) / 2.0)
                    .rect(120.0 - enclosure.S7C_PORTS_X0, py1 - py0 + 2 * m)
                    .extrude(-(glass - 3.0) - 1.0).val())
            self.assertLess(self.tower.intersect(plug).Volume(), 1e-6, (py0, py1))

    def test_7in_ring_board_clears_the_closed_deck(self):
        """The front notch is gone; the PR #990 ring board must still clear the
        deck by 2 mm. Each probed part's underside rises rearward at the slope."""
        ref = json.loads((Path(enclosure.HERE) / 'reference/ring_board_envelope.json').read_text())
        tx, ty, tz = ref['tower_translation_mm']
        tower = self.tower.translate((tx, ty, tz))
        gaps = []
        for body in ref['bodies']:
            (bx0, bx1), (by0, by1), (bz0, _) = body['x'], body['y'], body['z']
            rise = (by1 - by0) * math.tan(SLOPE)
            keep_out = (cq.Workplane('YZ').workplane(offset=bx0)
                        .polyline([(by0, bz0 - 2.0), (by1, bz0 + rise - 2.0),
                                   (by1, 200.0), (by0, 200.0)]).close()
                        .extrude(bx1 - bx0).val())
            self.assertLess(tower.intersect(keep_out).Volume(), 1e-6, body['part'])
            gaps.append(tower.distance(keep_out) + 2.0)
        self.assertGreater(min(gaps), 3.0)

    # --- 15.6in stand ------------------------------------------------------

    def test_15in6_halves_are_one_part_mirrored(self):
        left = self.parts['segno_screen16_stand_L']
        right = self.parts['segno_screen16_stand_R']
        mirrored = left.mirror('YZ', (enclosure.SCREEN_16_U, 0, 0))
        self.assertLess(mirrored.cut(right).Volume(), 1e-6)
        self.assertLess(right.cut(mirrored).Volume(), 1e-6)
        # ...and they meet exactly at the screen centre
        self.assertAlmostEqual(left.BoundingBox().xmax, enclosure.SCREEN_16_U, places=6)
        self.assertAlmostEqual(right.BoundingBox().xmin, enclosure.SCREEN_16_U, places=6)

    def test_15in6_splice_seats_under_both_halves(self):
        splice = self.parts['segno_screen16_splice']
        for side in ('L', 'R'):
            stand = self.parts['segno_screen16_stand_' + side]
            self.assertLess(splice.intersect(stand).Volume(), 1e-6)
            self.assertLess(splice.distance(stand), 1e-6)
        # four screws, two into each half's heat-set inserts
        holes = [f for f in splice.Faces() if f.geomType() == 'CYLINDER']
        xs = sorted(round(f.Center().x - enclosure.SCREEN_16_U, 3) for f in holes)
        self.assertEqual(xs, [-14.0, -14.0, 14.0, 14.0])

    def test_15in6_tower_walls_reach_the_deck(self):
        """v3 stopped the tube at the ribs' bottom edge, leaving a 15 mm slot in
        both end walls under the deck. Sample the outboard end wall of the left
        tower up to just under the deck."""
        stand = self.parts['segno_screen16_stand_L']
        x = 460.0 + enclosure.S16_WALL / 2.0
        c = math.cos(SLOPE)
        yc = enclosure.S16_DECK_V * c - 2.093
        drop = (enclosure.S16_BLOCK_D + enclosure.S16_GAP) / c
        z_deck = lambda y: (enclosure.LID_UNDER_Z0 - drop + math.tan(SLOPE) * y
                            - enclosure.S16_BEAM_T / c)
        for y in (yc - 30.0, yc, yc + 30.0):
            for z in range(12, int(z_deck(y)) - 1, 3):
                self.assertTrue(stand.isInside(cq.Vector(x, y, z)), (y, z))

    def test_15in6_monitor_screws_are_fixed_and_the_washer_bears_all_round(self):
        """#1070: no float at the monitor. The two VESA holes are M4 clearance,
        75 mm apart, and an M4 DIN 125 washer (O9) covers either one fully even
        with the screw pushed to the side of its clearance."""
        d = enclosure.S16_VESA_CLR_D
        self.assertLessEqual(d, 4.8 + 1e-9)
        self.assertGreater(9.0 / 2.0, d / 2.0 + (d - 4.0) / 2.0)
        holes = []
        for side in ('L', 'R'):
            stand = self.parts['segno_screen16_stand_' + side]
            for f in stand.Faces():
                if f.geomType() == 'CYLINDER':
                    cyl = BRepAdaptor_Surface(f.wrapped).Cylinder()
                    if abs(cyl.Radius() - d / 2.0) < 1e-6:
                        holes.append(round(cyl.Location().X(), 2))
        xs = sorted(set(holes))
        self.assertEqual(len(xs), 2, xs)
        self.assertAlmostEqual(xs[1] - xs[0], enclosure.S16_VESA, delta=0.05)

    # --- fit tests -----------------------------------------------------------

    def test_7in_deck_fit_test_has_the_towers_bosses_and_notch(self):
        """The jig is only useful if its bosses are the tower's: same diameter,
        height above the deck, insert pilot and screw clearance."""
        jig = self.parts['segno_screen7_deck_fit_test']
        self.assertTrue(jig.isValid())
        self.assertEqual(len(jig.Solids()), 1)
        dt = enclosure.S7T_DECK
        top = dt + (enclosure.S7C_MOD_DEPTH + enclosure.S7C_GAP
                    - enclosure.S7C_GLASS_TO_TABF - enclosure.S7C_TAB_T
                    - enclosure.SCREEN_COATED_SETBACK)
        self.assertAlmostEqual(jig.BoundingBox().zmax, top, places=6)
        for x, y in enclosure.S7C_HOLES:
            pilot = (cq.Workplane('XY').workplane(offset=top).center(x, y)
                     .circle(enclosure.S7T_INSERT_D / 2 - .01)
                     .extrude(-enclosure.S7T_INSERT_L + .01).val())
            clear = (cq.Workplane('XY').center(x, y)
                     .circle(enclosure.S7T_SCREW_CLR / 2 - .01).extrude(top).val())
            ring = (cq.Workplane('XY').workplane(offset=top - .1).center(x, y)
                    .circle(enclosure.S7T_BOSS_D / 2 - .01)
                    .circle(enclosure.S7T_INSERT_D / 2 + .01).extrude(.1).val())
            self.assertLess(jig.intersect(pilot).Volume(), 1e-7)
            self.assertLess(jig.intersect(clear).Volume(), 1e-7)
            self.assertLess(ring.cut(jig).Volume(), 1e-7)
        # the connector notch goes through the +x edge
        py = sum(enclosure.S7C_PORTS_Y) / 2.0
        self.assertFalse(jig.isInside(cq.Vector(88.0, py, dt / 2.0)))
        self.assertTrue(jig.isInside(cq.Vector(88.0, -40.0, dt / 2.0)))

    def test_15in6_vesa_fit_test_matches_the_stand(self):
        """Fixed M4 holes at the VESA pitch, and a lip that stands the block's
        proud height above the bosses: the same step the stand's tower pads make
        from its bosses."""
        bar = self.parts['segno_screen16_vesa_fit_test']
        self.assertTrue(bar.isValid())
        self.assertEqual(len(bar.Solids()), 1)
        xs = sorted(round(BRepAdaptor_Surface(f.wrapped).Cylinder().Location().X(), 3)
                    for f in bar.Faces() if f.geomType() == 'CYLINDER'
                    and abs(BRepAdaptor_Surface(f.wrapped).Cylinder().Radius()
                            - enclosure.S16_VESA_CLR_D / 2) < 1e-6)
        self.assertEqual(xs, [-enclosure.S16_VESA / 2, enclosure.S16_VESA / 2])
        boss = enclosure.S16_BEAM_T + enclosure.S16_GAP - enclosure.SCREEN_COATED_SETBACK
        lip = bar.BoundingBox().zmax
        self.assertAlmostEqual(lip - boss, enclosure.S16_BLOCK_PROUD, places=6)
        self.assertTrue(bar.isInside(cq.Vector(enclosure.S16_VESA / 2, 8.0, boss - .05)))
        self.assertFalse(bar.isInside(cq.Vector(enclosure.S16_VESA / 2, 8.0, boss + .05)))

    def to_deck_frame(self, shape):
        return (shape.translate((0, 0, -enclosure._s16_deck_frame_z0()))
                .rotate((0, 0, 0), (1, 0, 0), -enclosure.SLOPE_ANGLE)
                .translate((0, 0, enclosure.S16_BEAM_T)))

    def test_15in6_whole_fit_test_is_the_stands_own_top(self):
        """Each half is cut from the stand above its deck's underside, nothing
        added: the monitor meets exactly what it will meet on the real stands,
        both bosses and both tower pads, and the real splice seats under it."""
        t = enclosure.S16_BEAM_T
        pad = t + enclosure.S16_PAD_H - enclosure.SCREEN_COATED_SETBACK
        boss = t + enclosure.S16_GAP - enclosure.SCREEN_COATED_SETBACK
        splice = self.to_deck_frame(self.parts['segno_screen16_splice'])
        monitor = self.to_deck_frame(self.parts['segno_screen16_monitor'])
        for side in ('L', 'R'):
            jig = self.parts['segno_screen16_deck_fit_test_' + side]
            stand = self.to_deck_frame(self.parts['segno_screen16_stand_' + side])
            above = stand.intersect(cq.Solid.makeBox(
                2000, 2000, 100, cq.Vector(-1000, -1000, 0)))
            # a skeleton of the stand's top: nothing added, most of the slab
            # gone, every contact kept (below)
            self.assertLess(jig.cut(above).Volume(), 1e-3)
            self.assertLess(jig.Volume(), 0.5 * above.Volume())
            self.assertAlmostEqual(jig.BoundingBox().zmin, 0.0, places=6)
            self.assertAlmostEqual(jig.BoundingBox().zmax, pad, places=5)
            # the monitor rests on it: touching, never inside
            self.assertLess(jig.intersect(monitor).Volume(), 1e-6)
            self.assertLess(jig.distance(monitor), 1e-6)
            # ...on BOTH its boss (the block) and its pad (the flat back)
            for z in (boss, pad):
                tops = [f for f in jig.Faces() if f.geomType() == 'PLANE'
                        and f.normalAt().z > .99999 and abs(f.Center().z - z) < 1e-5]
                self.assertTrue(tops, (side, z))
                self.assertLess(min(f.distance(monitor) for f in tops), 1e-6, (side, z))
            self.assertLess(splice.intersect(jig).Volume(), 1e-6)
            self.assertLess(splice.distance(jig), 1e-6)
        self.assertGreater(pad, boss)

    # --- both: floor interface ---------------------------------------------

    def test_shim_kit_is_binary_and_nominal_matches_the_lift(self):
        kit = enclosure.STAND_SHIM_SET
        stacks = {round(sum(c), 3) for r in range(len(kit) + 1)
                  for c in itertools.combinations(kit, r)}
        self.assertEqual(stacks, {round(0.2 * i, 3) for i in range(16)})
        self.assertAlmostEqual(sum(enclosure.STAND_SHIM_NOMINAL), enclosure.STAND_SHIM_NOM)
        # the nominal stack leaves room to go down as well as up
        self.assertGreaterEqual(enclosure.STAND_SHIM_NOM, 0.8)
        self.assertGreaterEqual(sum(kit) - enclosure.STAND_SHIM_NOM, 1.6)

    def test_each_shim_is_its_flange_footprint(self):
        """Stacked at nominal, the shims fill the gap under the flange exactly:
        touching it, never overlapping it, and covering its whole underside."""
        for stem, part, z0 in (('segno_screen7_shim', self.tower, 0.0),
                               ('segno_screen16_shim', self.parts['segno_screen16_stand_L'],
                                enclosure.FLOOR_TOP)):
            flange_area = sum(f.Area() for f in part.Faces()
                              if f.geomType() == 'PLANE' and f.normalAt().z < -.99999
                              and abs(f.Center().z - z0 - enclosure.STAND_SHIM_NOM) < 1e-6)
            z = z0
            for t in enclosure.STAND_SHIM_NOMINAL:
                shim = self.parts[f"{stem}_{str(t).replace('.', 'p')}"].translate((0, 0, z - z0))
                self.assertAlmostEqual(shim.Volume() / t, flange_area, places=3)
                self.assertLess(shim.intersect(part).Volume(), 1e-6)
                z += t
            self.assertLess(shim.distance(part), 1e-6)
            for t in enclosure.STAND_SHIM_SET:
                self.assertIn(f"{stem}_{str(t).replace('.', 'p')}", self.parts)


if __name__ == '__main__':
    unittest.main()
