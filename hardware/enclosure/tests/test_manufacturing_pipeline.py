"""Laser-path validity and fail-closed supplier package regressions."""
from copy import deepcopy
from contextlib import redirect_stdout
import hashlib
import io
import json
from pathlib import Path
from types import SimpleNamespace
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import ezdxf
from ezdxf.math import Matrix44

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import segno_enclosure as enclosure
from flat_pattern_check import compare_flat_pattern, validate_cut_contours
from fusion_export_formed import _sketch_curves, _validate_sketch_curves


class ManufacturingPipelineTest(unittest.TestCase):
    def test_all_generated_metal_paths_are_clean_and_match_native_base(self):
        with tempfile.TemporaryDirectory() as tmp:
            for stem, writer in enclosure.DXF_PARTS:
                if enclosure.PART_SPECS[stem][2] != enclosure.PKG_SHEETMETAL:
                    continue
                with self.subTest(stem=stem):
                    path = Path(tmp)/(stem+'.dxf')
                    writer(str(path))
                    validate_cut_contours(path)
            result = compare_flat_pattern(
                Path(tmp)/'segno_base.dxf',
                Path(enclosure.HERE)/'formed/segno_base_flat.dxf')
            self.assertEqual(result['missing_area_mm2'], 0)
            self.assertEqual(result['extra_area_mm2'], 0)

    @staticmethod
    def _drawing():
        doc = ezdxf.new(); doc.units = 4
        doc.modelspace().add_lwpolyline(
            [(0,0),(120,0),(120,70),(0,70)], close=True,
            dxfattribs={'layer':'CUT'})
        for x,y,r in ((12,13,2),(40,28,3),(90,49,4)):
            doc.modelspace().add_circle((x,y),r,dxfattribs={'layer':'CUT'})
        return doc

    def test_rejects_redundant_crossing_open_and_self_intersecting_paths(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)/'part.dxf'
            for fault in ('duplicate', 'nested', 'crossing', 'outside', 'touching',
                          'open', 'self-intersection', 'units'):
                with self.subTest(fault=fault):
                    doc = self._drawing(); msp = doc.modelspace()
                    if fault == 'duplicate':
                        msp.add_entity(next(iter(msp.query('CIRCLE'))).copy())
                    elif fault == 'nested':
                        msp.add_circle((12,13),1,dxfattribs={'layer':'VENT'})
                    elif fault == 'crossing':
                        msp.add_circle((0,0),3.25,dxfattribs={'layer':'CUT'})
                    elif fault == 'outside':
                        msp.add_circle((200,100),3,dxfattribs={'layer':'CUT'})
                    elif fault == 'touching':
                        msp.add_circle((16,13),2,dxfattribs={'layer':'CUT'})
                    elif fault == 'open':
                        next(iter(msp.query('LWPOLYLINE'))).closed = False
                    elif fault == 'self-intersection':
                        next(iter(msp.query('LWPOLYLINE'))).set_points(
                            [(0,0),(120,70),(120,0),(0,70)])
                    else:
                        doc.units = 1
                    doc.saveas(path)
                    with self.assertRaises(AssertionError):
                        validate_cut_contours(path)
            # Process references may cross or duplicate laser paths; they do
            # not become cutting operations merely by appearing in the DXF.
            doc = self._drawing()
            doc.modelspace().add_circle((0,0),3.25,dxfattribs={'layer':'DRILL'})
            doc.modelspace().add_line((0,0),(120,70),dxfattribs={'layer':'BEND'})
            doc.saveas(path)
            validate_cut_contours(path)

    def test_opposite_face_requires_an_explicit_verified_view(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp)/'source.dxf'; native = Path(tmp)/'native.dxf'
            doc = self._drawing(); doc.saveas(source)
            for entity in doc.modelspace():
                entity.dxf.layer = ('OUTER_PROFILES' if entity.dxftype() == 'LWPOLYLINE'
                                    else 'INTERIOR_PROFILES')
                entity.transform(Matrix44.scale(-1,1,1))
            doc.saveas(native)
            with self.assertRaises(AssertionError):
                compare_flat_pattern(source,native)
            result = compare_flat_pattern(source,native,opposite_face=True)
            self.assertEqual(result['missing_area_mm2'],0)
            self.assertEqual(result['extra_area_mm2'],0)

    def test_lid_process_reclassification_preserves_every_hole(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(enclosure,'OUT',tmp):
            enclosure.dxf_faceplate(str(Path(tmp)/'segno_faceplate.dxf'))
            expected = enclosure._flat_primitives('segno_faceplate')
        actual = deepcopy(expected)
        hole = next(curve for curve in actual['DRILL'] if curve[0] == 'C')
        actual['DRILL'].remove(hole)
        actual['CUT'].append(hole)
        _validate_sketch_curves('segno_faceplate',expected,actual)
        hole[1][0] += 1
        with self.assertRaisesRegex(AssertionError,'sketch differs'):
            _validate_sketch_curves('segno_faceplate',expected,actual)

    def test_native_profile_history_is_ignored_only_when_it_is_cut_construction(self):
        def line(start, end, construction):
            point = lambda xy: SimpleNamespace(geometry=SimpleNamespace(x=xy[0],y=xy[1]))
            return SimpleNamespace(startSketchPoint=point(start),endSketchPoint=point(end),
                                   isConstruction=construction)
        class Curves(list):
            @property
            def sketchLines(self): return self
            sketchCircles = ()
            sketchArcs = ()
        active = line((0,0),(1,0),False)
        old_profile = line((1,0),(2,0),True)
        bend = line((0,0),(0,1),True)
        layers = {'CUT':SimpleNamespace(sketchCurves=Curves([active,old_profile])),
                  'BEND':SimpleNamespace(sketchCurves=Curves([bend]))}
        component = SimpleNamespace(name='corner_bracket',
                                    sketches=SimpleNamespace(itemByName=layers.get))
        expected = {'CUT':[['L',[[0.0,0.0],[10.0,0.0]]]],
                    'BEND':[['L',[[0.0,0.0],[0.0,10.0]]]]}
        actual = _sketch_curves(component,expected)
        _validate_sketch_curves('segno_corner_bracket_rear',expected,actual)
        # The same old edge left as real CUT geometry is still a mismatch.
        old_profile.isConstruction = False
        with self.assertRaisesRegex(AssertionError,'CUT sketch differs'):
            _validate_sketch_curves('segno_corner_bracket_rear',expected,
                                    _sketch_curves(component,expected))

    def test_handed_bracket_split_does_not_leave_the_old_painting_quantity(self):
        # Keeping the old x2 painter row after adding the left-hand x1 part
        # would quote and request three brackets instead of the two made parts.
        rows = [(row[0],row[1],2,*row[3:])
                if row[0] == 'segno_corner_bracket_rear' else row
                for row in enclosure.PAINT_BOM]
        with patch.object(enclosure,'PAINT_BOM',rows):
            with self.assertRaisesRegex(AssertionError,'painting quantity differs'):
                enclosure._verify_paint_bom()

    def test_small_drill_residue_does_not_translate_the_whole_sheet(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp)/'source.dxf'; native = Path(tmp)/'native.dxf'
            doc = self._drawing()
            next(iter(doc.modelspace().query('LWPOLYLINE'))).set_points(
                [(0,0),(1200,0),(1200,70),(0,70)])
            doc.modelspace().add_circle((110,20),1.5,dxfattribs={'layer':'CUT'})
            doc.saveas(source)
            for entity in doc.modelspace():
                entity.dxf.layer = ('OUTER_PROFILES' if entity.dxftype() == 'LWPOLYLINE'
                                    else 'INTERIOR_PROFILES')
            next(iter(doc.modelspace().query('CIRCLE'))).dxf.center += (0,.000273,0)
            doc.saveas(native)
            result = compare_flat_pattern(source,native)
            self.assertEqual(result['matched_reference_holes'],3)
            self.assertLessEqual(result['missing_area_mm2'],.01)
            self.assertLessEqual(result['extra_area_mm2'],.01)

    @staticmethod
    def _previous_archives(out):
        archives = {name:b'previous complete package' for name in (
            'segno_sheetmetal.zip','segno_sheetmetal_step.zip',
            'segno_pintura.zip','segno_3dprint.zip')}
        for name,data in archives.items():
            (out/name).write_bytes(data)
        return archives

    @staticmethod
    def _generated_drawings(out):
        for stem,writer in enclosure.DXF_PARTS:
            writer(str(out/(stem+'.dxf')))
        with patch.object(enclosure,'OUT',str(out)):
            enclosure.build_pedal_tile_vectors(with_pdf=False)

    def test_partial_generation_preserves_previous_metal_and_paint_archives(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(enclosure,'OUT',tmp):
            out = Path(tmp); archives = self._previous_archives(out)
            self._generated_drawings(out)
            produced = enclosure.build_quote_packages(with_step=False,with_pdf=False)
            self.assertTrue(all(Path(path).name not in archives for path in produced))
            for name,data in archives.items():
                self.assertEqual((out/name).read_bytes(),data)

    def test_export_plan_retires_overlay_and_keeps_purchased_hardware_out_of_part_orders(self):
        # Exercise the real vector writers and package selection. Native/PDF
        # acceptance has its own failure tests; no artifacts are published here.
        with tempfile.TemporaryDirectory() as tmp, patch.object(enclosure,'OUT',tmp):
            out = Path(tmp)
            self._generated_drawings(out)
            self.assertFalse(list(out.glob('*overlay*')))
            lid = ezdxf.readfile(out/'segno_faceplate.dxf')
            self.assertFalse(any(e.dxf.layer == 'SILK' for e in lid.modelspace()))
            for label in ('REC/PLAY','STOP'):
                tile = ezdxf.readfile(out/(enclosure._tile_stem(label)+'.dxf'))
                self.assertTrue(any(e.dxf.layer == 'ENGRAVE' and e.dxftype() == 'HATCH'
                                    for e in tile.modelspace()))
            # This checks source drawing notes, including their file stems and
            # orientation/accent clauses, without generating a PDF.
            enclosure._verify_drawing_package(with_pdf=False,check_archives=False)
            with (patch.object(enclosure,'_verify_drawing_package'),
                  patch.object(enclosure,'_formed_record'),
                  patch.object(enclosure,'_write_quote_archives',side_effect=lambda p:p)):
                packages = enclosure.build_quote_packages(with_step=True,with_pdf=True)
            self.assertEqual({name:len(members) for name,members in packages.items()}, {
                'segno_sheetmetal.zip':14, 'segno_sheetmetal_step.zip':8,
                'segno_pintura.zip':8, 'segno_pedal_tiles.zip':22,
                'segno_3dprint.zip':38,
            })
            for part in ('segno_platform_sled', 'segno_platform_mid_sled'):
                for extension in ('.step', '.stl'):
                    self.assertIn(part+extension, packages['segno_3dprint.zip'])
            members = [name for names in packages.values() for name in names]
            self.assertFalse(any('overlay' in name for name in members))
            self.assertIn('segno_assembly.step',packages['segno_sheetmetal_step.zip'])
            for reference in ('segno_front_shim_pack_reference.step',
                              'segno_lid_washer_reference.step'):
                self.assertNotIn(reference,members)

    def test_failed_native_gate_does_not_publish_new_metal_archive(self):
        source = Path(enclosure.HERE)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); out = root/'out'; out.mkdir()
            shutil.copytree(source/'formed',root/'formed')
            archives = self._previous_archives(out)
            self._generated_drawings(out)
            path = out/'segno_base.dxf'; doc = ezdxf.readfile(path)
            hole = next(e for e in doc.modelspace().query('CIRCLE')
                        if e.dxf.layer == 'CUT' and 50 < e.dxf.center.x < 800
                        and 20 < e.dxf.center.y < 380)
            hole.dxf.center += (1,0,0); doc.saveas(path)
            with patch.object(enclosure,'HERE',str(root)), patch.object(enclosure,'OUT',str(out)):
                with self.assertRaisesRegex(AssertionError,'stale'):
                    enclosure.build_quote_packages(with_step=True,with_pdf=False)
            for name,data in archives.items():
                self.assertEqual((out/name).read_bytes(),data)

    def test_retraced_slit_on_flat_part_blocks_package_publication(self):
        # A source-outline editing error can add an inward out-and-back slit.
        # OCC heals it away when making a face, although CAM sees both segments.
        with tempfile.TemporaryDirectory() as tmp, patch.object(enclosure,'OUT',tmp):
            out = Path(tmp); archives = self._previous_archives(out)
            self._generated_drawings(out)
            path = out/'segno_post.dxf'; doc = ezdxf.readfile(path)
            outer = next(e for e in doc.modelspace().query('LWPOLYLINE')
                         if e.dxf.layer == 'CUT')
            points = list(outer.get_points('xyb'))
            a,b = points[:2]
            x,y = (a[0]+b[0])/2,(a[1]+b[1])/2
            points[1:1] = [(x,y,0),(x,y+5,0),(x,y,0)]
            outer.set_points(points,format='xyb'); doc.saveas(path)
            with self.assertRaisesRegex(AssertionError,'retraced or healed'):
                enclosure.build_quote_packages(with_step=True,with_pdf=False)
            for name,data in archives.items():
                self.assertEqual((out/name).read_bytes(),data)

    def test_lid_and_bracket_gate_checks_final_native_material(self):
        source = Path(enclosure.HERE)
        for stem in ('segno_faceplate','segno_corner_bracket_rear',
                     'segno_corner_bracket_rear_mirrored'):
            with self.subTest(stem=stem), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp); out = root/'out'; out.mkdir()
                shutil.copytree(source/'formed',root/'formed')
                shutil.copyfile(source/'out'/(stem+'.dxf'),out/(stem+'.dxf'))
                with patch.object(enclosure,'HERE',str(root)), patch.object(enclosure,'OUT',str(out)):
                    enclosure._formed_record(stem)
                    flat = root/'formed'/(stem+'_flat.dxf')
                    doc = ezdxf.readfile(flat)
                    hole = min((e for e in doc.modelspace().query('CIRCLE')
                                if e.dxf.layer == 'INTERIOR_PROFILES'),
                               key=lambda e:e.dxf.radius)
                    hole.dxf.center += (1,0,0); doc.saveas(flat)
                    with self.assertRaisesRegex(AssertionError,'flat pattern differs'):
                        enclosure._formed_record(stem)
                    manifest = root/'formed/manifest.json'
                    data = json.loads(manifest.read_text())
                    data[stem]['flat_pattern_sha256'] = hashlib.sha256(flat.read_bytes()).hexdigest()
                    manifest.write_text(json.dumps(data))
                    with self.assertRaisesRegex(AssertionError,'flat-pattern mismatch'):
                        enclosure._formed_record(stem)

    def test_paint_writer_failure_propagates_without_publishing_archives(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); out = root/'out'; out.mkdir()
            archives = self._previous_archives(out)
            def fail_paint(path):
                Path(path).write_bytes(b'%PDF incomplete')
                raise RuntimeError('forced paint PDF failure')
            with (patch.object(enclosure,'HERE',str(root)),
                  patch.object(enclosure,'OUT',str(out)),
                  patch.object(enclosure,'dxf_to_pdf'),
                  patch.object(enclosure,'build_pedal_tile_vectors',return_value=[]),
                  patch.object(enclosure,'paint_quote_pdf',side_effect=fail_paint),
                  redirect_stdout(io.StringIO())):
                with self.assertRaisesRegex(RuntimeError,'forced paint PDF failure'):
                    enclosure.main({'--no-step'})
            for name,data in archives.items():
                self.assertEqual((out/name).read_bytes(),data)

    def test_invalid_on_disk_paint_pdf_blocks_all_archive_publication(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(enclosure,'OUT',tmp):
            out = Path(tmp); archives = self._previous_archives(out)
            (out/'segno_paint_quote.pdf').write_bytes(b'%PDF incomplete')
            with patch.object(enclosure,'PAINT_PAGES',{'segno_paint_quote':4}):
                with self.assertRaisesRegex(AssertionError,'holds 0 pages on disk'):
                    enclosure.build_quote_packages(with_step=True,with_pdf=True)
            for name,data in archives.items():
                self.assertEqual((out/name).read_bytes(),data)

    def test_archive_set_survives_missing_members_and_failed_zip_writes(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(enclosure,'OUT',tmp):
            out = Path(tmp); archives = self._previous_archives(out)
            packages = {'segno_sheetmetal.zip':['part.dxf'],
                        'segno_pintura.zip':['paint.pdf']}
            (out/'part.dxf').write_bytes(b'current drawing')
            with self.assertRaisesRegex(AssertionError,'missing required paint.pdf'):
                enclosure._write_quote_archives(packages)
            for name,data in archives.items():
                self.assertEqual((out/name).read_bytes(),data)
            (out/'paint.pdf').write_bytes(b'current painter reference')
            original_write = zipfile.ZipFile.write
            def fail_write(archive,path,arcname):
                if arcname == 'paint.pdf':
                    raise OSError('forced ZIP write failure')
                return original_write(archive,path,arcname)
            with patch.object(zipfile.ZipFile,'write',fail_write):
                with self.assertRaisesRegex(OSError,'forced ZIP write failure'):
                    enclosure._write_quote_archives(packages)
            for name,data in archives.items():
                self.assertEqual((out/name).read_bytes(),data)
            self.assertFalse(list(out.glob('.quote-pack-*')))
            enclosure._write_quote_archives(packages)
            for name,members in packages.items():
                with zipfile.ZipFile(out/name) as archive:
                    self.assertEqual(archive.namelist(),members)
                    for member in members:
                        self.assertEqual(archive.read(member),(out/member).read_bytes())


if __name__ == '__main__':
    unittest.main()
