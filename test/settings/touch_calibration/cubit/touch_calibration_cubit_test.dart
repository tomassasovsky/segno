import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/settings/touch_calibration/cubit/touch_calibration_cubit.dart';
import 'package:touch_calibration_client/touch_calibration_client.dart';

import '../fake_touch_calibration_client.dart';

const _capture = <TouchPoint>[
  (x: 0.1, y: 0.1),
  (x: 0.9, y: 0.1),
  (x: 0.9, y: 0.9),
  (x: 0.1, y: 0.9),
  (x: 0.5, y: 0.5),
];
const _test = <TouchPoint>[(x: 0.3, y: 0.3), (x: 0.7, y: 0.7)];

/// Taps that land shifted right and down from where they were aimed.
const _skew = TouchMatrix(1, 0, 0.05, 0, 1, 0.03);

void main() {
  late FakeTouchCalibrationClient client;

  TouchCalibrationCubit cubit() => TouchCalibrationCubit(
    client: client,
    screen: TouchScreen.readout,
    captureTargets: _capture,
    testTargets: _test,
  );

  /// Starts [c] and taps every capture target the way [_skew] lands them.
  void capture(FakeAsync async, TouchCalibrationCubit c) {
    c.start();
    async.flushMicrotasks();
    for (final target in _capture) {
      c.tap(_skew.map(target));
    }
    async.flushMicrotasks();
  }

  setUp(() => client = FakeTouchCalibrationClient());

  test('walks the capture targets in order', () {
    fakeAsync((async) {
      final c = cubit()..start();
      async.flushMicrotasks();
      expect(
        c.state,
        const TouchCalibrationState(
          phase: .capture,
          steps: 5,
          target: (x: 0.1, y: 0.1),
        ),
      );
      c.tap((x: 0.1, y: 0.1));
      expect(c.state.step, 1);
      expect(c.state.target, _capture[1]);
    });
  });

  test('applies the fit, so the skewed taps land where they were aimed', () {
    fakeAsync((async) {
      final c = cubit();
      capture(async, c);
      expect(client.calls, ['read readout', 'write readout']);
      for (final target in _capture) {
        final back = client.stored!.map(_skew.map(target));
        expect(back.x, closeTo(target.x, 1e-9));
        expect(back.y, closeTo(target.y, 1e-9));
      }
      expect(
        c.state,
        const TouchCalibrationState(
          phase: .test,
          steps: 2,
          target: (x: 0.3, y: 0.3),
          secondsLeft: 30,
        ),
      );
    });
  });

  test('composes the fit with the calibration already in force', () {
    fakeAsync((async) {
      const previous = TouchMatrix(1.1, 0, -0.02, 0, 0.9, 0.04);
      client.stored = previous;
      final c = cubit();
      capture(async, c);
      final fit = fitTouchMatrix([
        for (final t in _capture) _skew.map(t),
      ], _capture)!;
      expect(client.stored, fit.after(previous));
    });
  });

  test('taps on a line cannot fix a matrix, so the capture starts over', () {
    fakeAsync((async) {
      final c = cubit()..start();
      async.flushMicrotasks();
      for (var i = 0; i < _capture.length; i++) {
        c.tap((x: 0.1 * i, y: 0.1 * i));
      }
      async.flushMicrotasks();
      expect(client.calls, ['read readout']);
      expect(c.state.phase, TouchCalibrationPhase.capture);
      expect(c.state.step, 0);
    });
  });

  test('a test tap counts only near its target', () {
    fakeAsync((async) {
      final c = cubit();
      capture(async, c);
      c.tap((x: 0.5, y: 0.5));
      expect(c.state.step, 0);
      c.tap((x: 0.31, y: 0.29));
      expect(c.state.step, 1);
      expect(c.state.target, _test[1]);
      c.tap((x: 0.7, y: 0.7));
      expect(c.state.target, isNull);
      expect(c.state.phase, TouchCalibrationPhase.test);
    });
  });

  test('the countdown reverts an untried calibration', () {
    fakeAsync((async) {
      final c = cubit();
      capture(async, c);
      async.elapse(const Duration(seconds: 10));
      expect(c.state.secondsLeft, 20);
      async.elapse(const Duration(seconds: 20));
      expect(c.state.phase, TouchCalibrationPhase.reverted);
      expect(client.calls.last, 'reset readout');
      expect(client.stored, isNull);
    });
  });

  test('the countdown puts a previous calibration back', () {
    fakeAsync((async) {
      const previous = TouchMatrix(1.1, 0, -0.02, 0, 0.9, 0.04);
      client.stored = previous;
      final c = cubit();
      capture(async, c);
      async.elapse(const Duration(seconds: 30));
      expect(c.state.phase, TouchCalibrationPhase.reverted);
      expect(client.stored, previous);
    });
  });

  test('Keep stops the countdown and leaves the new calibration', () {
    fakeAsync((async) {
      final c = cubit();
      capture(async, c);
      final applied = client.stored;
      c.keep();
      async.elapse(const Duration(seconds: 60));
      expect(c.state.phase, TouchCalibrationPhase.kept);
      expect(client.stored, applied);
      _close(async, c);
      expect(client.stored, applied);
    });
  });

  test('Restart reverts, then captures again', () {
    fakeAsync((async) {
      final c = cubit();
      capture(async, c);
      c.restart();
      async.flushMicrotasks();
      expect(client.calls.last, 'reset readout');
      expect(c.state.phase, TouchCalibrationPhase.capture);
      expect(c.state.step, 0);
      async.elapse(const Duration(seconds: 60));
      expect(c.state.phase, TouchCalibrationPhase.capture);
    });
  });

  test('Cancel before anything was applied changes nothing', () {
    fakeAsync((async) {
      final c = cubit()..start();
      async.flushMicrotasks();
      c.cancel();
      async.flushMicrotasks();
      expect(c.state.phase, TouchCalibrationPhase.reverted);
      expect(client.calls, ['read readout']);
    });
  });

  test('closing mid-test reverts', () {
    fakeAsync((async) {
      final c = cubit();
      capture(async, c);
      _close(async, c);
      expect(client.calls.last, 'reset readout');
    });
  });

  test('a failed write says so', () {
    fakeAsync((async) {
      client.failWrites = true;
      final c = cubit();
      capture(async, c);
      expect(c.state.phase, TouchCalibrationPhase.failed);
    });
  });
}

void _close(FakeAsync async, TouchCalibrationCubit c) {
  c.close().ignore();
  async.flushMicrotasks();
}
