"""Reproduce the design catalogue from the user-supplied Looper X extraction.

Usage: python3 docs/design/import_looperx_factory.py EXTRACTED_DIRECTORY
Reads data and artwork only. Never runs supplied executables or scripts.
"""

import hashlib
import json
from pathlib import Path
import shutil
import sys


FAMILIES = {
    "Ed's Rack": "edsguitar", "Vocal Rack": "vocal", "Guitar Rack": "guitar",
    "Lo-Fi Rack": "lo-fi", "Drum Rack": "drum", "Dub Rack": "dub",
    "Studio Rack": "studio", "Rhythmic Rack": "rhythmic",
    "Vocal Tuner Rack": "vocaltuner",
}
EFFECTS = {
    'Amp': 'Amp4', 'Chorus': 'Chorus3', 'Compressor': 'Compressor2',
    'Degrade': 'Degrade3', 'Delay': 'Delay3', 'Distortion': 'Distort2',
    'Doubler': 'Doubler1', 'Dub Delay': 'Delay6', 'Four-band EQ': 'EQ4',
    'Harmonize': 'Harmonise20', 'HP / Gate': 'HPFGate2',
    'Low-pass Filter': 'LPF2', 'Modulation': 'Mod3', 'Octaver': 'Octaver3',
    'Overdrive': 'Overdrive2', 'Parametric EQ': 'EQ5',
    'Pitch Shift': 'PitchShift2', 'Pumper': 'Pumper2', 'Reverb': 'Reverb2',
    'Slicer': 'Slicer2', 'Smart Tune': 'SmartTune2',
    'Spring Reverb': 'SpringRev2', 'Transient': 'Transient3',
    'Vinyl': 'Vinyl4', 'Wah': 'Wah1', 'Whammy': 'Wham2',
}


def build(source: Path, output: Path):
    output.mkdir(parents=True, exist_ok=True)
    manifest = []

    def include(path, relative):
        destination = output / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, destination)
        original = path.read_bytes()
        assert original == destination.read_bytes()
        manifest.append({'source': path.relative_to(source).as_posix(),
                         'destination': relative,
                         'sha256': hashlib.sha256(original).hexdigest(),
                         'bytes': len(original)})

    images = source / 'AppUI/img/Effects'
    include(images / 'selector/singlefx.png', 'images/selector/singlefx.png')
    families = []
    for family, artwork in FAMILIES.items():
        for role in ('selector', 'footswitch', 'strip'):
            include(images / role / (artwork + '.png'), f'images/{role}/{artwork}.png')
        presets = []
        for path in sorted((source / 'FxPresets' / family).glob('*.fxpreset')):
            raw = json.loads(path.read_text())
            content = json.loads(raw['content'])
            include(path, f'presets/{family}/{path.name}')
            presets.append({'id': raw['id'], 'name': raw['name'], 'type': raw['type'],
                            'version': content['_version'], 'filename': path.name,
                            'parameters': {k: v for k, v in content.items() if k != '_version'},
                            'raw': raw, 'readiness': 'unverified'})
        families.append({'name': family, 'artwork': artwork, 'presets': presets,
                         'readiness': 'unverified'})
    for path in sorted((images / 'NewEditor/Stomps').glob('*.png')):
        include(path, f'images/stomps/{path.name}')
    catalogue = {'sourceVersion': '1.0.2', 'families': families,
                 'effects': [{'name': name, 'icon': icon + '.png', 'readiness': 'unverified'}
                             for name, icon in EFFECTS.items()],
                 'limitations': ['Effect labels interpret native image identifiers.',
                                 '26 native single-effect identifiers; additional images are artwork variants.',
                                 'Preset values are exact; physical control mappings and DSP parity are unverified.',
                                 'Module grouping in the design is proposed, not recovered DSP signal order.']}
    assert sum(len(f['presets']) for f in families) == 159
    assert len({p['id'] for f in families for p in f['presets']}) == 159
    (output / 'catalog.js').write_text('window.LOOPERX_FACTORY = ' + json.dumps(catalogue, ensure_ascii=False, separators=(',', ':')) + ';\n')
    (output / 'manifest.json').write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + '\n')
    print(json.dumps({'families': len(families), 'presets': 159, 'effect_identifiers': len(EFFECTS),
                      'artwork_files': sum(m['destination'].startswith('images/') for m in manifest),
                      'verified_original_files': len(manifest)}))


if __name__ == '__main__':
    build(Path(sys.argv[1]).resolve(), Path(__file__).resolve().parent / 'looperx-factory')
