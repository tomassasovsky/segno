import 'dart:convert';

import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/control/binding/mix_value_scale.dart';

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
  };

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
      TrackVolumeTarget() ||
      LaneVolumeTarget() ||
      MonitorVolumeTarget() => mixerGainAt(value),
      TrackPanTarget() ||
      InputPanTarget() ||
      PairBalanceTarget() ||
      OutputBalanceTarget() => value * 2 - 1,
      OutputLevelTarget() => value,
    };
  }

  /// Converts the accepted Mixer value back to a normalized source position.
  double fromDomain(double domain) => switch (this) {
    TrackVolumeTarget() ||
    LaneVolumeTarget() ||
    MonitorVolumeTarget() => mixerTravelFor(domain),
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

/// The master output gain — the same value the pedal's encoder turns.
final class MasterGainTarget extends ControlValueTarget {
  /// Creates the master-gain target.
  const MasterGainTarget();

  @override
  String canonicalString() => jsonEncode({'ctl': 'masterGain'});

  @override
  List<Object?> get props => ['masterGain'];
}
