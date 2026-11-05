import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:segno/looper/application/record_settings.dart';
import 'package:segno/looper/application/record_timing_settings.dart';
import 'package:segno/looper/application/tempo_settings.dart';
import 'package:segno/looper/model/record_length.dart';
import 'package:segno/looper/model/record_timing.dart';
import 'package:segno/looper/model/tempo_state.dart';
import 'package:segno/visualizer/application/readout_commands.dart';
import 'package:segno/visualizer/readout_command.dart';

class _Looper extends Mock implements LooperRepository {}

class _Tempo extends Mock implements TempoSettings {}

class _Record extends Mock implements RecordSettings {}

class _Timing extends Mock implements RecordTimingSettings {}

void main() {
  late _Looper repository;
  late _Tempo tempo;
  late _Record record;
  late _Timing timing;
  late ReadoutCommands commands;

  /// What the engine publishes as the live tempo; `0` is none.
  late double live;

  /// What the tempo owner accepted last.
  late double accepted;

  /// Whether the owner takes a tempo when it is set.
  late bool tempoFree;
  late List<double> sets;

  /// What the engine says a tempo change does now, and who sets the tempo.
  late TempoFollowState follow;
  late TempoSource source;
  late bool dimmed;

  /// What the engine answers a Clear tempo, and what came back refused.
  late EngineResult clearResult;
  late List<ReadoutRefusal> refusals;

  setUpAll(() => registerFallbackValue(RecordTiming.immediately));

  setUp(() {
    repository = _Looper();
    tempo = _Tempo();
    record = _Record();
    timing = _Timing();
    live = 84;
    accepted = 84;
    tempoFree = true;
    sets = [];
    follow = TempoFollowState.free;
    source = TempoSource.manual;
    dimmed = false;
    clearResult = EngineResult.ok;
    refusals = [];
    when(() => repository.lastState).thenAnswer(
      (_) => LooperState(
        tempoFollow: follow,
        transport: TransportState(tempoBpm: live, tempoSource: source),
      ),
    );
    when(() => repository.sessionTransport).thenAnswer(
      (_) => TransportState(
        tempoBpm: live,
        tempoSource: live > 0 ? TempoSource.manual : TempoSource.none,
      ),
    );
    when(() => tempo.state).thenAnswer((_) => TempoState(bpm: accepted));
    // The owner publishes an accepted tempo before it saves it, and skips a
    // refused one, as TempoSettings.setTempo does.
    when(() => tempo.setTempo(any())).thenAnswer((call) async {
      final bpm = call.positionalArguments.single as double;
      sets.add(bpm);
      if (tempoFree) accepted = bpm;
    });
    when(() => tempo.tapTempo()).thenReturn(EngineResult.ok);
    when(() => tempo.clearTempo()).thenAnswer((_) async => clearResult);
    when(() => tempo.setTimeSignature(any(), any())).thenAnswer((_) async {});
    when(() => record.setDefaultLengthBars(any())).thenAnswer(
      (_) async => const RecordLengthOutcome(RecordLengthStatus.applied),
    );
    when(() => timing.setTiming(any())).thenAnswer(
      (_) async => const RecordTimingOutcome(RecordTimingStatus.applied),
    );
    commands = ReadoutCommands(
      repository: repository,
      tempo: tempo,
      record: record,
      timing: timing,
      dimmed: () => dimmed,
      onRefused: refusals.add,
    );
  });

  group('a nudge', () {
    test('adds to the live tempo, in hundredths', () {
      commands.handle(const TempoNudge(0.1));
      expect(sets, [84.1]);
    });

    test('counts every repeat before the engine publishes', () {
      commands
        ..handle(const TempoNudge(0.1))
        ..handle(const TempoNudge(0.1))
        ..handle(const TempoNudge(1));
      expect(sets, [84.1, 84.2, 85.2]);
    });

    test('builds on the live tempo once the engine has published', () {
      commands.handle(const TempoNudge(1));
      // The engine applied it, then something else moved it.
      live = 90;
      commands.handle(const TempoNudge(-1));
      expect(sets, [85, 89]);
    });

    test('reads a published float tempo back in hundredths', () {
      commands.handle(const TempoNudge(0.1));
      live = 84.0999984741211;
      commands.handle(const TempoNudge(0.1));
      expect(sets, [84.1, 84.2]);
    });

    test('stops at the ends of the range', () {
      live = 299.5;
      commands.handle(const TempoNudge(1));
      live = 30.05;
      commands.handle(const TempoNudge(-0.1));
      expect(sets, [300, 30]);
    });

    test('starts from 120 when no tempo is set', () {
      live = 0;
      commands.handle(const TempoNudge(-1));
      expect(sets, [119]);
    });

    test('a set the owner did not take leaves nothing to build on', () {
      tempoFree = false;
      commands
        ..handle(const TempoNudge(1))
        ..handle(const TempoNudge(1));
      tempoFree = true;
      commands.handle(const TempoNudge(1));
      expect(sets, [85, 85, 85]);
    });

    test('a nudge older than a second no longer stands in for the live '
        'tempo', () {
      fakeAsync((async) {
        commands.handle(const TempoNudge(1));
        async.elapse(const Duration(seconds: 2));
        commands.handle(const TempoNudge(1));
        expect(sets, [85, 85]);
      });
    });
  });

  group('the tempo lock', () {
    void sendTempo() {
      commands
        ..handle(const TempoNudge(1))
        ..handle(const TempoSet(100))
        ..handle(const TempoTap());
    }

    for (final locked in [
      TempoFollowState.noGrid,
      TempoFollowState.noFollower,
      TempoFollowState.busy,
    ]) {
      test('${locked.name}: no tempo change reaches the owner', () {
        follow = locked;
        sendTempo();
        expect(sets, isEmpty);
        verifyNever(() => tempo.tapTempo());
      });
    }

    test('an external clock: no tempo change reaches the owner', () {
      source = TempoSource.external;
      sendTempo();
      expect(sets, isEmpty);
      verifyNever(() => tempo.tapTempo());
    });

    test('a change that retimes the loops goes through', () {
      follow = TempoFollowState.retimes;
      sendTempo();
      expect(sets, [85, 100]);
      verify(() => tempo.tapTempo()).called(1);
    });

    test('the signature changes only while nothing is recorded', () {
      follow = TempoFollowState.retimes;
      commands.handle(const SignatureSet(6, 8));
      verifyNever(() => tempo.setTimeSignature(any(), any()));
      follow = TempoFollowState.free;
      commands.handle(const SignatureSet(6, 8));
      verify(() => tempo.setTimeSignature(6, 8)).called(1);
    });
  });

  test('a dimmed console takes no command: the waking touch presses '
      'nothing', () {
    dimmed = true;
    commands
      ..handle(const TempoNudge(1))
      ..handle(const TempoTap())
      ..handle(const TempoClear())
      ..handle(const LengthSet(8))
      ..handle(const TimingSet(RecordTiming.bar));
    expect(sets, isEmpty);
    verifyNever(() => tempo.tapTempo());
    verifyNever(() => tempo.clearTempo());
    verifyNever(() => record.setDefaultLengthBars(any()));
    verifyNever(() => timing.setTiming(any()));
  });

  group('an exact tempo', () {
    test('is set in hundredths', () {
      commands.handle(const TempoSet(128.471));
      expect(sets, [128.47]);
    });

    test('outside the range is ignored', () {
      commands
        ..handle(const TempoSet(350))
        ..handle(const TempoSet(3));
      expect(sets, isEmpty);
    });

    test('is where the next nudge starts, before the engine publishes', () {
      commands
        ..handle(const TempoNudge(1))
        ..handle(const TempoSet(100))
        ..handle(const TempoNudge(1));
      expect(sets, [85, 100, 101]);
    });
  });

  test('a tap is one tap tempo', () {
    commands.handle(const TempoTap());
    verify(() => tempo.tapTempo()).called(1);
  });

  test('the touch that woke the console presses nothing, even one that '
      'acts on release', () {
    fakeAsync((async) {
      commands
        ..woke()
        ..handle(const TempoClear())
        ..handle(const LengthSet(8))
        ..handle(const TempoNudge(1));
      async.flushMicrotasks();
      verifyNever(() => tempo.clearTempo());
      verifyNever(() => record.setDefaultLengthBars(any()));
      expect(sets, isEmpty);

      async.elapse(ReadoutCommands.wakeGesture);
      commands.handle(const LengthSet(8));
      verify(() => record.setDefaultLengthBars(8)).called(1);
    });
  });

  group('Clear tempo (#1653)', () {
    test('clears through the tempo owner and answers nothing', () async {
      commands.handle(const TempoClear());
      await pumpEventQueue();
      verify(() => tempo.clearTempo()).called(1);
      expect(refusals, isEmpty);
    });

    test("leaves the lock to the engine, as the main screen's does", () async {
      // The panel's own tempo locks do not stop it: the engine decides.
      follow = TempoFollowState.busy;
      source = TempoSource.external;
      commands.handle(const TempoClear());
      await pumpEventQueue();
      verify(() => tempo.clearTempo()).called(1);
    });

    test('a refused clear keeps the nudge it did not clear', () async {
      clearResult = EngineResult.notReady;
      commands
        ..handle(const TempoNudge(1))
        ..handle(const TempoClear());
      await pumpEventQueue();
      commands.handle(const TempoNudge(1));
      expect(sets, [85, 86]);
    });

    test("a refusal comes back with the main screen's reason", () async {
      for (final (result, refusal) in [
        (EngineResult.notReady, ReadoutRefusal.tempoClearLocked),
        (EngineResult.notRunning, ReadoutRefusal.tempoClearStopped),
        (EngineResult.unsupported, ReadoutRefusal.tempoClearOther),
      ]) {
        clearResult = result;
        commands.handle(const TempoClear());
        await pumpEventQueue();
        expect(refusals.last, refusal, reason: result.name);
      }
      expect(refusals, hasLength(3));
    });
  });

  test('a time signature from the valid set is set', () {
    commands.handle(const SignatureSet(6, 8));
    verify(() => tempo.setTimeSignature(6, 8)).called(1);
  });

  test('a time signature outside the valid set is ignored', () {
    commands
      ..handle(const SignatureSet(4, 8))
      ..handle(const SignatureSet(16, 8));
    verifyNever(() => tempo.setTimeSignature(any(), any()));
  });

  test('a length sets the default for all tracks', () {
    commands
      ..handle(const LengthSet(8))
      ..handle(const LengthSet(0));
    verifyInOrder([
      () => record.setDefaultLengthBars(8),
      () => record.setDefaultLengthBars(0),
    ]);
    verifyNoMoreInteractions(record);
  });

  test('a record timing sets the default for all tracks', () {
    commands.handle(const TimingSet(RecordTiming.quarter));
    verify(() => timing.setTiming(RecordTiming.quarter)).called(1);
    verifyNoMoreInteractions(timing);
  });
}
