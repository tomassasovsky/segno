import 'dart:convert';

import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/control/binding/mix_value_scale.dart';
import 'package:segno/looper/model/one_shot.dart';
import 'package:segno/looper/model/overdub_decay.dart';
import 'package:segno/looper/model/owned_setting.dart';
import 'package:segno/looper/model/record_length.dart';
import 'package:segno/looper/model/record_start.dart';
import 'package:segno/looper/model/record_timing.dart';

/// What a continuous binding sweeps: an FX parameter, Mixer control, or
/// master gain.
///
/// The discrete counterpart is part 6b's `FxBindingTarget` — a stomp flips an
/// `enabled` flag, so the two shapes address different things and stay separate
/// sealed types. Both cross the `controller_repository` boundary as
/// [canonicalString]s, which is what keeps that package free of any
/// looper/engine dependency (VGV-critical).
///
/// ## Canonical JSON
///
/// An FX param EXTENDS part 3a's [FxAddress] canonical form the same way
/// `FxSlotTarget` does (R19): the address contributes its own fixed key order,
/// then `slot` and `param`. The rig-level controls, which have no address at
/// all, use a `ctl` envelope instead. Byte-stable in every case, so plain
/// string equality is target identity.
///
/// ## One normalized domain
///
/// Every binding endpoint is normalized `0..1`. Mixer targets convert that
/// position to their actual units at the target boundary, so one stored range
/// and one pickup rule can serve a gain fader, pan, and output level.
sealed class ControlValueTarget extends Equatable {
  /// Const base constructor for the sealed subtypes.
  const ControlValueTarget();

  /// Valid target coordinates, independent of whether the rig has that target.
  bool get isStructurallyValid => switch (this) {
    FxParamTarget(:final address, :final slotId, :final param) =>
      address.isStructurallyValid && slotId.isNotEmpty && param >= 0,
    TrackVolumeTarget(:final channel) => channel >= 0,
    LaneVolumeTarget(:final channel, :final lane) => channel >= 0 && lane >= 0,
    MonitorVolumeTarget(:final input) => input >= 0,
    TrackPanTarget(:final channel) => channel >= 0,
    InputPanTarget(:final input) => input >= 0,
    PairBalanceTarget(:final input) => input >= 0 && input.isEven,
    OutputLevelTarget(:final bus) => bus >= 0,
    OutputBalanceTarget(:final bus) => bus >= 0,
    MasterGainTarget() => true,
    ClickModeValueTarget() => true,
    CountInValueTarget() => true,
    ClickVolumeTarget() => true,
    DefaultDecayTarget() => true,
    TrackDecayTarget(:final channel) => channel >= 0 && channel < 8,
    DefaultOneShotTarget() => true,
    TrackOneShotTarget(:final channel) => channel >= 0 && channel < 8,
    DefaultRecordLengthTarget() => true,
    TrackRecordLengthTarget(:final channel) => channel >= 0 && channel < 8,
    DefaultRecordTimingTarget() => true,
    TrackRecordTimingTarget(:final channel) => channel >= 0 && channel < 8,
    DefaultFadeTarget() => true,
    TrackFadeTarget(:final channel) => channel >= 0 && channel < 8,
    BackingLevelTarget() || BackingPanTarget() || ClickPanTarget() => true,
  };

  /// Where a new mapping's top endpoint sits: unity gain on a level fader,
  /// whose full travel is +6 dB; full travel on every other target.
  double get mappingTop => switch (this) {
    TrackVolumeTarget() ||
    LaneVolumeTarget() ||
    BackingLevelTarget() => mixerTravelFor(1),
    _ => 1,
  };

  /// A stored mapping endpoint as the mapping reads it. On a level fader a
  /// literal 1.0 is read as [mappingTop], unity: the top every mapping got
  /// before unity became the default.
  double decodeEndpoint(double stored) => stored == 1 ? mappingTop : stored;

