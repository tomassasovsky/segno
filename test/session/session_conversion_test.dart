import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/control/binding/pedal_binding_set.dart';
import 'package:segno/session/session_mapping.dart';
import 'package:segno_engine/segno_engine.dart'
    show MockAudioEngine, PumpedNativeEngine;
import 'package:session_repository/session_repository.dart';

/// Real bundles written by every schema's own save path (#1196), opened and
/// applied through the app's own mapping onto a real `LooperRepository`.
const _fixtures = 'packages/session_repository/test/fixtures/sessions';

void main() {
  late MockAudioEngine engine;
  late LooperRepository looper;
  late Directory tempDir;

  setUp(() {
    engine = MockAudioEngine();
    looper = LooperRepository(engine: engine)
      ..startEngine(
        const EngineConfig(
          sampleRate: 48000,
          inputChannels: 2,
          outputChannels: 2,
        ),
      );
    tempDir = Directory.systemTemp.createTempSync('segno_conversion');
  });

  tearDown(() async {
    await looper.dispose();
    tempDir.deleteSync(recursive: true);
  });

  String copyFixture(String name) {
    final to = Directory('${tempDir.path}/$name')..createSync();
    for (final file in Directory('$_fixtures/$name').listSync()) {
      (file as File).copySync('${to.path}/${file.uri.pathSegments.last}');
    }
    return to.path;
  }

  List<TrackEffectType?> typesOf(Iterable<TrackEffect> effects) => [
    for (final effect in effects)
      if (effect is BuiltInEffect) effect.type else null,
  ];

  test('a schema-7 bundle from master maps with its chains, monitors and '
      'bindings', () async {
    final opened = await SessionRepository(
      engine: engine,
    ).open(copyFixture('v7_master_full'));
    final rig = rigFromBundle(opened.bundle);

    expect(MixSettingsSnapshot.fromRig(rig).isValid, isTrue);
    expect(
      typesOf(decodeFxChain(opened.bundle.session.allTracksChain).entries),
      [
        TrackEffectType.filter,
      ],
    );
    expect(typesOf(rig.laneChains[(0, 0)]!.entries), [
      TrackEffectType.delay,
      TrackEffectType.reverb,
    ]);
    expect(rig.laneChains[(0, 1)]!.chainEnabled, isFalse);
    expect(typesOf(rig.trackChains[1]!.entries), [TrackEffectType.tremolo]);
    expect(rig.monitors.map((m) => m.mode), [
      MonitorMode.auto,
      MonitorMode.on,
    ]);
    expect(typesOf(rig.monitors.first.effects), [TrackEffectType.echo]);

    // Both bindings survive; the one on the retired Master stage stays in
    // the set, unresolved, for the assignment screen to offer rebind.
    final bindings = PedalBindingSet.decode(
      opened.bundle.session.pedalBindings,
    );
    expect(bindings.length, 2);
    expect(
      bindings.bindings.map((b) => b.decodeTarget()?.address.stage),
      [FxStage.loop, null],
    );
  });

  for (final name in const [
    'v7_master_empty',
    'v8_slices_be987759d',
    'v8_trunk_a0a54e57e',
    'v9_slices_95dcea0d8',
    'v9_trunk_623a5a7ba',
    'v10_trunk_a921bd9a9',
    'v11_trunk_5c163d11f',
  ]) {
    test('$name maps to a valid rig', () async {
      final opened = await SessionRepository(
        engine: engine,
      ).open(copyFixture(name));
      final rig = rigFromBundle(opened.bundle);
      expect(MixSettingsSnapshot.fromRig(rig).isValid, isTrue);
      expect(
        opened.conversion?.fromVersion,
        name.startsWith('v11') ? isNull : isNotNull,
      );
    });
  }

  group('on the native engine', () {
    final lib = Platform.environment['SEGNO_ENGINE_LIB'];
    final skip = lib == null || lib.isEmpty
        ? 'SEGNO_ENGINE_LIB not set — run '
              'packages/segno_engine/tool/build_test_lib.sh'
        : null;
    late PumpedNativeEngine native;
    late LooperRepository nativeLooper;
    Timer? pumpDriver;

    setUp(() async {
      if (skip != null) return;
      native = PumpedNativeEngine();
      nativeLooper = LooperRepository(engine: native)
        ..startEngine(
          const EngineConfig(
            sampleRate: 48000,
            inputChannels: 2,
            outputChannels: 2,
            maxLoopFrames: 48000,
          ),
        );
      native.pump(frames: 0);
      expect(await nativeLooper.settleMixSettings(), EngineResult.ok);
      pumpDriver = Timer.periodic(
        const Duration(milliseconds: 1),
        (_) => native.pump(frames: 0),
      );
    });

    tearDown(() async {
      if (skip != null) return;
      pumpDriver?.cancel();
      await nativeLooper.dispose();
    });

    test('a converted schema-7 bundle applies with its audio, history, '
        'chains and monitors', () async {
      final opened = await SessionRepository(
        engine: native,
      ).open(copyFixture('v7_master_full'));

      await nativeLooper.applySession(
        rigFromBundle(opened.bundle),
        clearPollInterval: const Duration(milliseconds: 1),
      );

      final tracks = native.snapshot().tracks;
      expect(tracks[0].undoDepth, 2);
      expect((tracks[2].undoDepth, tracks[2].redoDepth), (2, 1));
      expect(tracks[1].lengthFrames, 4800);
      expect(tracks.take(3).map((t) => t.fade.amount), [1, 1, 1]);
      expect(typesOf(nativeLooper.allTracksChainEnvelope().entries), [
        TrackEffectType.filter,
      ]);
      expect(typesOf(nativeLooper.laneEffects(0, 0)), [
        TrackEffectType.delay,
        TrackEffectType.reverb,
      ]);
      expect(nativeLooper.monitorMode(0), MonitorMode.auto);
    }, skip: skip);
  });
}
