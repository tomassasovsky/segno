import 'package:controller_repository/controller_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:instrument_repository/instrument_repository.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:midi_device_repository/midi_device_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:operation_guards/operation_guards.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:pedal_repository/testing.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:segno/app/application/app_runtime.dart';
import 'package:segno/looper/model/owned_setting.dart';
import 'package:segno_engine/segno_engine.dart' show MockAudioEngine;
import 'package:session_repository/session_repository.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

class _Sessions extends Mock implements SessionRepository {}

/// The instruments family joins the runtime's owners when the app has an
/// instrument repository, and loads and closes with them (#1197).
void main() {
  Future<(AppRuntime, Future<void> Function())> build({
    required bool instruments,
  }) async {
    final looper = LooperRepository(
      engine: FakeAudioEngine(),
      ticker: const Stream<void>.empty(),
    )..startEngine(const EngineConfig());
    final store = FakeKeyValueStore();
    final settings = SettingsRepository(store: store);
    final controllers = ControllerRepository(sources: const []);
    final midi = MidiDeviceRepository(source: null, settings: settings);
    final pedal = PedalRepository(FakePedalLink());
    final engine = MockAudioEngine()..start(MockAudioEngine().defaultConfig);
    final repository = instruments
        ? InstrumentRepository(engine: engine, snapshots: const Stream.empty())
        : null;
    final guards = GuardRegistry();
    final performance = PerformanceRepository(
      guards: guards,
      engine: FakeAudioEngine(),
      exportsRoot: () async => '.',
    );
    final runtime = AppRuntime(
      guards: guards,
      repository: looper,
      settings: settings,
      mix: testMixSettings(looper, settings: settings),
      controllers: controllers,
      midiDevices: midi,
      pedal: pedal,
      performance: performance,
      sessions: _Sessions(),
      powerOff: () async {},
      reboot: () async {},
      storageSettled: () async {},
      instruments: repository,
    );
    return (
      runtime,
      () async {
        await runtime.close();
        await repository?.dispose();
        performance.dispose();
        await pedal.dispose();
        await midi.dispose();
        await controllers.dispose();
        await looper.dispose();
      },
    );
  }

  test(
    'with an instrument repository the family is owned and loaded',
    () async {
      final (runtime, dispose) = await build(instruments: true);
      addTearDown(dispose);
      expect(
        runtime.owners.all.map((o) => o.key),
        contains(OwnedSetting.instruments),
      );
      await runtime.start();
      expect(runtime.instruments!.owner.ready, isTrue);
      expect(runtime.instruments!.confirmed, const InstrumentsWorkingCopy());
    },
  );

  test('without one the runtime has no instruments', () async {
    final (runtime, dispose) = await build(instruments: false);
    addTearDown(dispose);
    expect(runtime.instruments, isNull);
    expect(
      runtime.owners.all.map((o) => o.key),
      isNot(contains(OwnedSetting.instruments)),
    );
  });
}
