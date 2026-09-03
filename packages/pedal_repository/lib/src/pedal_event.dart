import 'package:equatable/equatable.dart';
import 'package:pedal_repository/src/pedal_button.dart';
import 'package:pedal_repository/src/pedal_ctrl.dart';

/// A decoded input from the pedal, hardware-agnostic.
///
/// Produced by `PedalRepository` from the board's link messages. The control
/// cubit turns these into looper commands, timing tap / long-press /
/// double-tap from the [ButtonPressed] / [ButtonReleased] timestamps.
sealed class PedalEvent extends Equatable {
  const PedalEvent();
}

/// A pedal button was pressed.
final class ButtonPressed extends PedalEvent {
  /// Creates a [ButtonPressed] event.
  const ButtonPressed(this.button, {this.timestamp = Duration.zero});

  /// The button that was pressed.
  final PedalButton button;

  /// When the press was observed, relative to an arbitrary epoch.
  ///
  /// Stamped by the repository's clock when the message arrived.
  final Duration timestamp;

  @override
  List<Object?> get props => [button, timestamp];

  @override
  String toString() => 'ButtonPressed(${button.name}, $timestamp)';
}

/// A pedal button was released.
final class ButtonReleased extends PedalEvent {
  /// Creates a [ButtonReleased] event.
  const ButtonReleased(this.button, {this.timestamp = Duration.zero});

  /// The button that was released.
  final PedalButton button;

  /// When the release was observed, relative to an arbitrary epoch.
  final Duration timestamp;

  @override
  List<Object?> get props => [button, timestamp];

  @override
  String toString() => 'ButtonReleased(${button.name}, $timestamp)';
}

/// A CTRL jack moved: a footswitch edge, or an expression pedal's travel.
///
/// The board says which kind of pedal it decided is plugged in; the app binds
/// the two to different things, so the kind is part of the control's identity.
final class CtrlChanged extends PedalEvent {
  /// Creates a [CtrlChanged] event.
  const CtrlChanged({
    required this.jack,
    required this.kind,
    required this.value,
  });

  /// Which jack reported.
  final PedalCtrlJack jack;

  /// What the board decided is plugged into it.
  final PedalCtrlKind kind;

  /// `0`..`255`: a switch reports the ends, an expression pedal its travel.
  final int value;

  @override
  List<Object?> get props => [jack, kind, value];

  @override
  String toString() => 'CtrlChanged(${jack.name}, ${kind.name}, $value)';
}

/// The encoder was turned.
///
/// [EncoderDelta.delta] is signed: positive is clockwise, negative is
/// counter-clockwise.
final class EncoderDelta extends PedalEvent {
  /// Creates an [EncoderDelta] event.
  const EncoderDelta(this.delta);

  /// The signed number of detents turned since the previous message.
  final int delta;

  @override
  List<Object?> get props => [delta];

  @override
  String toString() => 'EncoderDelta($delta)';
}
