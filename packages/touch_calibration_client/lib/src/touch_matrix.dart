import 'package:equatable/equatable.dart';

/// A point in a screen's normalized coordinates: `(0, 0)` is the top-left
/// corner and `(1, 1)` the bottom-right.
typedef TouchPoint = ({double x, double y});

/// libinput's touch calibration matrix: the first two rows of a 3x3 affine
/// transform, row-major, mapping a touchscreen's normalized device coordinates
/// onto the screen's normalized coordinates.
///
/// ```text
/// | a b c |   | x |
/// | d e f | * | y |
/// | 0 0 1 |   | 1 |
/// ```
class TouchMatrix extends Equatable {
  /// Creates a [TouchMatrix] from its six coefficients.
  const TouchMatrix(this.a, this.b, this.c, this.d, this.e, this.f);

  /// The matrix libinput uses when none is set.
  static const identity = TouchMatrix(1, 0, 0, 0, 1, 0);

  /// Parses the helper's form, six numbers separated by spaces; `null` when
  /// [text] is not exactly that.
  static TouchMatrix? tryParse(String text) {
    final parts = text.trim().split(RegExp(r'\s+'));
    if (parts.length != 6) return null;
    final values = parts.map(double.tryParse).toList();
    if (values.any((v) => v == null || !v.isFinite)) return null;
    return TouchMatrix(
      values[0]!,
      values[1]!,
      values[2]!,
      values[3]!,
      values[4]!,
      values[5]!,
    );
  }

  /// First row: x' = a·x + b·y + c.
  final double a;

  /// First row.
  final double b;

  /// First row.
  final double c;

  /// Second row: y' = d·x + e·y + f.
  final double d;

  /// Second row.
  final double e;

  /// Second row.
  final double f;

  /// Where this matrix maps [point].
  TouchPoint map(TouchPoint point) => (
    x: a * point.x + b * point.y + c,
    y: d * point.x + e * point.y + f,
  );

  /// The matrix that applies [inner] first and this matrix after it.
  TouchMatrix after(TouchMatrix inner) => TouchMatrix(
    a * inner.a + b * inner.d,
    a * inner.b + b * inner.e,
    a * inner.c + b * inner.f + c,
    d * inner.a + e * inner.d,
    d * inner.b + e * inner.e,
    d * inner.c + e * inner.f + f,
  );

  /// The helper's form: six numbers separated by spaces.
  String toArgument() => [a, b, c, d, e, f].map(_format).join(' ');

  static String _format(double v) {
    // Six decimals is far below a pixel on either panel, and keeps the udev
    // rule readable.
    final text = v.toStringAsFixed(6);
    return text == '-0.000000' ? '0.000000' : text;
  }

  @override
  List<Object> get props => [a, b, c, d, e, f];

  @override
  String toString() => 'TouchMatrix(${toArgument()})';
}

/// The affine matrix that best maps each of [observed] onto the [targets] at
/// the same index, by least squares; `null` when the points cannot fix one
/// (fewer than three, or all on one line).
///
/// [observed] are where the screen received the taps, already through the
/// matrix in force; [targets] are where the taps were aimed.
TouchMatrix? fitTouchMatrix(
  List<TouchPoint> observed,
  List<TouchPoint> targets,
) {
  if (observed.length != targets.length || observed.length < 3) return null;
  // Normal equations for each output row: (XᵀX)·p = Xᵀ·t, X rows [x, y, 1].
  var sxx = 0.0;
  var sxy = 0.0;
  var syy = 0.0;
  var sx = 0.0;
  var sy = 0.0;
  var tx = (x: 0.0, y: 0.0, one: 0.0);
  var ty = (x: 0.0, y: 0.0, one: 0.0);
  for (var i = 0; i < observed.length; i++) {
    final o = observed[i];
    final t = targets[i];
    sxx += o.x * o.x;
    sxy += o.x * o.y;
    syy += o.y * o.y;
    sx += o.x;
    sy += o.y;
    tx = (x: tx.x + o.x * t.x, y: tx.y + o.y * t.x, one: tx.one + t.x);
    ty = (x: ty.x + o.x * t.y, y: ty.y + o.y * t.y, one: ty.one + t.y);
  }
  final n = observed.length.toDouble();
  final m = [
    [sxx, sxy, sx],
    [sxy, syy, sy],
    [sx, sy, n],
  ];
  final row1 = _solve3(m, [tx.x, tx.y, tx.one]);
  final row2 = _solve3(m, [ty.x, ty.y, ty.one]);
  if (row1 == null || row2 == null) return null;
  return TouchMatrix(row1[0], row1[1], row1[2], row2[0], row2[1], row2[2]);
}

/// Solves the 3x3 system [m]·p = [v] by Cramer's rule; `null` when [m] is
/// singular, which here means the points do not span the screen.
List<double>? _solve3(List<List<double>> m, List<double> v) {
  double det(List<List<double>> a) =>
      a[0][0] * (a[1][1] * a[2][2] - a[1][2] * a[2][1]) -
      a[0][1] * (a[1][0] * a[2][2] - a[1][2] * a[2][0]) +
      a[0][2] * (a[1][0] * a[2][1] - a[1][1] * a[2][0]);
  final d = det(m);
  if (d.abs() < 1e-12) return null;
  List<List<double>> replaced(int column) => [
    for (var r = 0; r < 3; r++) [...m[r]]..[column] = v[r],
  ];
  return [for (var c = 0; c < 3; c++) det(replaced(c)) / d];
}