  /// Parses a [canonicalString] back to a target, or `null` when [encoded] is
  /// not a decodable one.
  ///
  /// Never throws: mappings cross app restarts as bare strings, so a corrupt or
  /// hand-edited one must decode to `null` — which the caller renders as a
  /// stale row — rather than taking the control surface down.
  static ControlValueTarget? tryParse(String encoded) {
    final Object? raw;
    try {
      raw = jsonDecode(encoded);
    } on FormatException {
      return null;
    }
    if (raw is! Map<String, dynamic>) return null;
    final ctl = raw['ctl'];
    if (raw.containsKey('ctl')) {
      if (ctl == 'masterGain') {
        return raw.length == 1 ? const MasterGainTarget() : null;
      }
      if (ctl == 'clickVolume') {
        return raw.length == 1 ? const ClickVolumeTarget() : null;
      }
      if (ctl == 'clickMode') {
        return raw.length == 1 ? const ClickModeValueTarget() : null;
      }
      if (ctl == 'countIn') {
        return raw.length == 1 ? const CountInValueTarget() : null;
      }
      if (ctl == 'overdubDecay') {
        return raw.length == 1 ? const DefaultDecayTarget() : null;
      }
      if (ctl == 'defaultOneShot') {
        return raw.length == 1 ? const DefaultOneShotTarget() : null;
      }
      if (ctl == 'defaultRecordLength') {
        return raw.length == 1 ? const DefaultRecordLengthTarget() : null;
      }
      if (ctl == 'defaultRecordTiming') {
        return raw.length == 1 ? const DefaultRecordTimingTarget() : null;
      }
      if (ctl == 'fadeSeconds') {
        return raw.length == 1 ? const DefaultFadeTarget() : null;
      }
      if (ctl == 'backingLevel') {
        return raw.length == 1 ? const BackingLevelTarget() : null;
      }
      if (ctl == 'backingPan') {
        return raw.length == 1 ? const BackingPanTarget() : null;
      }
      if (ctl == 'clickPan') {
        return raw.length == 1 ? const ClickPanTarget() : null;
      }
      final index = raw['index'];
      final lane = raw['lane'];
      if (index is! int || index < 0) return null;
      final indexed = raw.length == 2;
      return switch (ctl) {
        'trackVolume' when indexed => TrackVolumeTarget(index),
        'laneVolume' when raw.length == 3 && lane is int && lane >= 0 =>
          LaneVolumeTarget(index, lane),
        'monitorVolume' when indexed => MonitorVolumeTarget(index),
        'trackPan' when indexed => TrackPanTarget(index),
        'inputPan' when indexed => InputPanTarget(index),
        'pairBalance' when indexed && index.isEven => PairBalanceTarget(index),
        'outputLevel' when indexed => OutputLevelTarget(index),
        'outputBalance' when indexed => OutputBalanceTarget(index),
        'trackOverdubDecay' when indexed && index < 8 => TrackDecayTarget(
          index,
        ),
        'trackOneShot' when indexed && index < 8 => TrackOneShotTarget(index),
        'trackRecordLength' when indexed && index < 8 =>
          TrackRecordLengthTarget(index),
        'trackRecordTiming' when indexed && index < 8 =>
          TrackRecordTimingTarget(index),
        'trackFadeSeconds' when indexed && index < 8 => TrackFadeTarget(index),
        _ => null,
      };
    }
    final address = FxAddress.fromJson(raw);
    if (address == null) return null;
    final slot = raw['slot'];
    final param = raw['param'];
    if (slot is! String || slot.isEmpty) return null;
    if (param is! int || param < 0) return null;
    return FxParamTarget(
      address: address,
      slotId: slot,
      param: param,
    );
  }

  /// The byte-stable canonical serialization (see the class doc).
  String canonicalString();
}

/// One parameter of one effect, keyed by the part 3a stable [slotId] (A9) —
/// never by position, so inserting or reordering effects around a bound one
/// leaves the mapping pointing at the SAME effect.
///
/// [param] is the parameter's index within the effect's own descriptor list.
/// Built-in effects only in v1: a hosted plugin's parameters are addressed by
/// plugin-assigned id rather than position and have no setter at every stage,
/// so a plugin slot offers no continuous targets yet (its rows simply do not
/// appear in the picker).
final class FxParamTarget extends ControlValueTarget {
  /// Creates an FX-parameter target.
  const FxParamTarget({
    required this.address,
    required this.slotId,
    required this.param,
  });

  /// The chain the effect lives on.
  final FxAddress address;

  /// The stable per-slot id (part 3a) of the bound effect.
  final String slotId;

  /// The parameter's index within the effect type's descriptors.
  final int param;

  @override
  String canonicalString() =>
      jsonEncode({...address.toJson(), 'slot': slotId, 'param': param});

