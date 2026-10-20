import 'package:equatable/equatable.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/control/binding/pedal_binding.dart';
import 'package:segno/looper/model/interaction_mode.dart';

/// The pedals a mode colours as one unit. The four track switches are one
/// group: they share a colour per state, whichever track or bank they show.
enum PedalLedGroup {
  /// Track 1-4.
  tracks,

  /// Record / Play.
  recPlay,

  /// Stop.
  stop,

  /// Undo.
  undo,

  /// Clear.
  clear,

  /// MODE.
  mode,

  /// Bank.
  bank,
}

/// What a lit pedal is showing. Which of these a group can show depends on
/// the mode; [PedalLedMap.schema] is that list.
enum PedalLedState {
  /// Capturing a first pass.
  recording,

  /// Summing into an existing loop.
  overdubbing,

  /// A loop is playing.
  playing,

  /// The selected track (Record cursor, Multiply/Divide target, Mixer
  /// channel).
  selected,

  /// Mute mode: armed and audible.
  armed,

  /// FX mode: the chain or binding behind the switch is on.
  engaged,

  /// Fade mode: fading or faded out.
  fading,

  /// Reverse mode: playing reversed.
  reversed,

  /// Peel mode: a press would remove a layer.
  peelable,

  /// Tuner mode: the input being tuned.
  tuned,

  /// Tuner mode: the tuned input is muted.
  muted,

  /// Rec/Play lit with no loop running (performance recording armed, or a
  /// bound FX target engaged).
  idle,

  /// MODE: the mode it is in. MODE is always lit.
  current,

  /// Bank: bank B, or a later Tuner page.
  laterBank,

  /// Custom mode: the pedal's assigned function is active.
  lit,

  /// The pedal is held. Every press lights its pedal at once, MODE included.
  pressed,
}

/// The pedal's original LED colours: pure channels, not the screen palette's
/// tints, which read washed out on an LED. The console board applies gamma.
const PedalColor ledRed = PedalColor(255, 0, 0);

/// Playing; Mute mode.
const PedalColor ledGreen = PedalColor(0, 255, 0);

/// An engaged FX chain; FX mode.
const PedalColor ledBlue = PedalColor(0, 0, 255);

/// MODE in every mode but Record, Mute and FX.
const PedalColor ledYellow = PedalColor(255, 235, 0);

/// Bank B.
const PedalColor ledBankB = PedalColor(0, 0, 80);

/// A lit pedal with no hue of its own, and the press flash.
const PedalColor ledWhite = PedalColor.defaultColor;

/// One colour override, addressed by mode, group and state.
typedef PedalLedSlot = ({
  InteractionMode mode,
  PedalLedGroup group,
  PedalLedState state,
});

/// One Custom-mode pedal colour, addressed by assignment and state.
typedef CustomLedSlot = ({PedalBindingKey key, PedalLedState state});

/// The pedal LED colour map: per mode, per group, per state, plus a colour
/// per Custom-assignable pedal assignment.
///
/// Stores only what differs from the defaults, which are the pedal's original
/// colours, so a fresh map lights exactly as the pedal always did and a reset
/// is the removal of overrides.
class PedalLedMap extends Equatable {
  /// The defaults, with nothing overridden.
  const PedalLedMap()
    : modes = const <PedalLedSlot, PedalColor>{},
      custom = const <CustomLedSlot, PedalColor>{};

  PedalLedMap._(
    Map<PedalLedSlot, PedalColor> modes,
    Map<CustomLedSlot, PedalColor> custom,
  ) : modes = Map.unmodifiable(modes),
      custom = Map.unmodifiable(custom);

  /// Builds a map from overrides, dropping any equal to its default. Rejects
  /// a slot the mode does not have and a Custom colour on MODE or Bank.
  factory PedalLedMap.fromMaps({
    Map<PedalLedSlot, PedalColor> modes = const {},
    Map<CustomLedSlot, PedalColor> custom = const {},
  }) {
    final keptModes = <PedalLedSlot, PedalColor>{};
    for (final MapEntry(:key, :value) in modes.entries) {
      final fallback = schema(key.mode)[key.group]?[key.state];
      if (fallback == null) {
        throw const FormatException('Invalid pedal LED slot');
      }
      if (value != fallback) keptModes[key] = value;
    }
    final keptCustom = <CustomLedSlot, PedalColor>{};
    for (final MapEntry(:key, :value) in custom.entries) {
      if (PedalBindingKey.unbindable.contains(key.key.button) ||
          !customStates.contains(key.state)) {
        throw const FormatException('Invalid custom pedal LED slot');
      }
      if (value != ledWhite) keptCustom[key] = value;
    }
    return PedalLedMap._(keptModes, keptCustom);
  }

