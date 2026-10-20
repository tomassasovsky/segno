import 'dart:async';
import 'dart:math' as math;

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:touch_calibration_client/touch_calibration_client.dart';

/// Where a touch calibration is (pen 30).
enum TouchCalibrationPhase {
  /// Reading the calibration in force.
  loading,

  /// Tapping the capture targets.
  capture,

  /// Applying the measured calibration, not yet stored.
  applying,

  /// Trying the new calibration, under the revert countdown.
  test,

  /// Storing the new calibration, after Keep.
  saving,

  /// Putting the stored calibration back.
  reverting,

  /// The new calibration was kept.
  kept,

  /// The previous calibration is back: the countdown ran out, or the player
  /// cancelled.
  reverted,

  /// The calibration could not be read or saved.
  failed,
}

/// A touch calibration's progress.
class TouchCalibrationState extends Equatable {
  /// Creates a [TouchCalibrationState].
  const TouchCalibrationState({
    this.phase = TouchCalibrationPhase.loading,
    this.step = 0,
    this.steps = 0,
    this.target,
    this.secondsLeft = 0,
  });

  /// Where the calibration is.
  final TouchCalibrationPhase phase;

  /// The current target's index in its phase.
  final int step;

  /// How many targets the phase has.
  final int steps;

  /// The point to tap, in the screen's normalized coordinates; `null` when
  /// nothing is to be tapped.
  final TouchPoint? target;

  /// Seconds before the test reverts to the previous calibration.
  final int secondsLeft;

  @override
  List<Object?> get props => [phase, step, steps, target, secondsLeft];
}

/// Measures one screen's touch calibration (pen 30, "Displays & touch
/// calibration"): the player taps five targets, the fit that maps where the
/// taps landed onto where they were aimed is applied, and the player tries it
/// on three more before keeping it. Not kept within the test duration (30 s by
/// default), and the previous calibration comes back on its own, so a
/// calibration that made the screen untouchable undoes itself.
///
/// Taps arrive through [tap], already in the screen's normalized coordinates,
/// and already through the calibration in force: the fit is composed with it.
///
/// The new calibration is only applied while it is tried, and stored on Keep,
/// so one that a power cycle interrupts is gone after the reboot. Helper calls
/// run one at a time, in the order they were made: a revert never overtakes
/// the apply it undoes.
class TouchCalibrationCubit extends Cubit<TouchCalibrationState> {
  /// Creates a [TouchCalibrationCubit] for [screen].
  TouchCalibrationCubit({
    required TouchCalibrationClient client,
    required TouchScreen screen,
    required List<TouchPoint> captureTargets,
    required List<TouchPoint> testTargets,
    Duration testDuration = const Duration(seconds: 30),
    double hitTolerance = 0.04,
  }) : assert(captureTargets.length >= 3, 'a fit needs three points'),
       assert(testTargets.isNotEmpty, 'the test needs a target'),
       _client = client,
       _screen = screen,
       _captureTargets = captureTargets,
       _testTargets = testTargets,
       _testDuration = testDuration,
       _hitTolerance = hitTolerance,
       super(const TouchCalibrationState());

  final TouchCalibrationClient _client;
  final TouchScreen _screen;
  final List<TouchPoint> _captureTargets;
  final List<TouchPoint> _testTargets;

  /// How long the player has to keep a new calibration.
  final Duration _testDuration;

  /// How close to a test target a tap has to land, in normalized units.
  final double _hitTolerance;

  TouchMatrix? _previous;
  TouchMatrix? _tried;
  final _observed = <TouchPoint>[];

  /// Whether a calibration that is not stored may be in force: set before the
  /// apply starts, so leaving while it runs still reverts it.
  var _applied = false;
  Timer? _countdown;
  Future<void> _helper = Future.value();

  /// Runs [op] after every helper call made before it.
  Future<void> _serial(Future<void> Function() op) {
    final next = _helper.then((_) => op());
    _helper = next.then((_) {}, onError: (Object _) {});
    return next;
  }

  /// Reads the calibration in force and shows the first target.
  void start() => unawaited(_start());

  Future<void> _start() async {
    try {
      _previous = await _client.read(_screen);
    } on Object {
      if (!isClosed) emit(const TouchCalibrationState(phase: .failed));
      return;
    }
    if (!isClosed) _capture();
  }

  void _capture() {
    _observed.clear();
    emit(
      TouchCalibrationState(
        phase: .capture,
        steps: _captureTargets.length,
        target: _captureTargets.first,
      ),
    );
  }

