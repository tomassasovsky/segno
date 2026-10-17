import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:instrument_repository/instrument_repository.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/instruments/application/instrument_settings.dart';
import 'package:segno/looper/model/owned_setting.dart';
import 'package:segno_engine/segno_engine.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/fake_audio_engine.dart';
import '../../helpers/fake_key_value_store.dart';

void main() {
  const key = 'instruments.working_copy';
  const pad = 6;
  const lead = 5;

  late FakeKeyValueStore store;
  late FakeAudioEngine looperEngine;
  late LooperRepository looper;
  late MockAudioEngine engine;
  late StreamController<EngineSnapshot> snapshots;
  late InstrumentRepository instruments;
  late InstrumentSettings settings;
  late int minted;

  InstrumentSettings build() => InstrumentSettings(
    looper: looper,
    instruments: instruments,
    settings: SettingsRepository(store: store),
    mintId: () => 'id${minted++}',
  );

  Future<void> tick() async {
    snapshots.add(engine.snapshot());
    await Future<void>.delayed(Duration.zero);
  }

  InstrumentsWorkingCopy stored() => InstrumentsWorkingCopy.fromJson(
    jsonDecode(store.values[key]! as String) as Map<String, dynamic>,
  );

  setUp(() async {
    minted = 0;
    store = FakeKeyValueStore();
    looperEngine = FakeAudioEngine();
    looper = LooperRepository(
      engine: looperEngine,
      ticker: const Stream.empty(),
    );
    engine = MockAudioEngine()..start(MockAudioEngine().defaultConfig);
    snapshots = StreamController<EngineSnapshot>();
    instruments = InstrumentRepository(
      engine: engine,
      snapshots: snapshots.stream,
    );
    settings = build();
    await settings.load();
    await tick();
  });

  tearDown(() async {
    await settings.close();
    await instruments.dispose();
    await snapshots.close();
    await looper.dispose();
  });

  test('an empty store loads no instruments and writes nothing', () {
    expect(settings.confirmed, const InstrumentsWorkingCopy());
    expect(store.values, isEmpty);
    expect(settings.owner.key, OwnedSetting.instruments);
  });

  test('add stores the instrument and plays it, controllers off', () async {
    final result = await settings.add(soundId: 'pad', name: 'Pad');
    expect(result.outcome!.isOk, isTrue);
    final added = stored().byId('id0')!;
    expect(added.slot, 0);
    expect(added.params, [42, 60, 72]);
    expect(added.midi.enabled, isFalse);
    expect(added.keys.enabled, isFalse);
    expect(engine.snapshot().instruments.patches[0], pad);
    expect(
      (await settings.add(soundId: 'theremin', name: 'X')).outcome!.status,
      SettingStatus.rejected,
    );
  });

  test(
    'a ninth instrument is refused with the reason, nothing written',
    () async {
      for (var n = 0; n < 8; n++) {
        await settings.add(soundId: 'keys', name: 'K$n');
      }
      final before = store.values[key];
      final result = await settings.add(soundId: 'pad', name: 'Nine');
      expect(result.refusal, AddRefusal.full);
      expect(result.outcome, isNull);
      expect(store.values[key], before);
    },
  );

  test(
    'Listen then Apply stores the sound; Cancel sends the saved one back',
    () async {
      await settings.add(soundId: 'pad', name: 'Pad');
      instruments.listen('id0', 'lead');
      expect(engine.snapshot().instruments.patches[0], lead);
      expect(stored().byId('id0')!.soundId, 'pad');
      instruments.cancelAudition('id0');
      expect(engine.snapshot().instruments.patches[0], pad);

      instruments.listen('id0', 'lead');
      await settings.chooseSound('id0', 'lead');
      expect(stored().byId('id0')!.soundId, 'lead');
      expect(stored().byId('id0')!.params, [72, 2, 25]);
      expect(instruments.state.auditions, isEmpty);
      expect(
        (await settings.chooseSound('id0', 'kazoo')).status,
        SettingStatus.rejected,
      );
    },
  );

  test('a parameter draft is audible but stored only when committed', () async {
    await settings.add(soundId: 'pad', name: 'Pad');
    final before = store.values[key];
    instruments.setParamDraft('id0', 1, 5);
    expect(engine.simulatedParams(0), [42, 5, 72]);
    expect(store.values[key], before);
    await settings.commitParams('id0');
    expect(stored().byId('id0')!.params, [42, 5, 72]);
    expect(instruments.state.drafts, isEmpty);
    expect((await settings.commitParams('id0')).isOk, isTrue);
  });

  test('rename, MIDI input and computer keys are stored', () async {
    await settings.add(soundId: 'pad', name: 'Pad');
    await settings.rename('id0', 'Strings');
    await settings.setMidiInput(
      'id0',
      const MidiNoteInput(enabled: true, deviceId: 'kb', channel: 2),
    );
    await settings.setComputerKeys('id0', const ComputerKeys(enabled: true));
    final saved = stored().byId('id0')!;
    expect(saved.name, 'Strings');
    expect(saved.midi.channel, 2);
    expect(saved.keys.enabled, isTrue);
    expect((await settings.rename('nobody', 'X')).isOk, isTrue);
    expect(stored().instruments, hasLength(1));
  });

  test('a restart loads the stored definitions into the engine', () async {
    await settings.add(soundId: 'pad', name: 'Pad');
    await settings.close();
    engine
      ..stop()
      ..start(engine.defaultConfig); // a fresh synth
    settings = build();
    await settings.load();
    await tick();
    expect(settings.confirmed.byId('id0')!.name, 'Pad');
    expect(engine.snapshot().instruments.patches[0], pad);
  });

  test('a stored sound this build lacks loads as unavailable', () async {
    await settings.close();
    store.values[key] = jsonEncode(
      const InstrumentsWorkingCopy(
        instruments: [
          Instrument(
            id: 'old',
            slot: 2,
            name: 'Theremin',
            soundId: 'theremin',
            params: [1, 2, 3],
            midi: MidiNoteInput(enabled: true, deviceId: 'kb'),
          ),
        ],
      ).toJson(),
    );
    settings = build();
    await settings.load();
    await tick();
    expect(settings.owner.ready, isTrue);
    expect(instruments.state.unavailable, {'old'});
    expect(engine.snapshot().instruments.patches[2], -1);
    expect(settings.confirmed.byId('old')!.midi.enabled, isTrue);
  });

  test('an unreadable record asks for recovery instead of loading', () async {
    await settings.close();
    store.values[key] = '{"version": 99}';
    settings = build();
    await settings.load();
    expect(settings.owner.ready, isFalse);
  });

  group('remove', () {
    EngineSnapshot routed({
      required int input,
      TrackState state = TrackState.playing,
      int length = 4,
    }) => looperEngine.nextSnapshot.copyWith(
      tracks: [
        TrackSnapshot(
          state: state,
          volume: 1,
          muted: false,
          lengthFrames: length,
          undoDepth: 0,
          rms: 0,
          peak: 0,
          lanes: [
            LaneSnapshot(
              inputChannel: input,
              outputMask: 3,
              volume: 1,
              muted: false,
              lengthFrames: length,
              rms: 0,
              peak: 0,
            ),
          ],
        ),
        for (var t = 1; t < 8; t++) const TrackSnapshot.empty(),
      ],
    );

    test('is refused while a track captures from the instrument', () async {
      await settings.add(soundId: 'pad', name: 'Pad');
      looperEngine.nextSnapshot = routed(
        input: 32,
        state: TrackState.recording,
      );
      final result = await settings.remove('id0');
      expect(result.refusal, RemoveRefusal.capturing);
      expect(stored().byId('id0'), isNotNull);
      expect(
        (await settings.remove('nobody')).refusal,
        RemoveRefusal.unknown,
      );
    });

    test('keeps a tombstone while recorded material names it', () async {
      await settings.add(soundId: 'pad', name: 'Pad');
      looperEngine.nextSnapshot = routed(input: 32);
      final result = await settings.remove('id0');
      expect(result.outcome!.isOk, isTrue);
      expect(stored().instruments, isEmpty);
      expect(stored().tombstones, const [Tombstone(slot: 0, name: 'Pad')]);
      expect(engine.snapshot().instruments.patches[0], -1);
    });

    test('leaves no tombstone when nothing was recorded from it', () async {
      await settings.add(soundId: 'pad', name: 'Pad');
      looperEngine.nextSnapshot = routed(input: 0); // another source
      await settings.remove('id0');
      expect(stored().tombstones, isEmpty);
    });
  });
}
