import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/looper/cubit/fx_presets_cubit.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

/// One module of a live rack instance: it carries the three things a saved
/// DEFINITION must not.
BuiltInEffect _instance(
  String slot,
  TrackEffectType type, {
  String rackId = 'R1',
  FxPlacement placement = FxPlacement.pre,
  FxChannels channels = FxChannels.defaults,
}) => BuiltInEffect(
  type: type,
  slotId: slot,
  placement: placement,
  channels: channels,
  module: 'Delay',
  rack: FxRack(id: rackId, name: 'Funk Wah', art: 'guitar'),
);

void main() {
  late SettingsRepository settings;
  late FxPresetsCubit cubit;

  setUp(() {
    settings = SettingsRepository(store: FakeKeyValueStore());
    cubit = FxPresetsCubit(settings: settings);
    addTearDown(cubit.close);
  });

  test('starts empty and loads nothing when nothing was saved', () async {
    await cubit.load();

    expect(cubit.state, isEmpty);
  });

  test(
    'a saved preset is a DEFINITION: no rack, no slot ids, no placement',
    () async {
      // Those three are what make one instance distinct from the next. A saved
      // sound that carried them would recall as the same instance twice, and
      // would drag the destination it was saved on along with it.
      await cubit.save(
        name: 'Warm rhythmic guitar',
        entries: [
          _instance('a', TrackEffectType.delay),
          _instance('b', TrackEffectType.reverb),
        ],
      );

      final saved = cubit.state.single;
      expect(saved.entries, hasLength(2));
      expect(saved.entries.every((fx) => fx.rack == null), isTrue);
      expect(saved.entries.every((fx) => fx.slotId == null), isTrue);
      expect(
        saved.entries.every((fx) => fx.placement == FxPlacement.post),
        isTrue,
      );
    },
  );

  test(
    'it DOES keep the parameters, the channel settings and the pedal name',
    () async {
      await cubit.save(
        name: 'Verse',
        entries: [
          BuiltInEffect(
            type: TrackEffectType.delay,
            params: const [0.42, 0.35, 0.25, 0],
            enabled: false,
            module: 'Delay',
            channels: const FxChannels(
              input: FxChannelInput.monoSum,
              output: FxChannelOutput.mono,
              placement: -0.5,
              level: 0.8,
            ),
          ),
        ],
      );

      final fx = cubit.state.single.entries.single as BuiltInEffect;
      expect(fx.params[0], closeTo(0.42, 1e-9));
      expect(fx.channels.level, 0.8);
      expect(fx.enabled, isFalse);
      expect(fx.module, 'Delay');
    },
  );

  test('byName is case-insensitive, because two rows a player cannot tell '
      'apart are one name', () async {
    await cubit.save(
      name: 'Verse',
      entries: [_instance('a', TrackEffectType.delay)],
    );

    expect(fxPresetNamed(cubit.state, 'verse')?.name, 'Verse');
    expect(fxPresetNamed(cubit.state, '  VERSE '), isNotNull);
    expect(fxPresetNamed(cubit.state, 'Chorus'), isNull);
  });

  test(
    'replace keeps the identity and the name, and changes the entries',
    () async {
      await cubit.save(
        name: 'Verse',
        entries: [_instance('a', TrackEffectType.delay)],
      );
      final first = cubit.state.single;

      await cubit.replace(
        id: first.id,
        entries: [
          _instance('b', TrackEffectType.reverb),
          _instance('c', TrackEffectType.drive),
        ],
      );

      final saved = cubit.state.single;
      expect(saved.id, first.id);
      expect(saved.name, 'Verse');
      expect(saved.entries, hasLength(2));
    },
  );

  test('rename keeps the identity, and an empty name is refused', () async {
    await cubit.save(
      name: 'Verse',
      entries: [_instance('a', TrackEffectType.delay)],
    );
    final first = cubit.state.single;

    await cubit.rename(first.id, '  Chorus ');
    expect(cubit.state.single.name, 'Chorus');
    expect(cubit.state.single.id, first.id);

    await cubit.rename(first.id, '   ');
    expect(cubit.state.single.name, 'Chorus');
  });

  test('remove drops one and leaves the rest', () async {
    await cubit.save(
      name: 'A',
      entries: [_instance('a', TrackEffectType.delay)],
    );
    final a = cubit.state.single;
    await cubit.save(
      name: 'B',
      entries: [_instance('b', TrackEffectType.reverb)],
    );

    await cubit.remove(a.id);

    expect(cubit.state.map((p) => p.name), ['B']);
  });

  test('the saved list survives a restart', () async {
    await cubit.save(
      name: 'Warm rhythmic guitar',
      entries: [
        _instance('a', TrackEffectType.delay),
        _instance('b', TrackEffectType.reverb),
      ],
      art: 'guitar',
    );

    final reloaded = FxPresetsCubit(settings: settings);
    addTearDown(reloaded.close);
    await reloaded.load();

    final saved = reloaded.state.single;
    expect(saved.name, 'Warm rhythmic guitar');
    expect(saved.art, 'guitar');
    expect(saved.entries, hasLength(2));
    expect(saved.isRack, isTrue);
  });

  test(
    'a malformed entry is dropped without taking the good ones with it',
    () async {
      const good = r'{"id":"1","name":"Good","chain":"[{\"type\":1}]"}';
      const noId = '{"name":"No id"}';
      const emptyChain = '{"id":"3","name":"Empty chain","chain":"[]"}';
      await settings.saveFxUserPresets('[$good,$noId,$emptyChain]');

      await cubit.load();

      expect(cubit.state.map((p) => p.name), ['Good']);
    },
  );
}
