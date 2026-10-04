import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:segno/visualizer/application/waveform_display_controller.dart';
import 'package:segno/visualizer/performance_readout.dart';
import 'package:segno/visualizer/waveform_window_service.dart';

class _Looper extends Mock implements LooperRepository {}

class _Window implements WaveformWindowService {
  Completer<bool>? opening;
  Completer<void>? failingFrame;
  int opens = 0;
  int closes = 0;
  int closeFailures = 0;
  Completer<void>? closing;
  final frames = <String>[];
  final readouts = <PerformanceReadout>[];

  @override
  bool isOpen = false;

  @override
  void Function()? onWindowReady;

  @override
  Future<bool> open({String title = ''}) async {
    opens++;
    return isOpen = await (opening?.future ?? Future.value(true));
  }

  @override
  Future<void> close() async {
    closes++;
    await closing?.future;
    if (closeFailures > 0) {
      closeFailures--;
      throw StateError('window enumeration failed');
    }
    isOpen = false;
  }

  @override
  Future<void> pushReadout(PerformanceReadout value) async {
    readouts.add(value);
  }

  @override
  Future<void> pushWaveform(Float32List samples, double progress, String name) {
    frames.add(name);
    final failure = failingFrame;
    failingFrame = null;
    return failure?.future ?? Future<void>.value();
  }
}

WaveformDisplayContext _context(int cursor) => WaveformDisplayContext(
  cursor: cursor,
  name: 'Track ${cursor + 1}',
  defaultName: true,
  mode: 'record',
  bank: 0,
  deviceLost: false,
  goodbye: ReadoutGoodbye.none,
);