  @override
  List<Object?> get props => [address, slotId, param];
}

/// One track's volume fader.
final class TrackVolumeTarget extends MixValueTarget {
  /// Creates a track-volume target on [channel].
  const TrackVolumeTarget(this.channel);

  /// The track channel.
  final int channel;

  @override
  String canonicalString() =>
      jsonEncode({'ctl': 'trackVolume', 'index': channel});

  @override
  List<Object?> get props => [channel];
}

/// A Mixer setting with a normalized binding position and a physical domain.
/// The rig coordinate remains stable even when the current device lacks it.
sealed class MixValueTarget extends ControlValueTarget {
  /// Const base constructor for Mixer target subtypes.
  const MixValueTarget();

  /// Converts a stored endpoint or live source position into Mixer units.
  double toDomain(double normalized) {
    final value = normalized.clamp(0.0, 1.0);
    return switch (this) {
      TrackVolumeTarget() || LaneVolumeTarget() => mixerGainAt(value),
      MonitorVolumeTarget() => value,
      TrackPanTarget() ||
      InputPanTarget() ||
      PairBalanceTarget() ||
      OutputBalanceTarget() => value * 2 - 1,
      OutputLevelTarget() => value,
    };
  }

  /// Converts the accepted Mixer value back to a normalized source position.
  double fromDomain(double domain) => switch (this) {
    TrackVolumeTarget() || LaneVolumeTarget() => mixerTravelFor(domain),
    MonitorVolumeTarget() => domain.clamp(0.0, 1.0),
    TrackPanTarget() ||
    InputPanTarget() ||
    PairBalanceTarget() ||
    OutputBalanceTarget() => ((domain + 1) / 2).clamp(0.0, 1.0),
    OutputLevelTarget() => domain.clamp(0.0, 1.0),
  };

  /// One relative-controller detent in normalized source travel.
  double get relativeStep => switch (this) {
    TrackVolumeTarget() || LaneVolumeTarget() || MonitorVolumeTarget() => 0.02,
    TrackPanTarget() => 0.025,
    InputPanTarget() ||
    PairBalanceTarget() ||
    OutputLevelTarget() ||
    OutputBalanceTarget() => 0.01,
  };
}

/// One active lane's independent playback gain.
final class LaneVolumeTarget extends MixValueTarget {
  /// Creates a lane-volume target.
  const LaneVolumeTarget(this.channel, this.lane);

  /// The recorded track channel.
  final int channel;

  /// The active lane number within that track.
  final int lane;

  @override
  String canonicalString() =>
      jsonEncode({'ctl': 'laneVolume', 'index': channel, 'lane': lane});

  @override
  List<Object?> get props => [channel, lane];
}

/// One hardware input's live-monitor gain, separate from capture trim.
final class MonitorVolumeTarget extends MixValueTarget {
  /// Creates a monitor-volume target.
  const MonitorVolumeTarget(this.input);

  /// The hardware input channel.
  final int input;

  @override
  String canonicalString() =>
      jsonEncode({'ctl': 'monitorVolume', 'index': input});

  @override
  List<Object?> get props => [input];
}

/// One track's pan offset, without changing its recorded source images.
final class TrackPanTarget extends MixValueTarget {
  /// Creates a track-pan target.
  const TrackPanTarget(this.channel);

  /// The recorded track channel.
  final int channel;

  @override
  String canonicalString() => jsonEncode({'ctl': 'trackPan', 'index': channel});

  @override
  List<Object?> get props => [channel];
}

/// The stored pan of a mono hardware input.
final class InputPanTarget extends MixValueTarget {
  /// Creates an input-pan target.
  const InputPanTarget(this.input);

  /// The hardware input channel.
  final int input;

  @override
  String canonicalString() => jsonEncode({'ctl': 'inputPan', 'index': input});

  @override
  List<Object?> get props => [input];
}

/// Balance of an existing linked hardware-input pair, keyed by its left jack.
final class PairBalanceTarget extends MixValueTarget {
  /// Creates a pair-balance target.
  const PairBalanceTarget(this.input);

  /// The even, lower hardware input channel.
  final int input;

  @override
  String canonicalString() =>
      jsonEncode({'ctl': 'pairBalance', 'index': input});

  @override
  List<Object?> get props => [input];
}

