import 'dart:math' as math;

import 'package:equatable/equatable.dart';

/// The lowest capture trim, in dB (accepted design, Audio routing).
const double kMinInputTrimDb = -24;

/// The highest capture trim, in dB.
const double kMaxInputTrimDb = 12;

/// The trim step, in dB.
const double kInputTrimStepDb = 0.5;

/// The per-input capture setup the accepted Audio routing pages edit
/// (Mono input · Pan & trim, Stereo pair · Balance & trim): appliance-wide
/// like the input names, saved with a session and carried into New Loop.
///
/// Inputs are hardware channels, `0`-based. A stereo pair is two adjacent
/// jacks, the even lower one Left and the odd upper one Right (jacks 1/2,
/// 3/4 ... 17/18 in the pen's numbering); [pairs] holds the lower member of
/// every pair with the pair's balance. A paired input has no pan of its own:
/// the pair's balance attenuates one side relative to the other, and each
/// member keeps its own trim. Unlinking restores the members' former pans.
class InputSetup extends Equatable {
  /// Creates an [InputSetup].
  const InputSetup({
    this.trimDb = const {},
    this.pan = const {},
    this.pairs = const {},
  });

  /// Capture trim per input, in dB (absent = unity). Clamped to
  /// [kMinInputTrimDb]..[kMaxInputTrimDb] by the repository.
  final Map<int, double> trimDb;

  /// Pan per mono input, `-1` (left) .. `1` (right) (absent = centre). Kept
  /// for a paired input too, so unlinking brings it back.
  final Map<int, double> pan;

  /// The balance of every stereo pair, keyed by the pair's lower (Left)
  /// member: `-1` favours Left, `1` favours Right, `0` is even.
  final Map<int, double> pairs;

  /// The lower member of the pair [input] belongs to, or `null` when it is a
  /// mono input.
  int? pairOf(int input) {
    final lower = input.isEven ? input : input - 1;
    return pairs.containsKey(lower) ? lower : null;
  }

  /// Whether [input] is the Left (lower) member of a pair.
  bool isPairLeft(int input) => input.isEven && pairs.containsKey(input);

  /// Whether [input] is the Right (upper) member of a pair.
  bool isPairRight(int input) => input.isOdd && pairs.containsKey(input - 1);

  /// [input]'s trim in dB, unity when unset.
  double trimDbOf(int input) => trimDb[input] ?? 0;

  /// [input]'s pan, centre when unset.
  double panOf(int input) => pan[input] ?? 0;

  /// The balance of the pair [input] belongs to, even when unset or mono.
  double balanceOf(int input) {
    final lower = pairOf(input);
    return lower == null ? 0 : pairs[lower] ?? 0;
  }

  /// Where [input]'s signal sits in the stereo image as the engine is told
  /// it: a pair member is hard on its own side, a mono input follows its pan.
  double effectivePanOf(int input) {
    if (isPairLeft(input)) return -1;
    if (isPairRight(input)) return 1;
    return panOf(input);
  }

  /// The gain the pair's balance gives [input]'s side: the favoured side
  /// stays at unity and the other falls on the same quarter-sine as the
  /// engine's pan law, so a balance of `1` silences Left. `1` for a mono
  /// input.
  double balanceGainOf(int input) {
    final lower = pairOf(input);
    if (lower == null) return 1;
    final balance = (pairs[lower] ?? 0).clamp(-1.0, 1.0);
    final left = input == lower;
    final far = left ? math.max(balance, 0) : math.max(-balance, 0);
    return far >= 1 ? 0 : math.cos(far * math.pi / 2);
  }

  /// A copy with [input]'s trim at [db] (unity drops the entry).
  InputSetup withTrim(int input, double db) {
    final trims = Map<int, double>.of(trimDb);
    if (db == 0) {
      trims.remove(input);
    } else {
      trims[input] = db;
    }
    return copyWith(trimDb: trims);
  }

  /// A copy with mono [input]'s pan at [pan] (centre drops the entry).
  InputSetup withPan(int input, double pan) {
    final pans = Map<int, double>.of(this.pan);
    if (pan == 0) {
      pans.remove(input);
    } else {
      pans[input] = pan;
    }
    return copyWith(pan: pans);
  }

  /// A copy with the pair whose lower member is [input] linked (at an even
  /// balance, or the balance it had) or unlinked.
  InputSetup withPair(int input, {required bool paired}) {
    final next = Map<int, double>.of(pairs);
    if (paired) {
      next.putIfAbsent(input, () => 0);
    } else {
      next.remove(input);
    }
    return copyWith(pairs: next);
  }

  /// A copy with the pair whose lower member is [input] at [balance].
  InputSetup withBalance(int input, double balance) =>
      copyWith(pairs: Map<int, double>.of(pairs)..[input] = balance);

  /// Returns a copy with the given overrides.
  InputSetup copyWith({
    Map<int, double>? trimDb,
    Map<int, double>? pan,
    Map<int, double>? pairs,
  }) => InputSetup(
    trimDb: trimDb ?? this.trimDb,
    pan: pan ?? this.pan,
    pairs: pairs ?? this.pairs,
  );

  @override
  List<Object?> get props => [trimDb, pan, pairs];
}

/// The linear capture gain for a trim of [db] decibels.
double inputTrimGainOfDb(double db) => math.pow(10, db / 20).toDouble();
