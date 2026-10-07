import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:instrument_repository/instrument_repository.dart';
import 'package:segno_engine/segno_engine.dart';

/// A mock engine that refuses the next few patch changes and route tables,
/// as a full event ring and an unacknowledged table do.
class _RefusingEngine extends MockAudioEngine {
  int refusePatches = 0;
  int refuseRoutes = 0;

  @override
  EngineResult setInstrument({
    required int slot,
    required int? patch,
    List<double>? params,
  }) {
    if (refusePatches > 0) {
      refusePatches--;
      return EngineResult.capacity;
    }
    return super.setInstrument(slot: slot, patch: patch, params: params);
  }

  @override
  EngineResult setInstrumentRoutes(List<InstrumentRoute> routes) {
    if (refuseRoutes > 0) {
      refuseRoutes--;
      return EngineResult.notReady;
    }
    return super.setInstrumentRoutes(routes);
  }
}

void main() {
  const pad = 6;
  const keys = 1;
  const lead = 5;

  late _RefusingEngine engine;
  late StreamController<EngineSnapshot> snapshots;
  late InstrumentRepository repository;

  void tick() => snapshots.add(engine.snapshot());

  Future<void> pump() async {
    tick();
    await Future<void>.delayed(Duration.zero);
  }

  const two = InstrumentsWorkingCopy(
    instruments: [
      Instrument(
        id: 'a',
        slot: 0,
        name: 'Pad',
        soundId: 'pad',
        params: [42, 60, 72],
        midi: MidiNoteInput(enabled: true, deviceId: 'kb', channel: 1),
      ),
      Instrument(
        id: 'b',
        slot: 3,
        name: 'Keys',
        soundId: 'keys',
        params: [10, 20, 30],
      ),
    ],
  );

  setUp(() async {
    engine = _RefusingEngine();
    snapshots = StreamController<EngineSnapshot>();
    repository = InstrumentRepository(
      engine: engine,
      snapshots: snapshots.stream,
    );
    engine.start(engine.defaultConfig);
  });

  tearDown(() async {
    await repository.dispose();
    await snapshots.close();
  });

  List<int> patches() => engine.snapshot().instruments.patches;

  test('sends nothing before the engine is configured', () async {
    final fresh = MockAudioEngine();
    final stream = StreamController<EngineSnapshot>();
    final repo = InstrumentRepository(engine: fresh, snapshots: stream.stream)
      ..apply(two);
    stream.add(fresh.snapshot());
    await Future<void>.delayed(Duration.zero);
    expect(fresh.instrumentCalls, ['synthCatalogue']);
    await repo.dispose();
    await stream.close();
  });

  test('the first epoch sends every slot, parameter and the table', () async {
    repository
      ..setPorts(const {'kb': 2})
      ..apply(two);
    expect(patches(), everyElement(-1)); // no epoch seen yet
    await pump();
    expect(patches(), [pad, -1, -1, keys, -1, -1, -1, -1]);
    expect(engine.simulatedParams(0), [42, 60, 72]);
    expect(engine.simulatedParams(3), [10, 20, 30]);
    expect(
      engine.simulatedRoutes[0],
      const InstrumentRoute(
        midiEnabled: true,
        port: 2,
        channel: 1,
      ),
    );
    // A snapshot that changes nothing sends nothing.
    final calls = engine.instrumentCalls.length;
    await pump();
    expect(engine.instrumentCalls, hasLength(calls));
  });

  test(
    'a reset epoch replays every slot and the table, and ends previews',
    () async {
      repository
        ..setPorts(const {'kb': 2})
        ..apply(two);
      await pump();
      repository
        ..listen('a', 'lead')
        ..setParamDraft('b', 0, 99);
      expect(patches()[0], lead);
      engine
        ..stop()
        ..start(engine.defaultConfig); // configure: a new synth epoch
      expect(patches(), everyElement(-1));
      await pump();
      expect(patches(), [pad, -1, -1, keys, -1, -1, -1, -1]);
      expect(engine.simulatedParams(3), [10, 20, 30]);
      expect(engine.simulatedRoutes[0].midiEnabled, isTrue);
      expect(repository.state.auditions, isEmpty);
      expect(repository.state.drafts, isEmpty);
    },
  );

  test(
    'a sound this build lacks loads as unavailable and keeps the rest',
    () async {
      final rolledBack = two.replace(
        two.byId('a')!.copyWith(soundId: 'theremin'),
      );
      repository
        ..setPorts(const {'kb': 2})
        ..apply(rolledBack);
      await pump();
      expect(repository.state.unavailable, {'a'});
      expect(patches()[0], -1);
      expect(repository.workingCopy.byId('a')!.midi.enabled, isTrue);
      expect(engine.simulatedRoutes[0].midiEnabled, isTrue);
      expect(repository.listen('a', 'theremin'), EngineResult.invalid);
    },
  );

  test('Listen previews a sound, Cancel sends the saved one back', () async {
    repository.apply(two);
    await pump();
    expect(repository.listen('a', 'lead'), EngineResult.ok);
    expect(patches()[0], lead);
    expect(engine.simulatedParams(0), [72, 2, 25]); // the lead's defaults
    expect(repository.state.auditions, {'a': 'lead'});
    expect(repository.workingCopy, two);
    repository.cancelAudition('a');
    expect(patches()[0], pad);
    expect(engine.simulatedParams(0), [42, 60, 72]);
    expect(repository.listen('zz', 'lead'), EngineResult.invalid);
  });

  test(
    'writing the auditioned sound commits it and ends the audition',
    () async {
      repository.apply(two);
      await pump();
      repository.listen('a', 'lead');
      final chosen = two.replace(
        two.byId('a')!.copyWith(soundId: 'lead', params: [72, 2, 25]),
      );
      expect(repository.apply(chosen), EngineResult.ok);
      expect(repository.state.auditions, isEmpty);
      expect(patches()[0], lead);
    },
  );

  test('a parameter draft is audible but not written', () async {
    repository.apply(two);
    await pump();
    expect(repository.setParamDraft('a', 1, 5), EngineResult.ok);
    expect(engine.simulatedParams(0), [42, 5, 72]);
    expect(repository.workingCopy.byId('a')!.params, [42, 60, 72]);
    // An unrelated write keeps the draft.
    repository.apply(two.replace(two.byId('b')!.copyWith(name: 'Ivories')));
    expect(repository.state.drafts['a'], [42, 5, 72]);
    expect(engine.simulatedParams(0), [42, 5, 72]);
    repository.discardDraft('a');
    expect(engine.simulatedParams(0), [42, 60, 72]);
    expect(repository.setParamDraft('a', 3, 5), EngineResult.invalid);
    expect(repository.setParamDraft('a', 0, 101), EngineResult.invalid);
    expect(repository.setParamDraft('zz', 0, 1), EngineResult.invalid);
  });

  test('a refused patch change is retried until accepted', () async {
    engine.refusePatches = 3;
    repository.apply(two);
    await pump(); // slots 0..2 refused
    expect(patches()[0], -1);
    await pump();
    expect(patches(), [pad, -1, -1, keys, -1, -1, -1, -1]);
  });

  test(
    'a table the engine has not taken yet is retried, latest wins',
    () async {
      repository.apply(two);
      await pump();
      engine.refuseRoutes = 2;
      repository.setPorts(const {'kb': 1}); // refused
      final moved = two.replace(
        two
            .byId('a')!
            .copyWith(
              midi: const MidiNoteInput(
                enabled: true,
                deviceId: 'kb',
                channel: 5,
              ),
            ),
      );
      repository.apply(moved); // refused
      expect(engine.simulatedRoutes[0].midiEnabled, isFalse);
      await pump();
      expect(
        engine.simulatedRoutes[0],
        const InstrumentRoute(midiEnabled: true, port: 1, channel: 5),
      );
    },
  );

  test('removing an instrument empties its slot', () async {
    repository.apply(two);
    await pump();
    repository.apply(two.remove('b', keepLabel: true));
    expect(patches()[3], -1);
  });

  test('refuses parameters out of range and changes nothing', () async {
    final bad = two.replace(two.byId('a')!.copyWith(params: [1, 2, 300]));
    expect(repository.apply(bad), EngineResult.invalid);
    expect(repository.workingCopy, const InstrumentsWorkingCopy());
  });

  test('projects voices and route problems by instrument', () async {
    final states = <InstrumentsState>[];
    repository.states.listen(states.add);
    final reversed = two
        .byId('a')!
        .copyWith(
          midi: const MidiNoteInput(
            enabled: true,
            deviceId: 'kb',
            low: 90,
            high: 10,
          ),
        );
    repository
      ..apply(two.replace(reversed))
      ..setPorts(const {'kb': 0});
    await pump();
    engine.instrumentNoteOn(slot: 3, origin: 1, note: 60, velocity: 90);
    await pump();
    expect(repository.state.voices, {'a': 0, 'b': 1});
    expect(repository.state.problems, const [
      RouteProblem('a', RouteProblemKind.invalid),
    ]);
    expect(states.last, repository.state);
  });

  group('the voice limit and overload', () {
    void late(int periods) => engine.nextCallbackTelemetry = CallbackTelemetry(
      session: CallbackWindowStats(latePeriods: periods),
    );

    test('every epoch sends the default limit', () async {
      final stream = StreamController<EngineSnapshot>();
      final custom = InstrumentRepository(
        engine: engine,
        snapshots: stream.stream,
        defaultVoiceLimit: 24,
      );
      expect(custom.state.voiceLimit, 24);
      Future<void> tickCustom() async {
        stream.add(engine.snapshot());
        await Future<void>.delayed(Duration.zero);
      }

      await tickCustom();
      expect(engine.snapshot().instruments.voiceLimit, 24);
      engine
        ..stop()
        ..start(engine.defaultConfig); // the engine is back at 32
      await tickCustom();
      expect(engine.snapshot().instruments.voiceLimit, 24);
      await custom.dispose();
      await stream.close();
    });

    test('late periods while nothing sounds are not counted', () async {
      repository.apply(two);
      await pump();
      engine.instrumentNoteOn(slot: 0, origin: 1, note: 60, velocity: 90);
      await pump(); // the baseline, 0 late
      engine.instrumentRelease(1);
      await pump(); // silent
      late(4);
      await pump(); // still silent: no reduction
      engine.instrumentNoteOn(slot: 0, origin: 2, note: 60, velocity: 90);
      await pump(); // a fresh baseline at 4
      expect(repository.state.voiceLimit, 32);
    });

    test(
      'a late period while sounding lowers the limit by a quarter',
      () async {
        final reductions = <int>[];
        repository.polyphonyReductions.listen(reductions.add);
        repository.apply(two);
        await pump();
        late(5); // late periods while nothing sounds do not count
        await pump();
        engine.instrumentNoteOn(slot: 0, origin: 1, note: 60, velocity: 90);
        await pump(); // the baseline
        expect(repository.state.voiceLimit, 32);
        late(6);
        await pump();
        expect(repository.state.voiceLimit, 24);
        expect(repository.state.voiceLimitReduced, isTrue);
        expect(engine.snapshot().instruments.voiceLimit, 24);
        for (var n = 7; n < 14; n++) {
          late(n);
          await pump();
        }
        expect(reductions, [24, 18, 13, 9, 8]);
        expect(
          repository.state.voiceLimit,
          InstrumentRepository.minimumVoiceLimit,
        );
        repository.restoreVoiceLimit();
        expect(repository.state.voiceLimit, 32);
        expect(repository.state.voiceLimitReduced, isFalse);
        expect(engine.snapshot().instruments.voiceLimit, 32);
      },
    );

    test('an epoch returns the limit to its default', () async {
      repository.apply(two);
      await pump();
      engine.instrumentNoteOn(slot: 0, origin: 1, note: 60, velocity: 90);
      await pump();
      late(1);
      await pump();
      expect(repository.state.voiceLimit, 24);
      engine
        ..stop()
        ..start(engine.defaultConfig);
      await pump();
      expect(repository.state.voiceLimit, 32);
      expect(repository.state.voiceLimitReduced, isFalse);
    });

    test('an epoch drops held notes and latches', () async {
      repository.apply(two);
      await pump();
      repository.notes.toggleLatch('pad', 'a', const [60]);
      engine
        ..stop()
        ..start(engine.defaultConfig);
      await pump();
      expect(repository.notes.isLatched('pad'), isFalse);
    });

    test('an owed release is retried on the next snapshot', () async {
      final refusing = _FullReleaseLane()
        ..start(MockAudioEngine().defaultConfig);
      final stream = StreamController<EngineSnapshot>();
      final repo = InstrumentRepository(
        engine: refusing,
        snapshots: stream.stream,
      )..apply(two);
      stream.add(refusing.snapshot());
      await Future<void>.delayed(Duration.zero);
      final token = repo.notes.press('a', const [60])!;
      refusing.refuse = 1;
      repo.notes.release(token);
      expect(repo.notes.owedReleases, 1);
      stream.add(refusing.snapshot());
      await Future<void>.delayed(Duration.zero);
      expect(repo.notes.owedReleases, 0);
      expect(refusing.snapshot().instruments.voices[0], 0);
      await repo.dispose();
      await stream.close();
    });
  });
}

class _FullReleaseLane extends MockAudioEngine {
  int refuse = 0;

  @override
  EngineResult instrumentRelease(int origin) {
    if (refuse > 0) {
      refuse--;
      return EngineResult.capacity;
    }
    return super.instrumentRelease(origin);
  }
}
