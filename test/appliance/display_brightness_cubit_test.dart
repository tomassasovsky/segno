import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:brightness_client/brightness_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/appliance/display_brightness_cubit.dart';
import 'package:segno/appliance/software_brightness.dart';
import 'package:settings_repository/settings_repository.dart';

import '../helpers/helpers.dart';

class _FakeBrightnessClient implements BrightnessClient {
  /// The connectors whose panel answers DDC/CI.
  Set<String> supported = {'HDMI-A-1', 'HDMI-A-2'};

  /// Every set, as `connector=percent`.
  final sets = <String>[];

  /// When set, every `set` waits for it.
  Completer<void>? gate;

  bool failSets = false;

  @override
  Future<bool> isSupported(String connector) async =>
      supported.contains(connector);

  @override
  Future<void> set(String connector, double value) async {
    sets.add('$connector=${(value * 100).round()}');
    await gate?.future;
    if (failSets) throw StateError('DDC/CI write failed');
  }
}

class _FakeOutputs implements DisplayOutputs {
  @override
  Future<Map<String, String>> appIdConnectors() async => const {
    'dev.aquiles.segno': 'HDMI-A-1',
    'dev.aquiles.segno.waveform': 'HDMI-A-2',
  };

  @override
  Future<bool?> isConnected(String connector) async => true;
}

void main() {
  late FakeKeyValueStore store;
  late SettingsRepository settings;
  late _FakeBrightnessClient client;

  setUp(() {
    store = FakeKeyValueStore();
    settings = SettingsRepository(store: store);
    client = _FakeBrightnessClient();
  });

  DisplayBrightnessCubit build() => DisplayBrightnessCubit(
    settings: settings,
    client: client,
    outputs: _FakeOutputs(),
  );

  group('DisplayBrightnessCubit', () {
    test('starts each panel at the default', () {
      final cubit = build();
      expect(cubit.state.levelOf(DisplayRole.track), kDefaultDisplayBrightness);
      expect(cubit.state.levelOf(DisplayRole.main), kDefaultDisplayBrightness);
      unawaited(cubit.close());
    });

    test('load carries an older single brightness to both panels', () async {
      await store.setDouble('ui.brightness', 0.6);
      final cubit = build();
      await cubit.load();
      expect(cubit.state.levelOf(DisplayRole.track), 0.6);
      expect(cubit.state.levelOf(DisplayRole.main), 0.6);
      await cubit.close();
    });

    test('load clamps an older brightness below the range to 20%', () async {
      await store.setDouble('ui.brightness', 0.1);
      final cubit = build();
      await cubit.load();
      expect(cubit.state.levelOf(DisplayRole.track), 0.2);
      expect(cubit.state.levelOf(DisplayRole.main), 0.2);
      await cubit.close();
    });

    test('load probes each panel on its own connector and sets the ones '
        'that answer', () async {
      client.supported = {'HDMI-A-1'};
      await settings.saveDisplayBrightness(DisplayRole.main, 0.55);
      final cubit = build();
      await cubit.load();
      expect(cubit.state.hardware, {DisplayRole.main});
      expect(client.sets, ['HDMI-A-1=55']);
      // The panel that dims itself gets no filter; the other one does.
      expect(cubit.state.softwareOf(DisplayRole.main), 1);
      expect(cubit.state.softwareOf(DisplayRole.track), 0.8);
      await cubit.close();
    });

    test('setting main to 0.5 calls the client with HDMI-A-1 only and '
        'leaves track unchanged', () async {
      final cubit = build();
      await cubit.load();
      client.sets.clear();

      await cubit.setBrightness(DisplayRole.main, 0.5);

      expect(client.sets, ['HDMI-A-1=50']);
      expect(cubit.state.levelOf(DisplayRole.main), 0.5);
      expect(cubit.state.levelOf(DisplayRole.track), 0.8);
      expect(await settings.loadDisplayBrightness(DisplayRole.main), 0.5);
      expect(await store.getDouble('ui.brightness.track'), isNull);
      await cubit.close();
    });

    test('a set below the range lands on its floor', () async {
      final cubit = build();
      await cubit.setBrightness(DisplayRole.track, 0);
      expect(cubit.state.levelOf(DisplayRole.track), kMinDisplayBrightness);
      expect(
        await settings.loadDisplayBrightness(DisplayRole.track),
        kMinDisplayBrightness,
      );
      await cubit.close();
    });

    test('a drag sends one helper call at a time and ends on the last '
        'value', () async {
      final cubit = build();
      await cubit.load();
      client.sets.clear();
      client.gate = Completer<void>();

      final first = cubit.setBrightness(DisplayRole.main, 0.5);
      unawaited(cubit.setBrightness(DisplayRole.main, 0.6));
      unawaited(cubit.setBrightness(DisplayRole.main, 0.7));
      await pumpEventQueue();
      expect(client.sets, ['HDMI-A-1=50']);

      client.gate!.complete();
      await first;
      await pumpEventQueue();
      expect(client.sets, ['HDMI-A-1=50', 'HDMI-A-1=70']);
      await cubit.close();
    });

    test(
      'a panel that stops answering falls back to the software dim',
      () async {
        final cubit = build();
        await cubit.load();
        client.failSets = true;

        await cubit.setBrightness(DisplayRole.track, 0.4);

        expect(cubit.state.hardware, {DisplayRole.main});
        expect(cubit.state.softwareOf(DisplayRole.track), 0.4);
        await cubit.close();
      },
    );

    test('the idle dim is 30% of each setting with a 10% floor, and wakes '
        'back to the setting', () async {
      client.supported = {'HDMI-A-1'};
      await settings.saveDisplayBrightness(DisplayRole.main, 1);
      await settings.saveDisplayBrightness(DisplayRole.track, 0.2);
      final cubit = build();
      await cubit.load();
      client.sets.clear();

      cubit.setDimmed(dimmed: true);
      await pumpEventQueue();
      expect(cubit.state.shownOf(DisplayRole.main), closeTo(0.3, 1e-9));
      expect(cubit.state.shownOf(DisplayRole.track), kMinShownBrightness);
      expect(cubit.state.softwareOf(DisplayRole.track), kMinShownBrightness);
      expect(client.sets, ['HDMI-A-1=30']);
      // Dimming changes what is shown, never what is set.
      expect(await settings.loadDisplayBrightness(DisplayRole.main), 1);

      cubit.setDimmed(dimmed: false);
      await pumpEventQueue();
      expect(cubit.state.shownOf(DisplayRole.main), 1);
      expect(client.sets, ['HDMI-A-1=30', 'HDMI-A-1=100']);
      await cubit.close();
    });

    blocTest<DisplayBrightnessCubit, DisplayBrightnessState>(
      'a save that fails still shows the new level, and says so',
      build: () => DisplayBrightnessCubit(
        settings: SettingsRepository(store: _RefusingStore()),
      ),
      act: (cubit) => cubit.setBrightness(DisplayRole.main, 0.5),
      errors: () => [isA<StateError>()],
      expect: () => [
        isA<DisplayBrightnessState>().having(
          (s) => s.levelOf(DisplayRole.main),
          'main',
          0.5,
        ),
      ],
    );
  });
}

class _RefusingStore extends FakeKeyValueStore {
  @override
  Future<void> setDouble(String key, double value) async =>
      throw StateError('storage unavailable');
}