/// The level of one output destination, retained behind mute.
final class OutputLevelTarget extends MixValueTarget {
  /// Creates an output-level target.
  const OutputLevelTarget(this.bus);

  /// The output bus ordinal.
  final int bus;

  @override
  String canonicalString() => jsonEncode({'ctl': 'outputLevel', 'index': bus});

  @override
  List<Object?> get props => [bus];
}

/// Stereo balance of one output destination, retained while Mono.
final class OutputBalanceTarget extends MixValueTarget {
  /// Creates an output-balance target.
  const OutputBalanceTarget(this.bus);

  /// The output bus ordinal.
  final int bus;

  @override
  String canonicalString() =>
      jsonEncode({'ctl': 'outputBalance', 'index': bus});

  @override
  List<Object?> get props => [bus];
}

/// A value a shared settings owner holds: one family's default or track
/// address. Dispatch handles every owned family through this one type; the
/// conversion to each family's domain lives with its port.
sealed class OwnedValueTarget extends ControlValueTarget {
  /// Const base constructor for the owned families.
  const OwnedValueTarget();

  /// The family whose owner holds this value.
  OwnedSetting get family;

  /// One MIDI relative-controller detent in normalized source travel.
  double get relativeStep;

  /// [normalized] snapped to the nearest value the family can hold; a
  /// non-finite value passes through for the caller to refuse.
  double coerce(double normalized);
}

/// The master output gain — the same value the pedal's encoder turns.
final class MasterGainTarget extends ControlValueTarget {
  /// Creates the master-gain target.
  const MasterGainTarget();

  @override
  String canonicalString() => jsonEncode({'ctl': 'masterGain'});

  @override
  List<Object?> get props => ['masterGain'];
}

/// The click's gain, owned by the current Click volume control rather than a
/// Mixer output bus. A normalized position of 0.5 is physical unity.
final class ClickVolumeTarget extends OwnedValueTarget {
  /// Creates the click-volume target.
  const ClickVolumeTarget();

  @override
  OwnedSetting get family => OwnedSetting.clickVolume;

  @override
  double coerce(double normalized) => normalized.clamp(0.0, 1.0);

  /// Converts a stored normalized endpoint to the click's physical gain.
  double toDomain(double normalized) =>
      normalized.clamp(0.0, 1.0) * kMaxClickGain;

  /// Converts an accepted physical gain to a normalized endpoint.
  double fromDomain(double gain) => (gain / kMaxClickGain).clamp(0.0, 1.0);

  @override
  double get relativeStep => 0.01;

  @override
  String canonicalString() => jsonEncode({'ctl': 'clickVolume'});

  @override
  List<Object?> get props => ['clickVolume'];
}

/// The click's four audible policies in user order, independent of native
/// enum codes. A mapping stores normalized travel, not the native code.
final class ClickModeValueTarget extends OwnedValueTarget {
  /// Creates the global Hear click target.
  const ClickModeValueTarget();

  @override
  OwnedSetting get family => OwnedSetting.hearClick;

  @override
  double coerce(double normalized) =>
      normalized.isFinite ? fromDomain(toDomain(normalized)) : normalized;

  /// Choices in the order displayed by Loop settings and endpoint editors.
  static const choices = <ClickMode>[
    ClickMode.off,
    ClickMode.recFirst,
    ClickMode.rec,
    ClickMode.playRec,
  ];

  /// The nearest choice for one finite normalized endpoint.
  ClickMode toDomain(double normalized) {
    if (!normalized.isFinite) {
      throw ArgumentError.value(normalized, 'normalized');
    }
    return choices[(normalized.clamp(0.0, 1.0) * 3).round()];
  }

  /// The exact normalized position of an accepted choice.
  double fromDomain(ClickMode mode) => choices.indexOf(mode) / 3;

  @override
  double get relativeStep => 1 / 3;

  @override
  String canonicalString() => jsonEncode({'ctl': 'clickMode'});

  @override
  List<Object?> get props => ['clickMode'];
}

/// The four Count-in choices, stored as normalized option positions.
final class CountInValueTarget extends OwnedValueTarget {
  /// Creates the global Count-in target.
  const CountInValueTarget();

  @override
  OwnedSetting get family => OwnedSetting.recordStart;

  @override
  double coerce(double normalized) =>
      normalized.isFinite ? fromDomain(toDomain(normalized)) : normalized;

