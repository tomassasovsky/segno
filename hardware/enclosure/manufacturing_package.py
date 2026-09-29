"""The four-part metal order and atomic publication of generated vendor files.

Drawing/native geometry checks belong to the generator and run before this
module. Here, membership, freshness and complete ZIP writes protect the handoff.
Canonical source filenames stay unchanged; shipping names carry drawing metadata.
"""
from collections.abc import Mapping
import os
from pathlib import Path
import re
import tempfile
import unicodedata
import zipfile


METAL_ARCHIVE = 'segno_sheetmetal.zip'
OBSOLETE_METAL_ARCHIVES = (
    'segno_sheetmetal_step.zip',
    'segno_sheetmetal_STEP_DXF.zip',
    'segno_sheetmetal_parts_only.zip',
)
_PART_THICKNESSES = {
    'segno_base': 2.0,
    'segno_faceplate': 2.0,
    'segno_ring_disc': 2.0,
    'segno_beam': 1.6,
}


def metal_package_members(part_specs):
    """Return all 12 shipping-name -> canonical-filename pairs for one set.

    ``part_specs`` is the generator's existing material/quantity/vendor table.
    A changed part set or thickness requires an intentional package revision.
    """
    metal = {stem: row for stem, row in part_specs.items()
             if row[2] == 'sheetmetal'}
    if set(metal) != set(_PART_THICKNESSES):
        raise ValueError('metal order must contain only base, faceplate, ring disc '
                         'and steel beam')
    members = {}
    for stem, thickness in _PART_THICKNESSES.items():
        material, quantity, _ = metal[stem]
        if type(quantity) is not int or quantity != 1:
            raise ValueError(f'{stem}: the reviewed order requires quantity 1')
        expected_material = 'acero' if stem == 'segno_beam' else 'aluminio'
        if not isinstance(material, str) or expected_material not in material.lower():
            raise ValueError(f'{stem}: material caption must identify {expected_material}')
        gauges = re.findall(r'(\d+(?:[.,]\d+)?)\s*mm\b', material)
        if len(gauges) != 1 or float(gauges[0].replace(',', '.')) != thickness:
            raise ValueError(f'{stem}: material caption must specify {thickness:.1f} mm')
        material = re.sub(r'(?<=\d),(?=\d)', '.', material)
        ascii_material = unicodedata.normalize('NFKD', material).encode(
            'ascii', 'ignore').decode('ascii')
        label = re.sub(r'[^A-Za-z0-9.]+', '-', ascii_material).strip('-')
        for extension in ('.step', '.dxf', '.pdf'):
            member = f'{stem}__{label}__qty{quantity}{extension}'
            members[member] = stem+extension
    return members


def _filename(name):
    if (not isinstance(name, str) or not name or name in ('.', '..')
            or '/' in name or '\\' in name or '\x00' in name):
        raise ValueError(f'package entries must be plain filenames: {name!r}')
    return name


def _verify_archive(path, members, output_dir):
    with zipfile.ZipFile(path) as archive:
        if archive.namelist() != list(members):
            raise AssertionError(f'{path.name}: archive members differ from the reviewed order')
        for member, source in members.items():
            if archive.read(member) != (output_dir/source).read_bytes():
                raise AssertionError(f'{path.name}: archived content differs for {member}')


def _validate_metal_members(members):
    expected = {stem+extension for stem in _PART_THICKNESSES
                for extension in ('.step', '.dxf', '.pdf')}
    if set(members.values()) != expected:
        raise ValueError(f'metal archive requires exactly the {len(expected)} reviewed part artifacts')
    for member, source in members.items():
        stem, extension = os.path.splitext(source)
        material = 'acero' if stem == 'segno_beam' else 'aluminio'
        if (not member.startswith(stem+'__'+material)
                or not member.endswith('__qty1'+extension)
                or f'de-{_PART_THICKNESSES[stem]:.1f}-mm' not in member):
            raise ValueError(f'{member}: metal shipping name lacks matching part metadata')


def write_archives(output_dir, packages, *, run_started):
    """Stage the complete package set before atomically replacing each ZIP.

    ``packages`` maps ZIP names to {shipping filename: source filename} maps.
    A partial generation omits METAL_ARCHIVE and leaves the metal order intact.
    Missing, empty, stale or unsuccessfully compressed files never replace it.
    """
    output_dir = Path(output_dir)
    for archive, members in packages.items():
        _filename(archive)
        if not archive.endswith('.zip') or not isinstance(members, Mapping) or not members:
            raise ValueError(f'{archive}: expected a nonempty ZIP member mapping')
        if len(members.values()) != len(set(members.values())):
            raise ValueError(f'{archive}: the same source is ordered more than once')
        if archive == METAL_ARCHIVE:
            _validate_metal_members(members)
        for member, source in members.items():
            _filename(member)
            path = output_dir/_filename(source)
            if not path.is_file():
                raise AssertionError(f'{archive}: missing required {source}')
            stat = path.stat()
            if stat.st_size == 0:
                raise AssertionError(f'{archive}: empty required {source}')
            if stat.st_mtime < run_started:
                raise AssertionError(f'{source} is STALE -- not regenerated by this run')
    if not packages:
        return []
    with tempfile.TemporaryDirectory(dir=output_dir, prefix='.quote-pack-') as staging:
        staging = Path(staging)
        for archive, members in packages.items():
            staged = staging/archive
            with zipfile.ZipFile(staged, 'w', zipfile.ZIP_DEFLATED) as zipped:
                for member, source in members.items():
                    zipped.write(output_dir/source, member)
            _verify_archive(staged, members, output_dir)
        for archive in packages:
            os.replace(staging/archive, output_dir/archive)
    if METAL_ARCHIVE in packages:
        for old in OBSOLETE_METAL_ARCHIVES:
            (output_dir/old).unlink(missing_ok=True)
    return [str(output_dir/archive) for archive in packages]


def verify_manufacturing_archive(output_dir, part_specs):
    """Check the on-disk reviewed metal order, including each file's contents."""
    output_dir = Path(output_dir)
    _verify_archive(output_dir/METAL_ARCHIVE,
                    metal_package_members(part_specs), output_dir)
