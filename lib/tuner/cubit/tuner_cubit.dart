import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/tuner/application/tuner_settings.dart';
import 'package:segno/tuner/pitch.dart';

part 'tuner_state.dart';

/// Owns the tuner reading: which input it is for, and what the engine is
/// currently hearing on it, named against the stored A4 reference.
///
/// The input and the reference are appliance preferences in [TunerSettings];
/// this cubit follows them. It never arms the engine: the foot Tuner mode
/// does (Control, #1229), and a reading for any other input, or none, reads
/// as nothing.
///
/// The cubit holds the last confident reading for a short decay rather than
/// following the engine frame for frame. A plucked string is periodic for a
/// moment and then is not, so a needle wired straight to the snapshot would
/// snap back to "no signal" between picks — the reading is what the player
/// last played, until it is old enough not to be.
class TunerCubit extends Cubit<TunerState> {
  /// Creates a [TunerCubit] following [repository] and [settings].
  TunerCubit({
    required LooperRepository repository,
    required TunerSettings settings,
  }) : _repository = repository,
       _settings = settings,
       super(
         TunerState(
           input: settings.live.input < 0 ? 0 : settings.live.input,
           referenceHz: settings.live.referenceHz,
         ),
       ) {
    _subscription = _repository.looperState.listen(_onLooperState);
    _settingsSubscription = _settings.changes.listen(_onPreferences);
  }

  final LooperRepository _repository;
  final TunerSettings _settings;
  late final StreamSubscription<LooperState> _subscription;
  late final StreamSubscription<TunerPreferences> _settingsSubscription;

  /// How long a confident reading survives without a fresh one.
  ///
  /// Long enough to ride out the gap between picks and the decay of a note,
  /// short enough that walking away from the instrument clears the display
  /// rather than leaving a stale note on screen.
  static const Duration holdFor = Duration(milliseconds: 1200);

  /// Below this, a frame is too aperiodic to believe. Picked to match the
  /// engine's own voiced/unvoiced threshold rather than a second opinion.
  static const double minConfidence = 0.5;

  /// Releases a held reading once [holdFor] has passed with nothing fresh.
  ///
  /// A timer rather than a count of frames: [LooperRepository] only emits when
  /// the projected state CHANGES, so on a still rig (transport stopped, silent
  /// input) the "no pitch" frame arrives exactly once and no amount of counting
  /// would ever reach the end of the hold. The note would then sit on screen
  /// forever, which is the one thing the hold exists to prevent.
  Timer? _holdTimer;

  void _onPreferences(TunerPreferences preferences) {
    if (isClosed) return;
    if (preferences.referenceHz != state.referenceHz) {
      // A held reading is renamed against the new reference at once.
      final pitch = state.hz > 0
          ? pitchFromHz(state.hz, reference: preferences.referenceHz.toDouble())
          : null;
      emit(
        state.copyWith(
          referenceHz: preferences.referenceHz,
          pitch: pitch,
          clearPitch: pitch == null,
        ),
      );
    }
    final status = _repository.state.status;
    _follow(
      _tunableInput(
        preferences.input,
        status.inputChannels,
        status.excludedInputMask,
      ),
    );
  }

  /// Moves to [input]: the reading belonged to the input left behind.
  void _follow(int input) {
    if (input == state.input) return;
    emit(state.copyWith(input: input, hz: 0, clearPitch: true));
    _cancelHold();
  }

  /// The input to actually listen on: [wanted] when this rig has it and it is
  /// worth tuning, else the first channel that is, else `-1`.
  ///
  /// Two things disqualify a channel. It may simply not exist — a selection
  /// carried over from a wider interface, which the engine DISARMS rather than
  /// clamps, so leaving it would sit dead. Or it may be a loopback capture,
  /// which carries the console's own output back: the engine's tuner tap does
  /// not filter those, so tuning one would report the pitch of the loop that
  /// is playing as though something were plugged into that socket. Neither is
  /// positional — the loopback mask comes from per-channel NAMES, so a virtual
  /// device can have channel 0 excluded and an all-loopback device every
  /// channel — which is why this resolves rather than clamps.
  static int _tunableInput(int wanted, int channels, int excluded) {
    // Nothing known yet (no device open): leave the choice alone rather than
    // resolving it against a rig that has not been reported. "The first
    // available" is the first socket until the rig says otherwise.
    if (channels <= 0) return wanted < 0 ? 0 : wanted;
    bool tunable(int input) =>
        input >= 0 && input < channels && excluded & (1 << input) == 0;
    if (tunable(wanted)) return wanted;
    for (var input = 0; input < channels; input++) {
      if (tunable(input)) return input;
    }
    return -1;
  }

  void _onLooperState(LooperState looper) {
    // Fold a selection this rig cannot tune onto one it can, the moment the
    // rig says so — see [_tunableInput] for what disqualifies a channel. `-1`
    // when there is nothing worth tuning at all, which disarms the engine
    // rather than leaving it on a loopback.
    final wanted = _tunableInput(
      _settings.live.input,
      looper.status.inputChannels,
      looper.status.excludedInputMask,
    );
    if (wanted != state.input) {
      // This frame's reading belongs to the input we just left, so there is
      // nothing here worth reading. The stored preference is untouched: the
      // folded input is this rig's answer, not the player's choice.
      _follow(wanted);
      return;
    }

    final reading = looper.tuner;

    // Draw only what the engine heard on the input we are actually showing. A
    // snapshot polled between a tab tap and the engine consuming the switch
    // still carries the PREVIOUS input's pitch: it belongs to another input,
    // so it is cleared at once rather than held as "no signal" (#1229).
    //
    // A disarmed tuner reports input -1, which never matches: closing the
    // mode clears the reading. Nothing is pushed back on a mismatch: the
    // foot Tuner owns arming, and every `setTunerInput` also clears its
    // input mute (#1229, D12).
    if (reading.input != state.input) {
      _cancelHold();
      if (state.pitch != null || state.hz != 0 || state.isStale) {
        emit(state.copyWith(hz: 0, clearPitch: true, isStale: false));
      }
      return;
    }

    if (reading.hasPitch && reading.confidence >= minConfidence) {
      _cancelHold();
      emit(
        state.copyWith(
          hz: reading.hz,
          pitch: pitchFromHz(
            reading.hz,
            reference: state.referenceHz.toDouble(),
          ),
          isStale: false,
        ),
      );
      return;
    }

    // No usable pitch this frame. Hold what was last heard until the hold
    // expires, then clear — a needle that keeps pointing at a note nobody is
    // playing is worse than one that admits it has nothing.
    if (state.pitch == null) return;
    if (!state.isStale) emit(state.copyWith(isStale: true));
    _holdTimer ??= Timer(holdFor, _releaseHold);
  }

  void _releaseHold() {
    _holdTimer = null;
    if (state.pitch == null) return;
    emit(state.copyWith(hz: 0, clearPitch: true, isStale: false));
  }

  void _cancelHold() {
    _holdTimer?.cancel();
    _holdTimer = null;
  }

  @override
  Future<void> close() {
    _cancelHold();
    unawaited(_subscription.cancel());
    unawaited(_settingsSubscription.cancel());
    return super.close();
  }
}
