import 'dart:convert';

import 'package:equatable/equatable.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/control/binding/control_action.dart';
import 'package:segno/control/binding/external_pedal.dart';
import 'package:segno/control/binding/pedal_binding.dart';
import 'package:segno/control/binding/pedal_palette.dart';
import 'package:segno/looper/model/interaction_mode.dart';

/// What a HOLD on Record / Play does.
///
/// A closed list rather than the catalogue: Record / Play keeps its
/// immediate-contact press whatever is on its hold, so the hold can only
/// carry something that makes sense *after* the press has already fired.
enum RecordHold {
  /// Nothing. The switch is a plain contact again.
  none,

  /// Undo the take the press just started, or the track's latest layer.
  undoRecording;

  /// Parses a persisted [token]. An omitted value has the fresh default;
  /// an explicit unknown value is malformed rather than another action.
  static RecordHold fromToken(String? token) => token == null
      ? RecordHold.undoRecording
      : values.firstWhere(
          (value) => value.name == token,
          orElse: () => throw FormatException('Invalid recordHold: $token'),
        );
}

/// What a HOLD on one of the four track footswitches does.
///
/// Closed for the same reason as [RecordHold]: track selection keeps its
/// immediate-contact press, so the hold is an addition to it rather than an
/// alternative.
enum TrackHold {
  /// Nothing.
  none,

  /// Start overdubbing the held track — a no-op on a track with no loop yet,
  /// because "arm overdub" on empty would mean "record", and the press
  /// already covers that.
  armOverdub,

  /// Erase the held track's audio.
  clearTrack;

  /// Parses a persisted [token], rejecting explicit unknown actions.
  static TrackHold fromToken(String? token) => token == null
      ? TrackHold.armOverdub
      : values.firstWhere(
          (value) => value.name == token,
          orElse: () => throw FormatException('Invalid trackHold: $token'),
        );
}

/// One control's Press and Hold assignments.
///
/// Both halves are optional and independent. A pair with a [hold] moves its
/// press to the release, because until the threshold passes neither half is
/// known to be the one the foot meant; a pair without one presses on contact.
/// That rule lives in `ControlCubit`, where the gestures are; this is the
/// data it reads.
class ControlGesturePair extends Equatable {
  /// Creates a [ControlGesturePair].
  const ControlGesturePair({this.press, this.hold});

  /// Rebuilds a pair from its [toJson] map. Unknown action keys retain their
  /// exact identity as unavailable actions; malformed types are rejected.
  factory ControlGesturePair.fromJson(Map<String, dynamic> json) {
    final press = json['press'];
    final hold = json['hold'];
    if (json.containsKey('press') && (press is! String || press.isEmpty)) {
      throw const FormatException('Invalid custom Press');
    }
    if (json.containsKey('hold') && (hold is! String || hold.isEmpty)) {
      throw const FormatException('Invalid custom Hold');
    }
    return ControlGesturePair(
      press: press is String
          ? ControlAction.tryParse(press) ?? UnavailableAction(press)
          : null,
      hold: hold is String
          ? ControlAction.tryParse(hold) ?? UnavailableAction(hold)
          : null,
    );
  }

  /// The pair with nothing on either gesture.
  static const ControlGesturePair empty = ControlGesturePair();

  /// What a press does, or `null` when the press is unassigned.
  final ControlAction? press;

  /// What a hold does, or `null` when the switch carries only a press.
  final ControlAction? hold;

  /// Whether either gesture carries an action.
  bool get isEmpty => press == null && hold == null;

  /// Returns a copy with [press] replaced, `null` clearing it.
  ControlGesturePair withPress(ControlAction? press) =>
      ControlGesturePair(press: press, hold: hold);

  /// Returns a copy with [hold] replaced, `null` clearing it.
  ControlGesturePair withHold(ControlAction? hold) =>
      ControlGesturePair(press: press, hold: hold);

  /// Serializes this pair, omitting an unassigned half.
  Map<String, dynamic> toJson() => {
    if (press != null) 'press': press!.key,
    if (hold != null) 'hold': hold!.key,
  };

  @override
  List<Object?> get props => [press, hold];
}

