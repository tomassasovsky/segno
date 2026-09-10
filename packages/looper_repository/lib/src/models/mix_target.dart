import 'dart:convert';

import 'package:equatable/equatable.dart';

/// What a mix parameter belongs to (accepted design, slice 3). A track's
/// playback level is not here: `TrackVolumeTarget` (the control value
/// targets) already names it and saved bindings carry that form.
enum MixTargetKind {
  /// A recorded track's pan.
  trackPan,

  /// A live input's monitor level.
  inputLevel,

  /// A mono live input's pan.
  inputPan,

  /// A stereo input pair's balance, addressed by the pair's lower member.
  pairBalance;

  /// The kind named [name], or `null`.
  static MixTargetKind? fromName(String? name) {
    for (final kind in values) {
      if (kind.name == name) return kind;
    }
    return null;
  }
}

/// A typed identity for one mix parameter: the target later assignments
/// (pedal, expression, MIDI) bind to, beside the effect address `FxAddress`.
///
/// [canonicalString] is the persisted form: a JSON object with the fixed key
/// order `target`, `index`, no whitespace, so the same target always encodes
/// to the same string and string equality is identity. Fields are
/// additive-only: [fromJson] ignores keys it does not know and never throws
/// on a wrong-typed field. The same shape as `FxAddress` ([fromJson],
/// [tryParse], [canonicalString]) so one dispatcher can decode both.
class MixTarget extends Equatable {
  /// Creates a [MixTarget].
  const MixTarget({required this.kind, required this.index});

  /// Track [channel]'s pan.
  const MixTarget.trackPan(int channel)
    : this(kind: MixTargetKind.trackPan, index: channel);

  /// Live input [input]'s monitor level.
  const MixTarget.inputLevel(int input)
    : this(kind: MixTargetKind.inputLevel, index: input);

  /// Mono live input [input]'s pan.
  const MixTarget.inputPan(int input)
    : this(kind: MixTargetKind.inputPan, index: input);

  /// The balance of the pair whose lower member is [input].
  const MixTarget.pairBalance(int input)
    : this(kind: MixTargetKind.pairBalance, index: input);

  /// Rebuilds a [MixTarget] from its [toJson] map, or `null` when the map
  /// does not name one.
  static MixTarget? fromJson(Map<String, dynamic> json) {
    final raw = json['target'];
    final kind = MixTargetKind.fromName(raw is String ? raw : null);
    final index = json['index'];
    if (kind == null || index is! int) return null;
    return MixTarget(kind: kind, index: index);
  }

  /// Parses a [canonicalString], or `null` when it is not one.
  static MixTarget? tryParse(String canonical) {
    try {
      final decoded = jsonDecode(canonical);
      return decoded is Map<String, dynamic> ? fromJson(decoded) : null;
    } on FormatException {
      return null;
    }
  }

  /// The parameter's owner kind.
  final MixTargetKind kind;

  /// The track channel or hardware input the parameter belongs to.
  final int index;

  /// The persisted form; see the class doc.
  Map<String, dynamic> toJson() => {'target': kind.name, 'index': index};

  /// The byte-stable string form of [toJson].
  String canonicalString() => jsonEncode(toJson());

  @override
  List<Object?> get props => [kind, index];
}