  /// Rebuilds a map from its [toJson] form, rejecting anything malformed.
  factory PedalLedMap.fromJson(Map<String, dynamic> json) {
    if (json.keys.any((key) => key != 'modes' && key != 'custom')) {
      throw const FormatException('Unknown pedal LED field');
    }
    final modes = <PedalLedSlot, PedalColor>{};
    final rawModes = json['modes'];
    if (json.containsKey('modes')) {
      if (rawModes is! Map<String, dynamic>) {
        throw const FormatException('Invalid pedal LED modes');
      }
      for (final modeEntry in rawModes.entries) {
        final mode = _byName(InteractionMode.values, modeEntry.key);
        final groups = modeEntry.value;
        if (mode == null || groups is! Map<String, dynamic>) {
          throw const FormatException('Invalid pedal LED mode');
        }
        for (final groupEntry in groups.entries) {
          final group = _byName(PedalLedGroup.values, groupEntry.key);
          final states = groupEntry.value;
          if (group == null || states is! Map<String, dynamic>) {
            throw const FormatException('Invalid pedal LED group');
          }
          for (final stateEntry in states.entries) {
            final state = _byName(PedalLedState.values, stateEntry.key);
            if (state == null) {
              throw const FormatException('Invalid pedal LED state');
            }
            modes[(mode: mode, group: group, state: state)] = _color(
              stateEntry.value,
            );
          }
        }
      }
    }
    final custom = <CustomLedSlot, PedalColor>{};
    final rawCustom = json['custom'];
    if (json.containsKey('custom')) {
      if (rawCustom is! List) {
        throw const FormatException('Invalid custom pedal LEDs');
      }
      for (final item in rawCustom) {
        if (item is! Map<String, dynamic>) {
          throw const FormatException('Invalid custom pedal LED');
        }
        final key = PedalBindingKey.fromJson(item);
        if (key == null ||
            item.keys.any(
              (k) =>
                  k != 'button' &&
                  k != 'bank' &&
                  !customStates.any((state) => state.name == k),
            )) {
          throw const FormatException('Invalid custom pedal LED');
        }
        for (final state in customStates) {
          if (!item.containsKey(state.name)) continue;
          final slot = (key: key, state: state);
          if (custom.containsKey(slot)) {
            throw const FormatException('Duplicate custom pedal LED');
          }
          custom[slot] = _color(item[state.name]);
        }
      }
    }
    return PedalLedMap.fromMaps(modes: modes, custom: custom);
  }

  /// The states a Custom-assignable pedal is coloured for.
  static const List<PedalLedState> customStates = [
    PedalLedState.lit,
    PedalLedState.pressed,
  ];

  /// Every group [mode] lights and, for each, the states it can show with
  /// their default colours, in the order the editor lists them.
  ///
  /// The defaults are the pedal's original colours. A held pedal lights in
  /// its group's [PedalLedState.pressed] colour: white, except Clear, which
  /// was always red while held.
  static Map<PedalLedGroup, Map<PedalLedState, PedalColor>> schema(
    InteractionMode mode,
  ) => _schemas[mode]!;

  static final Map<
    InteractionMode,
    Map<PedalLedGroup, Map<PedalLedState, PedalColor>>
  >
  _schemas = {for (final mode in InteractionMode.values) mode: _build(mode)};

