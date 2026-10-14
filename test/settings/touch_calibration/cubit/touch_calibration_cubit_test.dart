import 'dart:async';

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
      expect(client.calls, ['read readout', 'apply readout']);
      for (final target in _capture) {
        final back = client.inForce!.map(_skew.map(target));
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

  test('stores nothing until Keep, so a power cycle drops an untried fit', () {
    fakeAsync((async) {
      const previous = TouchMatrix(1.1, 0, -0.02, 0, 0.9, 0.04);
      client.stored = client.inForce = previous;
      final c = cubit();
      capture(async, c);
      expect(client.inForce, isNot(previous));
      expect(client.stored, previous);
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
      expect(client.inForce, fit.after(previous));
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
      expect(client.calls.last, 'restore readout');
      expect(client.inForce, isNull);
    });
  });

  test('the countdown puts a previous calibration back', () {
    fakeAsync((async) {
      const previous = TouchMatrix(1.1, 0, -0.02, 0, 0.9, 0.04);
      client.stored = client.inForce = previous;
      final c = cubit();
      capture(async, c);
      async.elapse(const Duration(seconds: 30));
      expect(c.state.phase, TouchCalibrationPhase.reverted);
      expect(client.inForce, previous);
    });
  });

  test('Keep stores the new calibration and stops the countdown', () {
    fakeAsync((async) {
      final c = cubit();
      capture(async, c);
      final applied = client.inForce;
      c.keep();
      expect(c.state.phase, TouchCalibrationPhase.saving);
      async.elapse(const Duration(seconds: 60));
      expect(c.state.phase, TouchCalibrationPhase.kept);
      expect(client.stored, applied);
      _close(async, c);
      expect(client.calls.last, 'write readout');
      expect(client.inForce, applied);
    });
  });

  test('Restart reverts, then captures again', () {
    fakeAsync((async) {
      final c = cubit();
      capture(async, c);
      c.restart();
      async.flushMicrotasks();
      expect(client.calls.last, 'restore readout');
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
      expect(client.calls.last, 'restore readout');
    });
  });

  test('Cancel while the fit is applied reverts it once it lands', () {
    fakeAsync((async) {
      client.applyGate = Completer<void>();
      final c = cubit();
      capture(async, c);
      expect(c.state.phase, TouchCalibrationPhase.applying);
      c.cancel();
      async.flushMicrotasks();
      expect(client.calls.last, 'apply readout');
      client.applyGate!.complete();
      async.flushMicrotasks();
      expect(client.calls.last, 'restore readout');
      expect(client.inForce, isNull);
      expect(c.state.phase, TouchCalibrationPhase.reverted);
    });
  });

  test('leaving while the fit is applied reverts it once it lands', () {
    fakeAsync((async) {
      client.applyGate = Completer<void>();
      final c = cubit();
      capture(async, c);
      _close(async, c);
      client.applyGate!.complete();
      async.flushMicrotasks();
      expect(client.calls, [
        'read readout',
        'apply readout',
        'restore readout',
      ]);
      expect(client.inForce, isNull);
    });
  });

  test('Keep and test taps do nothing while a revert runs', () {
    fakeAsync((async) {
      final c = cubit();
      capture(async, c);
      c
        ..restart()
        ..keep()
        ..tap(_test.first);
      expect(c.state.phase, TouchCalibrationPhase.reverting);
      async.flushMicrotasks();
      expect(client.calls, isNot(contains('write readout')));
      expect(client.stored, isNull);
    });
  });

  test('a failed apply says so, and leaving still reverts', () {
    fakeAsync((async) {
      client.failApply = true;
      final c = cubit();
      capture(async, c);
      expect(c.state.phase, TouchCalibrationPhase.failed);
      _close(async, c);
      expect(client.calls.last, 'restore readout');
    });
  });

  test('a failed Keep says so', () {
    fakeAsync((async) {
      client.failWrite = true;
      final c = cubit();
      capture(async, c);
      c.keep();
      async.flushMicrotasks();
      expect(c.state.phase, TouchCalibrationPhase.failed);
    });
  });

  test('a failed revert is tried again on leaving', () {
    fakeAsync((async) {
      client.failRestore = true;
      final c = cubit();
      capture(async, c);
      c.cancel();
      async.flushMicrotasks();
      expect(c.state.phase, TouchCalibrationPhase.failed);
      client.failRestore = false;
      _close(async, c);
      expect(client.calls.last, 'restore readout');
      expect(client.inForce, isNull);
    });
  });
}

void _close(FakeAsync async, TouchCalibrationCubit c) {
  c.close().ignore();
  async.flushMicrotasks();
}
