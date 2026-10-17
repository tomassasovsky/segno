import 'package:test/test.dart';
import 'package:touch_calibration_client/touch_calibration_client.dart';

const _targets = <TouchPoint>[
  (x: 0.1, y: 0.1),
  (x: 0.9, y: 0.1),
  (x: 0.9, y: 0.9),
  (x: 0.1, y: 0.9),
  (x: 0.5, y: 0.5),
];

Matcher _closeTo(TouchMatrix expected) => predicate<TouchMatrix>(
  (m) => [
    (m.a, expected.a),
    (m.b, expected.b),
    (m.c, expected.c),
    (m.d, expected.d),
    (m.e, expected.e),
    (m.f, expected.f),
  ].every((p) => (p.$1 - p.$2).abs() < 1e-9),
  'close to $expected',
);

void main() {
  group(TouchMatrix, () {
    test('parses the helper form and writes it back', () {
      final m = TouchMatrix.tryParse(' 1.1 0  -0.05\t0 0.9 0.02 ');
      expect(m, const TouchMatrix(1.1, 0, -0.05, 0, 0.9, 0.02));
      expect(
        m!.toArgument(),
        '1.100000 0.000000 -0.050000 0.000000 0.900000 0.020000',
      );
    });

    test('rejects anything but six finite numbers', () {
      expect(TouchMatrix.tryParse('1 0 0 0 1'), isNull);
      expect(TouchMatrix.tryParse('1 0 0 0 1 x'), isNull);
      expect(TouchMatrix.tryParse('1 0 0 0 1 NaN'), isNull);
    });

    test('maps a point', () {
      const m = TouchMatrix(2, 0, 0.1, 0, 0.5, -0.1);
      expect(m.map((x: 0.5, y: 0.4)), (x: 1.1, y: 0.1));
    });

    test('composes: after applies the inner matrix first', () {
      const scale = TouchMatrix(2, 0, 0, 0, 2, 0);
      const shift = TouchMatrix(1, 0, 0.1, 0, 1, 0.2);
      final both = shift.after(scale);
      final p = both.map((x: 0.3, y: 0.4));
      final q = shift.map(scale.map((x: 0.3, y: 0.4)));
      expect(p.x, closeTo(q.x, 1e-12));
      expect(p.y, closeTo(q.y, 1e-12));
    });

    test('the identity changes nothing', () {
      const m = TouchMatrix(1.2, 0.1, -0.05, 0, 0.8, 0.1);
      expect(m.after(TouchMatrix.identity), m);
      expect(TouchMatrix.identity.after(m), m);
    });
  });

  group(fitTouchMatrix, () {
    test('recovers the transform that moved the taps', () {
      // A panel whose taps land scaled and shifted from where they were
      // aimed: the fit is the inverse, mapping each landing back to its aim.
      const skew = TouchMatrix(0.9, 0.02, 0.04, -0.01, 1.08, -0.03);
      final observed = [for (final t in _targets) skew.map(t)];
      final fit = fitTouchMatrix(observed, _targets)!;
      for (var i = 0; i < _targets.length; i++) {
        final back = fit.map(observed[i]);
        expect(back.x, closeTo(_targets[i].x, 1e-9));
        expect(back.y, closeTo(_targets[i].y, 1e-9));
      }
    });

    test('of taps that already land where aimed is the identity', () {
      expect(
        fitTouchMatrix(_targets, _targets),
        _closeTo(TouchMatrix.identity),
      );
    });

    test('averages out an unsteady finger', () {
      final jitter = [0.004, -0.003, 0.002, -0.004, 0.001];
      final observed = [
        for (var i = 0; i < _targets.length; i++)
          (x: _targets[i].x + jitter[i], y: _targets[i].y - jitter[i]),
      ];
      final fit = fitTouchMatrix(observed, _targets)!;
      for (var i = 0; i < _targets.length; i++) {
        final back = fit.map(observed[i]);
        expect(back.x, closeTo(_targets[i].x, 0.01));
        expect(back.y, closeTo(_targets[i].y, 0.01));
      }
    });

    test('cannot fit fewer than three points, or points on one line', () {
      expect(
        fitTouchMatrix(_targets.sublist(0, 2), _targets.sublist(0, 2)),
        isNull,
      );
      const line = <TouchPoint>[
        (x: 0.1, y: 0.1),
        (x: 0.5, y: 0.5),
        (x: 0.9, y: 0.9),
      ];
      expect(fitTouchMatrix(line, line), isNull);
    });

    test('needs one target per tap', () {
      expect(fitTouchMatrix(_targets, _targets.sublist(0, 4)), isNull);
    });
  });
}