  /// The nearest supported choice, never a rounded number of bars.
  int toDomain(double normalized) {
    if (!normalized.isFinite) {
      throw ArgumentError.value(normalized, 'normalized');
    }
    return kCountInBarOptions[(normalized.clamp(0.0, 1.0) * 3).round()];
  }

  /// The position of an accepted choice.
  double fromDomain(int bars) {
    final index = kCountInBarOptions.indexOf(bars);
    if (index < 0) throw ArgumentError.value(bars, 'bars');
    return index / 3;
  }

  @override
  double get relativeStep => 1 / 3;

  @override
  String canonicalString() => jsonEncode({'ctl': 'countIn'});

  @override
  List<Object?> get props => ['countIn'];
}

/// A decay endpoint uses percent as its native domain and 0..1 in mappings.
sealed class DecayValueTarget extends OwnedValueTarget {
  /// Creates a decay target.
  const DecayValueTarget();

  @override
  OwnedSetting get family => OwnedSetting.decay;

  @override
  double coerce(double normalized) =>
      normalized.isFinite ? fromDomain(toDomain(normalized)) : normalized;

  /// Its stable default or fixed-track address.
  DecayAddress get address;

  /// Converts normalized source travel into an integer decay percent.
  int toDomain(double normalized) {
    if (!normalized.isFinite) {
      throw ArgumentError.value(normalized, 'normalized');
    }
    return (normalized.clamp(0.0, 1.0) * 100).round();
  }

  /// Converts accepted percent into normalized source travel.
  double fromDomain(int percent) => percent.clamp(0, 100) / 100;

  @override
  double get relativeStep => 0.01;
}

/// The shared overdub decay inherited by tracks without an override.
final class DefaultDecayTarget extends DecayValueTarget {
  /// Creates the default decay target.
  const DefaultDecayTarget();

  @override
  DecayAddress get address => const DecayAddress.defaults();

  @override
  String canonicalString() => jsonEncode({'ctl': 'overdubDecay'});

  @override
  List<Object?> get props => ['overdubDecay'];
}

/// One fixed track's effective overdub decay, including empty tracks.
final class TrackDecayTarget extends DecayValueTarget {
  /// Creates a track decay target with a zero-based [channel].
  const TrackDecayTarget(this.channel);

  /// Fixed channel, independent of selection and the current track count.
  final int channel;

  @override
  DecayAddress get address => DecayAddress.track(channel);

  @override
  String canonicalString() =>
      jsonEncode({'ctl': 'trackOverdubDecay', 'index': channel});

  @override
  List<Object?> get props => [channel];
}

/// A binary Loop/Once endpoint represented by normalized controller travel.
sealed class OneShotValueTarget extends OwnedValueTarget {
  /// Creates a Loop/Once target.
  const OneShotValueTarget();

  @override
  OwnedSetting get family => OwnedSetting.oneShot;

  @override
  double coerce(double normalized) => normalized.isFinite
      ? fromDomain(oneShot: toDomain(normalized))
      : normalized;

  /// The fixed default or track address.
  OneShotAddress get address;

  /// Converts normalized source travel to the owner's Loop/Once value.
  bool toDomain(double normalized) {
    if (!normalized.isFinite) {
      throw ArgumentError.value(normalized, 'normalized');
    }
    return normalized >= 0.5;
  }

  /// Converts the accepted Loop/Once value to a stored endpoint.
  double fromDomain({required bool oneShot}) => oneShot ? 1 : 0;

  @override
  double get relativeStep => 1;
}

/// The Loop/Once default inherited by tracks without an override.
final class DefaultOneShotTarget extends OneShotValueTarget {
  /// Creates the default Loop/Once target.
  const DefaultOneShotTarget();

  @override
  OneShotAddress get address => const OneShotAddress.defaults();

  @override
  String canonicalString() => jsonEncode({'ctl': 'defaultOneShot'});

  @override
  List<Object?> get props => ['defaultOneShot'];
}

/// One fixed track's effective Loop/Once choice, including empty tracks.
final class TrackOneShotTarget extends OneShotValueTarget {
  /// Creates a track Loop/Once target with a zero-based [channel].
  const TrackOneShotTarget(this.channel);

  /// Fixed channel, independent of selection and current track count.
  final int channel;

  @override
  OneShotAddress get address => OneShotAddress.track(channel);