/// The built-in footswitch setup: everything the accepted Pedals screen edits.
///
/// Two halves, because the accepted screen has two contexts.
///
/// **Track controls** is the fixed plate, with a few configurable gestures on
/// it: which mode MODE reaches with a press and with a hold, and what a hold
/// adds to Record / Play and to a track switch. Everything else there is
/// fixed and dimmed — Stop, Undo, Clear and Bank mean one thing, and the
/// design is explicit that they keep it.
///
/// **Custom controls** is the free map: eight switches, each with its own
/// Press and Hold drawn from the shared [ControlAction] catalogue. The four
/// track switches carry a pair PER BANK (the same [PedalBindingKey] rule the
/// FX remap uses); the four transport switches carry one pair whatever the
/// bank, because the accepted design says shared transport assignments do not
/// duplicate across banks.
///
/// Pure data: no cubit, repository or engine dependency, so the same value is
/// the settings payload and the thing `ControlCubit` dispatches against.
class PedalSetup extends Equatable {
  /// Creates a [PedalSetup].
  ///
  /// The defaults are the accepted ones: MODE presses to Mute, and its hold
  /// opens the Custom controls.
  const PedalSetup({
    this.modePress = InteractionMode.mute,
    this.modeHold = InteractionMode.custom,
    this.recordHold = RecordHold.undoRecording,
    this.trackHold = TrackHold.armOverdub,
    this.palette = const PedalPalette(),
    this.external = ExternalPedalSetup.empty,
  }) : custom = const <PedalBindingKey, ControlGesturePair>{};

  const PedalSetup._({
    required this.modePress,
    required this.modeHold,
    required this.recordHold,
    required this.trackHold,
    required this.custom,
    required this.palette,
    required this.external,
  });

  /// Rebuilds a setup from its [encode] string. Only an absent blob means a
  /// fresh setup; malformed explicit choices reject the whole stored setup.
  factory PedalSetup.decode(String encoded) {
    if (encoded.isEmpty) {
      throw const FormatException('Empty pedal setup');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(encoded);
    } on FormatException {
      throw const FormatException('Invalid pedal setup JSON');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Invalid pedal setup object');
    }
    final raw = decoded;
    final rawPalette = raw['palette'];
    if (raw.containsKey('palette') && rawPalette is! Map<String, dynamic>) {
      throw const FormatException('Invalid pedal palette');
    }
    final palette = rawPalette is Map<String, dynamic>
        ? PedalPalette.fromJson(rawPalette)
        : const PedalPalette();
    final rawExternal = raw['external'];
    if (raw.containsKey('external') && rawExternal is! Map<String, dynamic>) {
      throw const FormatException('Invalid external pedals');
    }
    final external = rawExternal is Map<String, dynamic>
        ? ExternalPedalSetup.fromJson(rawExternal)
        : ExternalPedalSetup.empty;
    final custom = <PedalBindingKey, ControlGesturePair>{};
    final entries = raw['custom'];
    if (raw.containsKey('custom') && entries is! List) {
      throw const FormatException('Invalid custom assignments');
    }
    if (entries is List) {
      for (final entry in entries) {
        if (entry is! Map<String, dynamic>) {
          throw const FormatException('Invalid custom assignment');
        }
        final rawBank = entry['bank'];
        if (entry.containsKey('bank') && rawBank is! int) {
          throw const FormatException('Invalid custom bank');
        }
        final key = PedalBindingKey.fromJson(entry);
        if (key == null || PedalBindingKey.unbindable.contains(key.button)) {
          throw const FormatException('Invalid custom button');
        }
        final pair = ControlGesturePair.fromJson(entry);
        if (pair.isEmpty || custom.containsKey(key)) {
          throw const FormatException('Invalid custom pair');
        }
        custom[key] = pair;
      }
    }
    String? optionalToken(String key) {
      final value = raw[key];
      if (raw.containsKey(key) && value is! String) {
        throw FormatException('Invalid $key');
      }
      return value as String?;
    }

    final modePress = optionalToken('modePress');
    final modeHold = optionalToken('modeHold');
    final pressMode = modePress == null
        ? InteractionMode.mute
        : _mode(modePress);
    final holdMode = modeHold == null ? null : _mode(modeHold);
    if (pressMode == null || (modeHold != null && holdMode == null)) {
      throw const FormatException('Invalid Mode action');
    }
    return PedalSetup._(
      modePress: pressMode,
      modeHold: holdMode,
      recordHold: RecordHold.fromToken(optionalToken('recordHold')),
      trackHold: TrackHold.fromToken(optionalToken('trackHold')),
      custom: Map.unmodifiable(custom),
      palette: palette,
      external: external,
    );
  }

  /// The modes MODE can be assigned to reach.
  ///
  /// Every mode a foot can enter. `record` is in it because the accepted
  /// catalogue's `Exit` IS the Tracks mode, and a MODE press assigned to it
  /// is how a performer who never uses Mute keeps one switch that always
  /// goes home.
  static const List<InteractionMode> modeChoices = InteractionMode.values;

  /// Which mode a MODE press reaches — or leaves, when the rig is already in
  /// it. Never null: the switch always means something.
  final InteractionMode modePress;

  /// Which mode a MODE hold reaches, or `null` when MODE carries no hold.
  final InteractionMode? modeHold;

  /// What a Record / Play hold does.
  final RecordHold recordHold;

