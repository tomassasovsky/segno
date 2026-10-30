import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/library/application/eds_setup.dart';
import 'package:segno/session/new_loop_template.dart';
import 'package:segno_engine/segno_engine.dart' show MockAudioEngine;

/// The app's bundle with one of Ed's setup's presets missing from it.
class _WithoutBoomDry extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) {
    if (key == 'AssetManifest.bin') {
      return rootBundle.load(key).then((data) async {
        final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
        final kept = [
          for (final asset in manifest.listAssets())
            if (!asset.contains('Boom Dry')) asset,
        ];
        return const StandardMessageCodec().encodeMessage({
          for (final asset in kept) asset: <Object>[],
        })!;
      });
    }
    return rootBundle.load(key);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group("Ed's setup (#1513)", () {
    test('names tracks 1 to 4 Guitar, Boom, RC20 and Vox, with the presets '
        'the plan maps to them', () {
      expect(edsSetup, [
        (channel: 0, name: 'Guitar', preset: 'Acoustic Rhythm 1'),
        (channel: 1, name: 'Boom', preset: 'Boom Dry'),
        (channel: 2, name: 'RC20', preset: 'Bass Octave 1'),
        (channel: 3, name: 'Vox', preset: 'Vocal Close'),
      ]);
    });

    test('builds one rack per track from the shipped presets, with only '
        'the pedals each turns on, Post and the chain on', () async {
      final template = await loadEdsSetup();

      expect(template, isNotNull);
      expect(template!.names, {0: 'Guitar', 1: 'Boom', 2: 'RC20', 3: 'Vox'});
      expect(template.trackChains.keys, [0, 1, 2, 3]);
      final modules = {
        for (final MapEntry(:key, :value) in template.trackChains.entries)
          key: [for (final e in value.entries) (e as BuiltInEffect).module],
      };
      expect(modules, {
        0: ['Compressor', 'Reverb', 'Four-band EQ'],
        1: ['Compressor', 'Four-band EQ'],
        2: ['Octaver', 'Compressor', 'Four-band EQ'],
        3: ['Compressor', 'Reverb', 'Four-band EQ'],
      });
      // RC20's sound is the octave: its rack leads with the dual octaver.
      final octaver = template.trackChains[2]!.entries.first as BuiltInEffect;
      expect(octaver.type, TrackEffectType.dualOctaver);
      expect(octaver.enabled, isTrue);
      for (final (i, track) in edsSetup.indexed) {
        final chain = template.trackChains[i]!;
        expect(chain.chainEnabled, isTrue);
        final rack = chain.entries.first.rack!;
        expect(rack.name, track.preset);
        expect(rack.art, 'edsguitar');
        for (final entry in chain.entries) {
          expect(entry.enabled, isTrue);
          expect(entry.placement, FxPlacement.post);
          expect(entry.rack, rack);
          expect(entry.slotId, isNotNull);
        }
      }
    });

    test('the four racks fit the 96 kHz effects budget together', () async {
      final template = (await loadEdsSetup())!;

      final cost = template.trackChains.values.fold(
        0,
        (sum, chain) => sum + fxChainCostNs(chain.entries),
      );

      expect(cost, lessThanOrEqualTo(fxBudgetNs(96000)));
    });

    test('fits a 96 kHz rig through the admission every edit uses, and a '
        'template four times as heavy does not', () async {
      final template = (await loadEdsSetup())!;
      final engine = MockAudioEngine();
      final looper = LooperRepository(engine: engine)
        ..startEngine(const EngineConfig(sampleRate: 96000));
      addTearDown(looper.dispose);

      expect(newLoopTemplateFits(looper, template), isTrue);
      // Each rack four times over: past the budget on the callback.
      final heavy = NewLoopTemplate(
        trackChains: {
          for (final MapEntry(:key, :value) in template.trackChains.entries)
            key: FxChainEnvelope(
              entries: [for (var i = 0; i < 4; i++) ...value.entries],
            ),
        },
        names: const {},
      );
      expect(
        heavy.trackChains.values.fold(
          0,
          (sum, chain) => sum + fxChainCostNs(chain.entries),
        ),
        greaterThan(fxBudgetNs(96000)),
      );
      expect(newLoopTemplateFits(looper, heavy), isFalse);
    });

    test('a missing preset gives no template', () async {
      expect(await loadEdsSetup(bundle: _WithoutBoomDry()), isNull);
    });
  });
}
