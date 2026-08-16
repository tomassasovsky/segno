import 'package:equatable/equatable.dart';

/// A control command from the 7" readout's volume overlay to the main window —
/// the first sub→main control path on the waveform-window channel (#698); the
/// readout was previously display-only.
///
/// Same wire discipline as `PerformanceReadout`: the map is the contract, not
/// the Dart type, because the two engines can be built from different
/// revisions. [ReadoutControl.fromMap] defaults every missing field and the
/// main-window side ignores actions it does not know — an older main window
/// quietly drops a newer overlay's command instead of throwing, and value
/// clamping happens where the command is applied, never trusted from the
/// wire.
class ReadoutControl extends Equatable {
  /// Creates a [ReadoutControl].
  const ReadoutControl({
    required this.action,
    required this.index,
    this.value = 0,
  });

  /// Rebuilds a command from [map] as sent across the window channel.
  factory ReadoutControl.fromMap(Map<Object?, Object?> map) => ReadoutControl(
    action: map['action'] as String? ?? '',
    index: map['index'] as int? ?? -1,
    value: (map['value'] as num? ?? 0).toDouble(),
  );

  /// Set track [index]'s output volume to [value] (linear gain).
  static const trackVolume = 'trackVolume';

  /// Toggle track [index]'s mute. A toggle, not a set: the main window
  /// resolves the flip against repository intent, so a stale overlay snapshot
  /// cannot un-mute a track the pedal just muted.
  static const trackMuteToggle = 'trackMuteToggle';

  /// Toggle track [index]'s FX chain. A toggle for the same staleness reason
  /// as [trackMuteToggle].
  static const trackChainToggle = 'trackChainToggle';

  /// Set input [index]'s live-monitor output gain to [value] (linear gain).
  static const inputVolume = 'inputVolume';

  /// One of the action tokens above; unknown tokens are ignored on receipt.
  final String action;

  /// Track channel or hardware input index, per [action].
  final int index;

  /// Linear gain for the volume actions; meaningless for toggles.
  final double value;

  /// Channel-encodable form.
  Map<String, Object?> toMap() => {
    'action': action,
    'index': index,
    'value': value,
  };

  @override
  List<Object?> get props => [action, index, value];
}
