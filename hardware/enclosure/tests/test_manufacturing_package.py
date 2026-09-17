"""Exact metal ordering and preservation of complete archives on failure."""
from pathlib import Path
import os
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import manufacturing_package as package


class ManufacturingPackageTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='segno-package-test-')
        self.addCleanup(self.directory.cleanup)
        self.out = Path(self.directory.name)
        self.specs = {
            stem: ('aluminio 1100-H14 de 2.0 mm', 1, 'sheetmetal')
            for stem in ('segno_base', 'segno_faceplate', 'segno_ring_disc')
        }
        self.specs['segno_rear_panel'] = (
            'aluminio de 1.2 mm (aleación y temple por confirmar)', 1, 'sheetmetal')
        self.specs['segno_beam'] = ('acero laminado en frío de 1.6 mm', 1, 'sheetmetal')
        self.specs['segno_pedal_tiles'] = ('plástico de 2.0 mm', 10, 'tiles')
        self.members = package.metal_package_members(self.specs)
        for source in self.members.values():
            (self.out/source).write_bytes(('current artifact: '+source).encode())
        self.previous = {name: ('previous '+name).encode() for name in (
            package.METAL_ARCHIVE, *package.OBSOLETE_METAL_ARCHIVES,
            'segno_3dprint.zip', 'segno_pintura.zip')}
        for name, content in self.previous.items():
            (self.out/name).write_bytes(content)

    def write(self):
        return package.write_archives(
            self.out, {package.METAL_ARCHIVE: self.members}, run_started=0)

    def assert_previous_preserved(self):
        for name, content in self.previous.items():
            self.assertEqual((self.out/name).read_bytes(), content)
        self.assertFalse(list(self.out.glob('.quote-pack-*')))

    def test_order_contains_exactly_five_parts_with_three_formats_and_metadata(self):
        # Unrelated files beside the order must never be swept into its ZIP.
        for name in ('README.md', 'SHOP_REVIEW.md', 'segno_assembly.step',
                     'segno_platform_sled.step', 'segno_lid_washer_reference.step',
                     'segno_front_lid_washer_reference.step',
                     'segno_rear_lid_washer_reference.step',
                     'segno_corner_bracket_rear.dxf', 'segno_post.pdf'):
            (self.out/name).write_bytes(b'not part of the metal order')
        produced = self.write()
        self.assertEqual(produced, [str(self.out/package.METAL_ARCHIVE)])
        with zipfile.ZipFile(produced[0]) as archive:
            self.assertEqual(len(archive.namelist()), 15)
            self.assertEqual(set(archive.namelist()), set(self.members))
            self.assertTrue(all('__qty1.' in name for name in archive.namelist()))
            self.assertEqual({Path(name).suffix for name in archive.namelist()},
                             {'.step', '.dxf', '.pdf'})
            for name in archive.namelist():
                if name.startswith('segno_rear_panel__'):
                    self.assertIn('aluminio-de-1.2-mm', name)
                    self.assertIn('por-confirmar', name)
                elif name.startswith('segno_beam__'):
                    self.assertIn('acero-laminado-en-frio-de-1.6-mm', name)
                else:
                    self.assertIn('aluminio-1100-H14-de-2.0-mm', name)
                self.assertEqual(archive.read(name),
                                 (self.out/self.members[name]).read_bytes())
        package.verify_manufacturing_archive(self.out, self.specs)
        self.assertTrue(all(not (self.out/name).exists()
                            for name in package.OBSOLETE_METAL_ARCHIVES))
        for name in ('segno_3dprint.zip', 'segno_pintura.zip'):
            self.assertEqual((self.out/name).read_bytes(), self.previous[name])

    def test_each_missing_artifact_preserves_every_previous_archive(self):
        for source in self.members.values():
            with self.subTest(source=source):
                path = self.out/source
                content = path.read_bytes()
                path.unlink()
                with self.assertRaisesRegex(AssertionError, 'missing required'):
                    self.write()
                self.assert_previous_preserved()
                path.write_bytes(content)

    def test_empty_or_stale_artifact_cannot_replace_the_order(self):
        path = self.out/'segno_base.step'
        path.write_bytes(b'')
        with self.assertRaisesRegex(AssertionError, 'empty required'):
            self.write()
        self.assert_previous_preserved()
        path.write_bytes(b'stale base')
        os.utime(path, (1, 1))
        with self.assertRaisesRegex(AssertionError, 'STALE'):
            package.write_archives(self.out,
                {package.METAL_ARCHIVE: self.members}, run_started=2)
        self.assert_previous_preserved()

    def test_a_failed_zip_write_preserves_the_previous_complete_set(self):
        original = zipfile.ZipFile.write

        def fail_on_panel(archive, path, arcname):
            if arcname.startswith('segno_rear_panel__'):
                raise OSError('forced compression failure')
            return original(archive, path, arcname)

        with patch.object(zipfile.ZipFile, 'write', fail_on_panel):
            with self.assertRaisesRegex(OSError, 'forced compression failure'):
                self.write()
        self.assert_previous_preserved()

    def test_missing_other_vendor_file_blocks_the_whole_publication(self):
        with self.assertRaisesRegex(AssertionError, 'missing required paint.pdf'):
            package.write_archives(self.out, {
                package.METAL_ARCHIVE: self.members,
                'segno_pintura.zip': {'paint.pdf': 'paint.pdf'},
            }, run_started=0)
        self.assert_previous_preserved()

    def test_partial_generation_preserves_the_metal_order_and_obsolete_archives(self):
        (self.out/'tile.dxf').write_bytes(b'new tile')
        package.write_archives(self.out,
            {'segno_pedal_tiles.zip': {'tile.dxf': 'tile.dxf'}}, run_started=0)
        self.assert_previous_preserved()

    def test_changed_parts_quantities_or_materials_require_a_reviewed_manifest(self):
        for fault in ('missing', 'bracket', 'quantity', 'thickness', 'material'):
            with self.subTest(fault=fault):
                specs = self.specs.copy()
                if fault == 'missing':
                    del specs['segno_beam']
                elif fault == 'bracket':
                    specs['segno_corner_bracket_rear'] = specs['segno_base']
                elif fault == 'quantity':
                    specs['segno_beam'] = (specs['segno_beam'][0], 2, 'sheetmetal')
                elif fault == 'thickness':
                    specs['segno_rear_panel'] = ('aluminio de 2.0 mm', 1, 'sheetmetal')
                else:
                    specs['segno_beam'] = ('aluminio de 1.6 mm', 1, 'sheetmetal')
                with self.assertRaises(ValueError):
                    package.metal_package_members(specs)

    def test_decimal_comma_in_the_caption_remains_unambiguous_in_filenames(self):
        self.specs['segno_rear_panel'] = ('aluminio de 1,2 mm', 1, 'sheetmetal')
        names = package.metal_package_members(self.specs)
        panel = [name for name in names if name.startswith('segno_rear_panel__')]
        self.assertEqual(len(panel), 3)
        self.assertTrue(all('de-1.2-mm' in name for name in panel))

    def test_writer_cannot_publish_an_expanded_or_mislabeled_metal_manifest(self):
        (self.out/'README.md').write_bytes(b'unwanted note')
        invalid = self.members | {'README.md': 'README.md'}
        with self.assertRaisesRegex(ValueError, '15 reviewed'):
            package.write_archives(self.out,
                {package.METAL_ARCHIVE: invalid}, run_started=0)
        self.assert_previous_preserved()
        invalid = {member.replace('de-1.2-mm', 'de-2.0-mm'): source
                   for member, source in self.members.items()}
        with self.assertRaisesRegex(ValueError, 'metadata'):
            package.write_archives(self.out,
                {package.METAL_ARCHIVE: invalid}, run_started=0)
        self.assert_previous_preserved()

    def test_post_write_verification_rejects_extra_members_and_changed_contents(self):
        self.write()
        with zipfile.ZipFile(self.out/package.METAL_ARCHIVE, 'a') as archive:
            archive.writestr('segno_assembly.step', b'unwanted reference')
        with self.assertRaisesRegex(AssertionError, 'members differ'):
            package.verify_manufacturing_archive(self.out, self.specs)
        self.write()
        (self.out/'segno_faceplate.step').write_bytes(b'changed after archive creation')
        with self.assertRaisesRegex(AssertionError, 'content differs'):
            package.verify_manufacturing_archive(self.out, self.specs)


if __name__ == '__main__':
    unittest.main()