  static Map<PedalLedGroup, Map<PedalLedState, PedalColor>> _build(
    InteractionMode mode,
  ) {
    const pressed = {PedalLedState.pressed: ledWhite};
    final modeLed = {
      PedalLedState.current: switch (mode) {
        InteractionMode.record => ledRed,
        InteractionMode.mute => ledGreen,
        InteractionMode.fx => ledBlue,
        _ => ledYellow,
      },
      ...pressed,
    };
    const bank = {PedalLedState.laterBank: ledBankB, ...pressed};
    if (mode == InteractionMode.custom) {
      // Every other switch takes its colour from its own assignment.
      return {PedalLedGroup.mode: modeLed, PedalLedGroup.bank: bank};
    }
    const recPlay = {
      PedalLedState.recording: ledRed,
      PedalLedState.playing: ledGreen,
      PedalLedState.idle: ledWhite,
      ...pressed,
    };
    Map<PedalLedState, PedalColor> track(PedalLedState state, PedalColor c) => {
      state: c,
      ...pressed,
    };
    final tracks = switch (mode) {
      InteractionMode.record => {
        PedalLedState.recording: ledRed,
        PedalLedState.overdubbing: ledRed,
        PedalLedState.playing: ledGreen,
        PedalLedState.selected: ledWhite,
        ...pressed,
      },
      InteractionMode.mute => track(PedalLedState.armed, ledGreen),
      InteractionMode.fx => track(PedalLedState.engaged, ledBlue),
      InteractionMode.mixer => track(PedalLedState.selected, ledWhite),
      InteractionMode.fade => track(PedalLedState.fading, ledBlue),
      InteractionMode.reverse => track(PedalLedState.reversed, ledBlue),
      InteractionMode.peel => track(PedalLedState.peelable, ledBlue),
      InteractionMode.tuner => track(PedalLedState.tuned, ledWhite),
      InteractionMode.multiply ||
      InteractionMode.divide => track(PedalLedState.selected, ledRed),
      InteractionMode.custom => throw StateError('unreachable'),
    };
    const clearPressed = {PedalLedState.pressed: ledRed};
    return switch (mode) {
      InteractionMode.record || InteractionMode.mute => {
        PedalLedGroup.tracks: tracks,
        PedalLedGroup.recPlay: recPlay,
        PedalLedGroup.stop: pressed,
        PedalLedGroup.undo: pressed,
        PedalLedGroup.clear: clearPressed,
        PedalLedGroup.mode: modeLed,
        PedalLedGroup.bank: bank,
      },
      // A bound Rec/Play, Stop, Undo or Clear lights for what it drives.
      InteractionMode.fx => {
        PedalLedGroup.tracks: tracks,
        PedalLedGroup.recPlay: recPlay,
        PedalLedGroup.stop: {PedalLedState.engaged: ledWhite, ...pressed},
        PedalLedGroup.undo: {PedalLedState.engaged: ledWhite, ...pressed},
        PedalLedGroup.clear: {
          PedalLedState.engaged: ledRed,
          ...clearPressed,
        },
        PedalLedGroup.mode: modeLed,
        PedalLedGroup.bank: bank,
      },
      InteractionMode.tuner => {
        PedalLedGroup.tracks: tracks,
        PedalLedGroup.recPlay: pressed,
        PedalLedGroup.stop: {PedalLedState.muted: ledWhite, ...pressed},
        PedalLedGroup.undo: pressed,
        PedalLedGroup.clear: clearPressed,
        PedalLedGroup.mode: modeLed,
        PedalLedGroup.bank: bank,
      },
      // The Mixer pages its own channels: Bank lights only while held.
      InteractionMode.mixer => {
        PedalLedGroup.tracks: tracks,
        PedalLedGroup.recPlay: pressed,
        PedalLedGroup.stop: pressed,
        PedalLedGroup.undo: pressed,
        PedalLedGroup.clear: clearPressed,
        PedalLedGroup.mode: modeLed,
        PedalLedGroup.bank: pressed,
      },
      // The hold-less performance surfaces: only the track pedals, MODE and
      // Bank carry a state; the rest light while held.
      _ => {
        PedalLedGroup.tracks: tracks,
        PedalLedGroup.recPlay: pressed,
        PedalLedGroup.stop: pressed,
        PedalLedGroup.undo: pressed,
        PedalLedGroup.clear: clearPressed,
        PedalLedGroup.mode: modeLed,
        PedalLedGroup.bank: bank,
      },
    };
  }

  /// The group [button] belongs to.
  static PedalLedGroup groupOf(PedalButton button) => switch (button) {
    PedalButton.recPlay => PedalLedGroup.recPlay,
    PedalButton.stop => PedalLedGroup.stop,
    PedalButton.undo => PedalLedGroup.undo,
    PedalButton.clear => PedalLedGroup.clear,
    PedalButton.mode => PedalLedGroup.mode,
    PedalButton.bank => PedalLedGroup.bank,
    PedalButton.track1 ||
    PedalButton.track2 ||
    PedalButton.track3 ||
    PedalButton.track4 => PedalLedGroup.tracks,
  };