  /// What a track-switch hold does. One setting for all four switches: the
  /// accepted design edits them as one group.
  final TrackHold trackHold;

  /// The Custom-controls map, keyed exactly like the FX remap.
  final Map<PedalBindingKey, ControlGesturePair> custom;

  /// Per-physical-switch LED hues, shared across both action banks.
  final PedalPalette palette;

  /// Both external CTRL jacks, retained with their inactive type settings.
  final ExternalPedalSetup external;

  /// The pair on [button] within [bank], or [ControlGesturePair.empty].
  ///
  /// [bank] is consulted only for a bank-keyed control, so a caller can pass
  /// the live bank unconditionally.
  ControlGesturePair customFor(PedalButton button, {required int bank}) =>
      custom[PedalBindingKey(
        button: button,
        bank: PedalBindingKey.isBankKeyed(button) ? bank : null,
      )] ??
      ControlGesturePair.empty;

  /// Whether any Custom control carries an assignment — what enables the
  /// accepted Clear custom assignments action.
  bool get hasCustomAssignments => custom.values.any((p) => !p.isEmpty);

  /// Returns a copy with [pair] on [button] within [bank]; an empty pair
  /// removes the entry, so a cleared switch and a never-touched one encode
  /// identically.
  PedalSetup withCustom(
    PedalButton button, {
    required int bank,
    required ControlGesturePair pair,
  }) {
    if (PedalBindingKey.unbindable.contains(button)) return this;
    final key = PedalBindingKey(
      button: button,
      bank: PedalBindingKey.isBankKeyed(button) ? bank : null,
    );
    final next = {...custom};
    if (pair.isEmpty) {
      next.remove(key);
    } else {
      next[key] = pair;
    }
    return copyWith(custom: Map.unmodifiable(next));
  }

  /// The setup with every Custom assignment gone, on both banks and both
  /// gestures, and the fixed Track controls untouched.
  PedalSetup clearedCustom() =>
      copyWith(custom: const <PedalBindingKey, ControlGesturePair>{});

  /// Returns a copy with the given fields replaced.
  ///
  /// [clearModeHold] drops the MODE hold, which `modeHold: null` cannot
  /// express.
  PedalSetup copyWith({
    InteractionMode? modePress,
    InteractionMode? modeHold,
    RecordHold? recordHold,
    TrackHold? trackHold,
    Map<PedalBindingKey, ControlGesturePair>? custom,
    PedalPalette? palette,
    ExternalPedalSetup? external,
    bool clearModeHold = false,
  }) => PedalSetup._(
    modePress: modePress ?? this.modePress,
    modeHold: clearModeHold ? null : modeHold ?? this.modeHold,
    recordHold: recordHold ?? this.recordHold,
    trackHold: trackHold ?? this.trackHold,
    custom: Map.unmodifiable(custom ?? this.custom),
    palette: palette ?? this.palette,
    external: external ?? this.external,
  );

  /// The canonical encoding. Byte-stable for equal setups — the Custom
  /// entries are ordered by control, so a map that changed only in iteration
  /// order never looks like an edit.
  String encode() => jsonEncode({
    'modePress': ModeAction(modePress).token,
    if (modeHold != null) 'modeHold': ModeAction(modeHold!).token,
    'recordHold': recordHold.name,
    'trackHold': trackHold.name,
    if (custom.isNotEmpty)
      'custom': [
        for (final key in _orderedCustomKeys())
          {...key.toJson(), ...custom[key]!.toJson()},
      ],
    if (!palette.isEmpty) 'palette': palette.toJson(),
    if (!external.isEmpty) 'external': external.toJson(),
  });

  List<PedalBindingKey> _orderedCustomKeys() {
    final keys = custom.keys.toList()
      ..sort((a, b) {
        final button = a.button.index.compareTo(b.button.index);
        if (button != 0) return button;
        return (a.bank ?? -1).compareTo(b.bank ?? -1);
      });
    return keys;
  }

  static InteractionMode? _mode(Object? raw) {
    if (raw is! String) return null;
    final action = ControlAction.tryParse('mode:$raw');
    return action is ModeAction ? action.mode : null;
  }

  @override
  List<Object?> get props => [
    modePress,
    modeHold,
    recordHold,
    trackHold,
    palette,
    external,
    // An ORDERED flattening of the map, not the map itself: two setups built
    // in different insertion orders must compare equal, which a Map does not
    // promise through Equatable. Not the encoding either — this is compared
    // whenever a fresh setup reaches the state, and encoding JSON to answer
    // "did it change" is work the answer does not need.
    for (final key in _orderedCustomKeys()) ...[
      key,
      custom[key]!.press,
      custom[key]!.hold,
    ],
  ];
}
