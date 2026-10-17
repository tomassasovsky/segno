import 'package:backing_repository/backing_repository.dart';
import 'package:equatable/equatable.dart';

/// One field of [BackingMix]: the address an edit writes, so a level edit
/// never supersedes a pan controller (#1200 Part 5).
enum BackingMixField {
  /// The gain.
  level,

  /// The balance.
  pan,

  /// The output channel mask.
  output,

  /// What happens at the loaded file's end.
  end,
}

/// The backing's level, pan, output channels and End: the one record the
/// backing mix family stores and a Session carries (plan D9).
class BackingMix extends Equatable {
  /// Creates a [BackingMix]; the defaults are a silent, unrouted backing that
  /// stops at its end.
  const BackingMix({
    this.level = 1,
    this.pan = 0,
    this.outputMask = 0,
    this.end = BackingEnd.stop,
  });

  /// Reads the stored record strictly; throws [FormatException] otherwise.
  factory BackingMix.fromJson(Object? json) {
    const keys = {'level', 'pan', 'outputMask', 'end'};
    if (json is! Map<String, dynamic> ||
        json.length != keys.length ||
        !json.keys.every(keys.contains)) {
      throw const FormatException('invalid backing mix');
    }
    final level = json['level'];
    final pan = json['pan'];
    final mask = json['outputMask'];
    final end = json['end'];
    if (level is! num || pan is! num || mask is! int || end is! String) {
      throw const FormatException('invalid backing mix');
    }
    final mix = BackingMix(
      level: level.toDouble(),
      pan: pan.toDouble(),
      outputMask: mask,
      end: BackingEnd.values.firstWhere(
        (mode) => mode.name == end,
        orElse: () => throw FormatException('invalid backing End', end),
      ),
    );
    if (!mix.isValid) throw const FormatException('invalid backing mix');
    return mix;
  }

  /// The defaults.
  static const BackingMix defaults = BackingMix();

  /// Gain, `0..2`.
  final double level;

  /// Balance, `-1..1`.
  final double pan;

  /// The output channels it sounds on; 0 is none.
  final int outputMask;

  /// What happens at the loaded file's end.
  final BackingEnd end;

  /// Every value in range.
  bool get isValid =>
      level.isFinite &&
      level >= 0 &&
      level <= 2 &&
      pan.isFinite &&
      pan >= -1 &&
      pan <= 1 &&
      outputMask >= 0 &&
      outputMask <= 0xffffffff;

  /// This mix with [field] taken from [other].
  BackingMix withField(BackingMixField field, BackingMix other) =>
      switch (field) {
        BackingMixField.level => copyWith(level: other.level),
        BackingMixField.pan => copyWith(pan: other.pan),
        BackingMixField.output => copyWith(outputMask: other.outputMask),
        BackingMixField.end => copyWith(end: other.end),
      };

  /// A copy with the given fields replaced.
  BackingMix copyWith({
    double? level,
    double? pan,
    int? outputMask,
    BackingEnd? end,
  }) => BackingMix(
    level: level ?? this.level,
    pan: pan ?? this.pan,
    outputMask: outputMask ?? this.outputMask,
    end: end ?? this.end,
  );

  /// The stored record.
  Map<String, dynamic> toJson() => {
    'level': level,
    'pan': pan,
    'outputMask': outputMask,
    'end': end.name,
  };

  @override
  List<Object?> get props => [level, pan, outputMask, end];
}