  /// Overridden mode colours.
  final Map<PedalLedSlot, PedalColor> modes;

  /// Overridden Custom-mode pedal colours.
  final Map<CustomLedSlot, PedalColor> custom;

  /// Whether nothing is overridden.
  bool get isEmpty => modes.isEmpty && custom.isEmpty;

  /// The colour [group] shows for [state] in [mode].
  PedalColor colorFor(
    InteractionMode mode,
    PedalLedGroup group,
    PedalLedState state,
  ) =>
      modes[(mode: mode, group: group, state: state)] ??
      schema(mode)[group]?[state] ??
      ledWhite;

  /// The colour the Custom assignment at [key] shows for [state].
  PedalColor customColorFor(PedalBindingKey key, PedalLedState state) =>
      custom[(key: key, state: state)] ?? ledWhite;

  /// Returns a copy with [color] on one mode slot.
  PedalLedMap withColor(
    InteractionMode mode,
    PedalLedGroup group,
    PedalLedState state,
    PedalColor color,
  ) => PedalLedMap.fromMaps(
    modes: {...modes, (mode: mode, group: group, state: state): color},
    custom: custom,
  );

  /// Returns a copy with [color] on one Custom assignment's [state].
  PedalLedMap withCustomColor(
    PedalBindingKey key,
    PedalLedState state,
    PedalColor color,
  ) => PedalLedMap.fromMaps(
    modes: modes,
    custom: {...custom, (key: key, state: state): color},
  );

  /// Returns a copy with [mode]'s colours back at their defaults. Custom
  /// pedal colours belong to their assignments and are kept.
  PedalLedMap resetMode(InteractionMode mode) => PedalLedMap._(
    {
      for (final entry in modes.entries)
        if (entry.key.mode != mode) entry.key: entry.value,
    },
    custom,
  );

  /// Whether [mode] has any colour edited away from its default.
  bool isEdited(InteractionMode mode) => modes.keys.any((k) => k.mode == mode);

  /// The canonical encoding, byte-stable for equal maps.
  Map<String, dynamic> toJson() => {
    if (modes.isNotEmpty)
      'modes': {
        for (final mode in InteractionMode.values)
          if (isEdited(mode))
            mode.name: {
              for (final group in PedalLedGroup.values)
                if (_groupEdited(mode, group))
                  group.name: {
                    for (final state in PedalLedState.values)
                      if (modes[(mode: mode, group: group, state: state)]
                          case final color?)
                        state.name: color.rgb,
                  },
            },
      },
    if (custom.isNotEmpty)
      'custom': [
        for (final key in _customKeys)
          {
            ...key.toJson(),
            for (final state in customStates)
              if (custom[(key: key, state: state)] case final color?)
                state.name: color.rgb,
          },
      ],
  };

  bool _groupEdited(InteractionMode mode, PedalLedGroup group) =>
      modes.keys.any((k) => k.mode == mode && k.group == group);

  List<PedalBindingKey> get _customKeys =>
      {for (final slot in custom.keys) slot.key}.toList()..sort(
        (a, b) {
          final button = a.button.index.compareTo(b.button.index);
          if (button != 0) return button;
          return (a.bank ?? -1).compareTo(b.bank ?? -1);
        },
      );

  static T? _byName<T extends Enum>(List<T> values, String name) {
    for (final value in values) {
      if (value.name == name) return value;
    }
    return null;
  }

  static PedalColor _color(Object? raw) {
    if (raw is! int || raw < 0 || raw > 0xFFFFFF) {
      throw const FormatException('Invalid pedal LED colour');
    }
    return PedalColor.fromRgb(raw);
  }

  @override
  List<Object?> get props => [
    for (final slot in modes.keys.toList()..sort(_compareSlots)) ...[
      slot,
      modes[slot],
    ],
    for (final key in _customKeys)
      for (final state in customStates) ...[
        key,
        custom[(key: key, state: state)],
      ],
  ];

  static int _compareSlots(PedalLedSlot a, PedalLedSlot b) {
    final mode = a.mode.index.compareTo(b.mode.index);
    if (mode != 0) return mode;
    final group = a.group.index.compareTo(b.group.index);
    if (group != 0) return group;
    return a.state.index.compareTo(b.state.index);
  }
}