void main() {
  late _Looper repository;
  late _Window window;
  late StreamController<LooperState> states;
  setUp(() {
    repository = _Looper();
    window = _Window();
    states = StreamController<LooperState>.broadcast();
    when(() => repository.looperState).thenAnswer((_) => states.stream);
    when(() => repository.lastState).thenReturn(
      const LooperState(tracks: [Track(), Track(channel: 1)]),
    );
  });
  tearDown(() => states.close());

  WaveformDisplayController build({Duration delay = Duration.zero}) =>
      WaveformDisplayController(
        repository: repository,
        window: window,
        context: _context(0),
        openDelay: delay,
      );

  for (final dispose in [false, true]) {
    test('${dispose ? 'close' : 'disable'} during opening sends no frames', () {
      fakeAsync((clock) {
        window.opening = Completer<bool>();
        final display = build()..start(enabled: true, title: 'Waveform');
        clock.flushMicrotasks();
        expect(window.opens, 1);
        if (dispose) {
          unawaited(display.close());
        } else {
          display.setEnabled(enabled: false, title: 'Waveform');
        }
        window.opening!.complete(true);
        clock
          ..flushMicrotasks()
          ..elapse(const Duration(seconds: 1));
        expect(window.isOpen, isFalse);
        expect(window.frames, isEmpty);
        expect(window.readouts, isEmpty);
        unawaited(display.close());
        clock.flushMicrotasks();
      });
    });
  }

  test('disable and re-enable while opening follow only the latest intent', () {
    fakeAsync((clock) {
      final pending = Completer<bool>();
      window.opening = pending;
      final display = build()..start(enabled: true, title: 'Waveform');
      clock.flushMicrotasks();
      display
        ..setEnabled(enabled: false, title: 'Waveform')
        ..setEnabled(enabled: true, title: 'Waveform');
      window.opening = null;
      pending.complete(true);
      clock
        ..flushMicrotasks()
        ..elapse(const Duration(milliseconds: 100));
      expect(window.opens, 2);
      expect(window.isOpen, isTrue);
      expect(window.frames, ['Track 1']);
      expect(window.readouts.single.selected!.channel, 0);
      unawaited(display.close());
      clock.flushMicrotasks();
      expect(clock.periodicTimerCount, 0);
      expect(clock.nonPeriodicTimerCount, 0);
    });
  });

  test('every disposal caller waits for the in-flight window to close', () {
    fakeAsync((clock) {
      window.opening = Completer<bool>();
      final display = build()..start(enabled: true, title: 'Waveform');
      clock.flushMicrotasks();
      var completions = 0;
      unawaited(display.close().then((_) => completions++));
      unawaited(display.close().then((_) => completions++));
      clock.flushMicrotasks();
      expect(completions, 0);
      window.opening!.complete(true);
      clock.flushMicrotasks();
      expect(completions, 2);
      expect(window.isOpen, isFalse);
      expect(window.frames, isEmpty);
    });
  });

  test('a startup delay cannot reopen a disposed display', () {
    fakeAsync((clock) {
      final display = build(delay: const Duration(seconds: 2))
        ..start(enabled: true, title: 'Waveform');
      unawaited(display.close());
      clock
        ..flushMicrotasks()
        ..elapse(const Duration(seconds: 3));
      expect(window.opens, 0);
      expect(window.frames, isEmpty);
    });
  });

  test('same-turn display retry reconciles the latest intent', () {
    fakeAsync((clock) {
      var displays = 1;
      final display = WaveformDisplayController(
        repository: repository,
        window: window,
        context: _context(0),
        displayCount: () => displays,
      )..start(enabled: true, title: 'Waveform');
      displays = 2;
      display.setEnabled(enabled: true, title: 'Waveform');
      clock.flushMicrotasks();
      expect(window.opens, 1);
      expect(window.isOpen, isTrue);
      unawaited(display.close());
      clock.flushMicrotasks();
    });
  });

  for (final failures in [1, 2]) {
    test(
      'disable attempts a failed close once ($failures platform failures)',
      () {
        fakeAsync((clock) {
          final errors = <Object>[];
          runZonedGuarded(() {
            final display = build()..start(enabled: true, title: 'Waveform');
            clock.flushMicrotasks();
            window.closeFailures = failures;
            display.setEnabled(enabled: false, title: 'Waveform');
            clock.flushMicrotasks();
            expect(window.closes, 1);
            expect(errors, isEmpty);
            expect(states.hasListener, isFalse);
            clock.elapse(const Duration(seconds: 1));
            expect(window.frames, ['Track 1']);
            expect(window.readouts, isEmpty);
            expect(window.closes, 1);
            // A new intent may retry; the failed intent must not spin.
            display.setEnabled(enabled: false, title: 'Waveform');
            clock.flushMicrotasks();
            expect(window.closes, 2);
            expect(errors, isEmpty);
            unawaited(display.close());
            clock.flushMicrotasks();
            expect(window.closes, 3);
            expect(window.isOpen, isFalse);
            expect(window.onWindowReady, isNull);
          }, (error, _) => errors.add(error));
          expect(errors, isEmpty);
        });
      },
    );

    test('disposal while opening cleans up after $failures close failures', () {
      fakeAsync((clock) {
        final errors = <Object>[];
        runZonedGuarded(() {
          window
            ..opening = Completer<bool>()
            ..closeFailures = failures;
          final display = build()..start(enabled: true, title: 'Waveform');
          var streamClosed = false;
          display.failures.listen((_) {}, onDone: () => streamClosed = true);
          clock.flushMicrotasks();
          final first = display.close();
          final second = display.close();
          expect(identical(first, second), isTrue);
          var completed = 0;
          final closeErrors = <Object>[];
          for (final close in [first, second]) {
            unawaited(
              close.then(
                (_) => completed++,
                onError: (Object error) {
                  closeErrors.add(error);
                },
              ),
            );
          }
          clock.flushMicrotasks();
          expect(completed, 0);
          expect(closeErrors, isEmpty);
          window.opening!.complete(true);
          clock.flushMicrotasks();
          expect(window.closes, 2);
          expect(streamClosed, isTrue);
          expect(completed, failures == 1 ? 2 : 0);
          expect(closeErrors, hasLength(failures == 1 ? 0 : 2));
          expect(errors, isEmpty);
          expect(window.onWindowReady, isNull);
          expect(states.hasListener, isFalse);
          expect(window.frames, isEmpty);
          expect(window.readouts, isEmpty);
          clock.elapse(const Duration(seconds: 1));
          expect(clock.periodicTimerCount, 0);
          expect(clock.nonPeriodicTimerCount, 0);
          display.setEnabled(enabled: true, title: 'Waveform');
          clock.flushMicrotasks();
          expect(window.opens, 1);
        }, (error, _) => errors.add(error));
        expect(errors, isEmpty);
      });
    });
  }

  test('a newer enable survives a failed close of the previous intent', () {
    fakeAsync((clock) {
      final errors = <Object>[];
      runZonedGuarded(() {
        final display = build()..start(enabled: true, title: 'Waveform');
        clock.flushMicrotasks();
        final closing = Completer<void>();
        window.closing = closing;
        display.setEnabled(enabled: false, title: 'Waveform');
        clock.flushMicrotasks();
        display.setEnabled(enabled: true, title: 'Waveform');
        window.closing = null;
        closing.completeError(StateError('window enumeration failed'));
        clock.flushMicrotasks();
        expect(window.opens, 2);
        expect(window.frames, ['Track 1', 'Track 1']);
        expect(errors, isEmpty);
        unawaited(display.close());
        clock.flushMicrotasks();
      }, (error, _) => errors.add(error));
      expect(errors, isEmpty);
    });
  });

  test('an old failed frame does not replay after a new selection', () {
    fakeAsync((clock) {
      final failed = Completer<void>();
      window.failingFrame = failed;
      final display = build()..start(enabled: true, title: 'Waveform');
      clock.flushMicrotasks();
      display.updateContext(_context(1));
      clock.elapse(const Duration(milliseconds: 40));
      expect(window.frames, ['Track 1', 'Track 2']);
      failed.completeError(StateError('Old delivery failed'));
      clock
        ..flushMicrotasks()
        ..elapse(const Duration(milliseconds: 100));
      expect(window.frames, ['Track 1', 'Track 2']);
      expect(window.readouts.last.selected!.channel, 1);
      unawaited(display.close());
      clock.flushMicrotasks();
    });
  });
}
