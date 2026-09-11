import 'dart:convert';

import 'package:equatable/equatable.dart';

/// The FX stages of the signal path, in signal order.
///
/// Every effects chain in the app lives at exactly one stage; an [FxAddress]
/// names one chain by stage + coordinates.
enum FxStage {
  /// A hardware input's live-monitor chain. Its Pre entries are what a take
  /// records; its Post entries are copied onto the lane at record.
  input,

  /// A lane's record-route (loop playback) chain — one recorded part.
  loop,

  /// A track's stereo-bus chain, downstream of its lanes.
  track,

  /// The All tracks chain, over the sum of the recorded tracks. Not an output
  /// bus: live inputs, backing and click are not in this sum.
  allTracks,

  /// One output destination's post-sum chain — the true output stage, over
  /// every source actually routed to that destination.
  output;

  /// Maps a canonical wire [name] back to a stage, or `null` when unknown.
  static FxStage? fromName(String? name) {
    for (final stage in values) {
      if (stage.name == name) return stage;
    }
    return null;
  }
}

/// The address of one effects chain in the FX model (A9/R19):
/// `{stage, index, lane?}`.
///
/// Per-stage field meaning:
///
/// - [FxStage.input]: [index] is the hardware input channel; [lane] is unused
///   and must be null.
/// - [FxStage.loop]: [index] is the track channel; [lane] is the lane within
///   that track (required to name one chain, since every lane owns one).
/// - [FxStage.track]: [index] is the track channel; [lane] is unused (null).
/// - [FxStage.allTracks]: there is exactly one such chain — [index] is `0`
///   and [lane] is null.
/// - [FxStage.output]: [index] is the output destination (bus); [lane] is
///   unused (null).
///
/// The `master` stage of the four-stage model is gone: an output chain is
/// per destination from slice 3f, so the one chain that stage named is the
/// [FxStage.output] address at bus 0. A persisted binding still saying
/// `master` decodes to `null` and goes inert rather than retargeting itself
/// at a destination its author never chose.
///
/// ## Canonical JSON (the single declaration — R19)
///
/// [canonicalString] is THE serialization pedal bindings (part 6) and
/// expression mappings (part 7) persist and compare: a JSON object with the
/// fixed key order `stage`, `index`, `lane`, where `stage` is the enum name
/// and an absent [lane] is OMITTED (never null-valued). No whitespace beyond
/// `jsonEncode`'s none. Byte-stable: the same address always encodes to the
/// same string, so plain string equality == target identity, and the string
/// crosses the `controller_repository` / `pedal_repository` boundary without
/// those packages gaining a looper dependency.
///
/// Compatibility contract: fields are additive-only — a future revision may
/// add keys, and [FxAddress.fromJson] ignores keys it does not know, so an
/// older build can still decode a newer address. Existing keys never change
/// meaning or order.
class FxAddress extends Equatable {
  /// Creates an [FxAddress]. See the class doc for per-stage field meaning.
  const FxAddress({required this.stage, this.index = 0, this.lane});

  /// Rebuilds an [FxAddress] from its [toJson] map. Unknown keys are ignored
  /// (additive-only contract); an unknown or missing `stage` yields `null`.
  /// Wrong-TYPED fields never throw — a corrupt persisted binding string must
  /// decode to `null`, not a TypeError, since parts 6/7 feed this parser
  /// strings that crossed package boundaries and app restarts.
  static FxAddress? fromJson(Map<String, dynamic> json) {
    final rawStage = json['stage'];
    final stage = FxStage.fromName(rawStage is String ? rawStage : null);
    if (stage == null) return null;
    final index = json['index'];
    final lane = json['lane'];
    return FxAddress(
      stage: stage,
      index: index is num ? index.toInt() : 0,
      lane: lane is num ? lane.toInt() : null,
    );
  }

  /// Parses a [canonicalString] (or any JSON-object encoding of one) back to
  /// an address, or `null` when the string is not a decodable address.
  static FxAddress? tryParse(String encoded) {
    try {
      final raw = jsonDecode(encoded);
      if (raw is! Map<String, dynamic>) return null;
      return fromJson(raw);
    } on FormatException {
      return null;
    }
  }

  /// The stage this address names a chain on.
  final FxStage stage;

  /// The stage-scoped coordinate: input channel for [FxStage.input], track
  /// channel for [FxStage.loop] / [FxStage.track], output destination for
  /// [FxStage.output], `0` for [FxStage.allTracks].
  final int index;

  /// The lane within track [index] — only meaningful for [FxStage.loop];
  /// null for every other stage.
  final int? lane;

  /// The canonical JSON map: fixed key order `stage`, `index`, `lane`; an
  /// absent [lane] is omitted, never null-valued.
  Map<String, dynamic> toJson() => {
    'stage': stage.name,
    'index': index,
    if (lane != null) 'lane': lane,
  };

  /// The byte-stable canonical serialization (see the class doc). Equal
  /// addresses always produce identical strings, so string equality is
  /// target identity for binding/mapping consumers.
  String canonicalString() => jsonEncode(toJson());

  /// Returns a copy with the given fields replaced. [lane] cannot be cleared
  /// back to null through this (construct a fresh address instead) — no
  /// current caller needs that, and an accidental clear would silently change
  /// which chain a loop-stage address names.
  FxAddress copyWith({FxStage? stage, int? index, int? lane}) => FxAddress(
    stage: stage ?? this.stage,
    index: index ?? this.index,
    lane: lane ?? this.lane,
  );

  @override
  List<Object?> get props => [stage, index, lane];
}