  @override
  String canonicalString() =>
      jsonEncode({'ctl': 'trackOneShot', 'index': channel});

  @override
  List<Object?> get props => [channel];
}

/// A future-recording length: Auto or a whole number of bars.
sealed class RecordLengthValueTarget extends OwnedValueTarget {
  /// Creates a length target.
  const RecordLengthValueTarget();

  @override
  OwnedSetting get family => OwnedSetting.recordLength;

  @override
  double coerce(double normalized) =>
      normalized.isFinite ? fromDomain(toDomain(normalized)) : normalized;

  /// Its stable default or fixed-track address.
  RecordLengthAddress get address;

  /// Decodes a normalized source position to Auto (0) or 1–64 bars.
  int toDomain(double normalized) {
    if (!normalized.isFinite) {
      throw ArgumentError.value(normalized, 'normalized');
    }
    return (normalized.clamp(0.0, 1.0) * 64).round();
  }

  /// Encodes an accepted length as a canonical normalized endpoint.
  double fromDomain(int bars) => bars.clamp(0, 64) / 64;

  @override
  double get relativeStep => 1 / 64;
}

/// The future-recording length inherited by tracks without an override.
final class DefaultRecordLengthTarget extends RecordLengthValueTarget {
  /// Creates the default length target.
  const DefaultRecordLengthTarget();

  @override
  RecordLengthAddress get address => const RecordLengthAddress.defaults();

  @override
  String canonicalString() => jsonEncode({'ctl': 'defaultRecordLength'});

  @override
  List<Object?> get props => ['defaultRecordLength'];
}

/// One fixed track's future-recording length, including an empty slot.
final class TrackRecordLengthTarget extends RecordLengthValueTarget {
  /// Creates a track length target for zero-based [channel].
  const TrackRecordLengthTarget(this.channel);

  /// The fixed track channel.
  final int channel;

  @override
  RecordLengthAddress get address => RecordLengthAddress.track(channel);

  @override
  String canonicalString() =>
      jsonEncode({'ctl': 'trackRecordLength', 'index': channel});

  @override
  List<Object?> get props => [channel];
}

/// A future Record/Overdub timing choice on the established musical grid.
sealed class RecordTimingValueTarget extends OwnedValueTarget {
  /// Creates a timing target.
  const RecordTimingValueTarget();

  @override
  OwnedSetting get family => OwnedSetting.recordTiming;

  @override
  double coerce(double normalized) =>
      normalized.isFinite ? fromDomain(toDomain(normalized)) : normalized;

  /// Its stable default or fixed-track address.
  RecordTimingAddress get address;

  /// Seven accepted choices, with Immediately distinct from inheritance.
  RecordTiming toDomain(double normalized) {
    if (!normalized.isFinite) {
      throw ArgumentError.value(normalized, 'normalized');
    }
    return RecordTiming.values[(normalized.clamp(0.0, 1.0) * 6).round()];
  }

  /// Encodes a confirmed choice as its canonical normalized endpoint.
  double fromDomain(RecordTiming timing) => timing.code / 6;

  @override
  double get relativeStep => 1 / 6;
}

/// The timing inherited by tracks without an explicit override.
final class DefaultRecordTimingTarget extends RecordTimingValueTarget {
  /// Creates the default timing target.
  const DefaultRecordTimingTarget();

  @override
  RecordTimingAddress get address => const RecordTimingAddress.defaults();

  @override
  String canonicalString() => jsonEncode({'ctl': 'defaultRecordTiming'});

  @override
  List<Object?> get props => ['defaultRecordTiming'];
}

/// One fixed track's future timing, including an empty track slot.
final class TrackRecordTimingTarget extends RecordTimingValueTarget {
  /// Creates a track timing target for zero-based [channel].
  const TrackRecordTimingTarget(this.channel);

  /// The fixed track channel.
  final int channel;

  @override
  RecordTimingAddress get address => RecordTimingAddress.track(channel);

  @override
  String canonicalString() =>
      jsonEncode({'ctl': 'trackRecordTiming', 'index': channel});

  @override
  List<Object?> get props => [channel];
}

/// A Fade duration endpoint: 0.5–30 s in 0.5 s steps, stored in mappings as
/// normalized travel across those 60 values.
sealed class FadeValueTarget extends OwnedValueTarget {
  /// Creates a Fade duration target.
  const FadeValueTarget();

