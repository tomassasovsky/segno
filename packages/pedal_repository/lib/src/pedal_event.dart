import 'package:equatable/equatable.dart';
import 'package:pedal_repository/src/pedal_button.dart';

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

/// The encoder was turned.
///
/// [delta] is signed: positive is clockwise, negative is counter-clockwise.
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