  /// A tap on the screen being calibrated, in its normalized coordinates.
  void tap(TouchPoint point) {
    switch (state.phase) {
      case .capture:
        _observed.add(point);
        if (_observed.length < _captureTargets.length) {
          emit(
            TouchCalibrationState(
              phase: .capture,
              step: _observed.length,
              steps: _captureTargets.length,
              target: _captureTargets[_observed.length],
            ),
          );
        } else {
          unawaited(_fitAndApply());
        }
      case .test:
        final target = state.target;
        if (target == null || !_hits(point, target)) return;
        final next = state.step + 1;
        emit(
          TouchCalibrationState(
            phase: .test,
            step: next,
            steps: _testTargets.length,
            target: next < _testTargets.length ? _testTargets[next] : null,
            secondsLeft: state.secondsLeft,
          ),
        );
      case .loading ||
          .applying ||
          .saving ||
          .reverting ||
          .kept ||
          .reverted ||
          .failed:
        return;
    }
  }

  bool _hits(TouchPoint point, TouchPoint target) =>
      math.sqrt(
        math.pow(point.x - target.x, 2) + math.pow(point.y - target.y, 2),
      ) <=
      _hitTolerance;

  Future<void> _fitAndApply() async {
    final fit = fitTouchMatrix(List.of(_observed), _captureTargets);
    if (fit == null) {
      // The taps were too far off one another to fix a matrix (all on a line,
      // say): start the capture over rather than store nonsense.
      _capture();
      return;
    }
    final matrix = _tried = fit.after(_previous ?? TouchMatrix.identity);
    emit(
      TouchCalibrationState(
        phase: .applying,
        step: _captureTargets.length,
        steps: _captureTargets.length,
      ),
    );
    _applied = true;
    try {
      await _serial(() => _client.apply(_screen, matrix));
    } on Object {
      if (!isClosed && state.phase == .applying) {
        emit(const TouchCalibrationState(phase: .failed));
      }
      return;
    }
    // Left, or cancelled, while it was applied: the revert is already queued.
    if (isClosed || state.phase != .applying) return;
    emit(
      TouchCalibrationState(
        phase: .test,
        steps: _testTargets.length,
        target: _testTargets.first,
        secondsLeft: _testDuration.inSeconds,
      ),
    );
    _countdown = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  void _tick() {
    if (state.phase != .test) return;
    final left = state.secondsLeft - 1;
    if (left > 0) {
      emit(
        TouchCalibrationState(
          phase: .test,
          step: state.step,
          steps: state.steps,
          target: state.target,
          secondsLeft: left,
        ),
      );
      return;
    }
    unawaited(_revertThen(const TouchCalibrationState(phase: .reverted)));
  }

  /// Stores the new calibration.
  void keep() {
    final matrix = _tried;
    if (state.phase != .test || matrix == null) return;
    _countdown?.cancel();
    emit(const TouchCalibrationState(phase: .saving));
    unawaited(_save(matrix));
  }

  Future<void> _save(TouchMatrix matrix) async {
    try {
      await _serial(() => _client.write(_screen, matrix));
    } on Object {
      if (!isClosed) emit(const TouchCalibrationState(phase: .failed));
      return;
    }
    _applied = false;
    if (!isClosed) emit(const TouchCalibrationState(phase: .kept));
  }

  /// Puts the stored calibration back and starts the capture over.
  void restart() {
    if (state.phase != .test) return;
    unawaited(_revertThen(null));
  }

  /// Leaves without changing anything: a calibration applied but not kept is
  /// reverted first. Ignored once Keep is storing it.
  void cancel() {
    switch (state.phase) {
      case .saving || .reverting || .kept || .reverted:
        return;
      case .loading || .capture || .applying || .test || .failed:
        unawaited(_revertThen(const TouchCalibrationState(phase: .reverted)));
    }
  }

  /// Reverts what this calibration applied, then emits [next], or starts the
  /// capture over when [next] is null.
  Future<void> _revertThen(TouchCalibrationState? next) async {
    _countdown?.cancel();
    emit(const TouchCalibrationState(phase: .reverting));
    try {
      await _revert();
    } on Object {
      if (!isClosed) emit(const TouchCalibrationState(phase: .failed));
      return;
    }
    if (isClosed) return;
    if (next == null) {
      _capture();
    } else {
      emit(next);
    }
  }

  Future<void> _revert() async {
    if (!_applied) return;
    _applied = false;
    try {
      await _serial(() => _client.restore(_screen));
    } on Object {
      // Still possibly in force: leaving the page tries again.
      _applied = true;
      rethrow;
    }
  }

  @override
  Future<void> close() async {
    _countdown?.cancel();
    // Leaving the page by any other way than Keep must not leave an untried
    // calibration behind.
    try {
      await _revert();
    } on Object {
      // Nothing left to tell: the page is gone. The previous calibration is
      // still on /data for the next boot.
    }
    return super.close();
  }
}
