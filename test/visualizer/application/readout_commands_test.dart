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

  /// Whether the engine takes a tempo now (D6).
  late bool tempoFree;
  late List<double> sets;

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

    test('a refused nudge leaves nothing for the next to build on', () {
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