  @override
  OwnedSetting get family => OwnedSetting.fade;

  @override
  double coerce(double normalized) =>
      normalized.isFinite ? fromDomain(toDomain(normalized)) : normalized;

  /// The fixed track, or null for the Default inherited by tracks without an
  /// override.
  int? get channel;

  static const _minMs = 500;
  static const _stepMs = 500;
  static const _steps = 59;

  /// Converts normalized source travel into a whole number of 0.5 s steps,
  /// in milliseconds.
  int toDomain(double normalized) {
    if (!normalized.isFinite) {
      throw ArgumentError.value(normalized, 'normalized');
    }
    return _minMs + (normalized.clamp(0.0, 1.0) * _steps).round() * _stepMs;
  }

  /// Converts an accepted duration in milliseconds into normalized travel.
  double fromDomain(int milliseconds) =>
      (milliseconds.clamp(_minMs, _minMs + _steps * _stepMs) - _minMs) /
      (_steps * _stepMs);

  @override
  double get relativeStep => 1 / _steps;
}

/// The Fade duration inherited by tracks without an override.
final class DefaultFadeTarget extends FadeValueTarget {
  /// Creates the default Fade duration target.
  const DefaultFadeTarget();

  @override
  int? get channel => null;

  @override
  String canonicalString() => jsonEncode({'ctl': 'fadeSeconds'});

  @override
  List<Object?> get props => ['fadeSeconds'];
}

/// One fixed track's effective Fade duration, including an empty track slot.
/// Writing it while the track inherits the Default creates its override.
final class TrackFadeTarget extends FadeValueTarget {
  /// Creates a track Fade duration target for zero-based [channel].
  const TrackFadeTarget(this.channel);

  @override
  final int channel;

  @override
  String canonicalString() =>
      jsonEncode({'ctl': 'trackFadeSeconds', 'index': channel});

  @override
  List<Object?> get props => [channel];
}

/// The backing's gain (#1200), on the Mixer level fader's axis: silence to
/// +6.02 dB, unity at the same travel as a track fader.
final class BackingLevelTarget extends OwnedValueTarget {
  /// Creates the backing-level target.
  const BackingLevelTarget();

  @override
  OwnedSetting get family => OwnedSetting.backingMix;

  @override
  double coerce(double normalized) =>
      normalized.isFinite ? normalized.clamp(0.0, 1.0) : normalized;

  /// Converts normalized travel to the backing's linear gain.
  double toDomain(double normalized) => mixerGainAt(normalized);

  /// Converts an accepted gain to normalized travel.
  double fromDomain(double gain) => mixerTravelFor(gain);

  @override
  double get relativeStep => 0.02;

  @override
  String canonicalString() => jsonEncode({'ctl': 'backingLevel'});

  @override
  List<Object?> get props => ['backingLevel'];
}

/// A balance owned by the backing settings (#1200): travel 0..1 is left to
/// right, centre at one half.
sealed class OwnedPanTarget extends OwnedValueTarget {
  /// Const base constructor.
  const OwnedPanTarget();

  @override
  double coerce(double normalized) =>
      normalized.isFinite ? normalized.clamp(0.0, 1.0) : normalized;

  /// Converts normalized travel to a balance in `-1..1`.
  double toDomain(double normalized) => normalized.clamp(0.0, 1.0) * 2 - 1;

  /// Converts an accepted balance to normalized travel.
  double fromDomain(double pan) => ((pan + 1) / 2).clamp(0.0, 1.0);

  @override
  double get relativeStep => 0.025;
}

/// The backing's balance (#1200).
final class BackingPanTarget extends OwnedPanTarget {
  /// Creates the backing-pan target.
  const BackingPanTarget();

  @override
  OwnedSetting get family => OwnedSetting.backingMix;

  @override
  String canonicalString() => jsonEncode({'ctl': 'backingPan'});

  @override
  List<Object?> get props => ['backingPan'];
}

/// The click's balance (#1200 D6).
final class ClickPanTarget extends OwnedPanTarget {
  /// Creates the click-pan target.
  const ClickPanTarget();

  @override
  OwnedSetting get family => OwnedSetting.clickPan;

  @override
  String canonicalString() => jsonEncode({'ctl': 'clickPan'});

  @override
  List<Object?> get props => ['clickPan'];
}
