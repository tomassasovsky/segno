import 'package:equatable/equatable.dart';
import 'package:pedal_repository/src/pedal_button.dart';
import 'package:pedal_repository/src/pedal_expression_jack.dart';
import 'package:pedal_repository/src/pedal_external_switch.dart';

/// A decoded input from the pedal, hardware-agnostic.
///
/// Produced by `PedalCodec.decode` from a raw MIDI message. The pedal cubit
/// turns these into looper commands, timing tap / long-press / double-tap from
/// the [ButtonPressed] / [ButtonReleased] timestamps.
sealed class PedalEvent extends Equatable {
  const PedalEvent();
}

/// A pedal button was pressed (MIDI NoteOn with velocity > 0).
final class ButtonPressed extends PedalEvent {
  /// Creates a [ButtonPressed] event.
  const ButtonPressed(this.button, {this.timestamp = Duration.zero});

  /// The button that was pressed.
  final PedalButton button;

  /// When the press was observed, relative to an arbitrary epoch.
  ///
  /// Set by the caller of `decode`; the codec itself does not read a clock.
  final Duration timestamp;

  @override
  List<Object?> get props => [button, timestamp];

  @override
  String toString() => 'ButtonPressed(${button.name}, $timestamp)';
}

/// A pedal button was released (MIDI NoteOff, or NoteOn with velocity 0).
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

/// The encoder was turned (relative MIDI CC).
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

/// An external switch's contact changed state.
///
/// ONE event for both edges, unlike the plate's [ButtonPressed] and
/// [ButtonReleased] pair: a latching switch has no press and no release, only
/// a contact that is now closed or now open, and the two hardwares have to
/// arrive here the same way for the setup to decide what a change means.
final class ExternalContactChanged extends PedalEvent {
  /// Creates an [ExternalContactChanged] event.
  const ExternalContactChanged(
    this.switchId, {
    required this.closed,
    this.timestamp = Duration.zero,
  });

  /// Which switch on which jack.
  final PedalExternalSwitch switchId;

  /// Whether the contact is now closed.
  final bool closed;

  /// When the change was observed, relative to an arbitrary epoch.
  final Duration timestamp;

  @override
  List<Object?> get props => [switchId, closed, timestamp];

  @override
  String toString() =>
      'ExternalContactChanged(${switchId.name}, '
      '${closed ? 'closed' : 'open'}, $timestamp)';
}

/// An expression pedal moved.
///
/// [raw] is the UNCALIBRATED reading, `0..1` across the pedal's full electrical
/// range. Which end of it is heel and which is toe this does not say, and
/// cannot: a pedal can be wired either way round, and the travel a given pedal
/// actually reaches is narrower than its range. Turning this into a position
/// is the app's calibration, not the wire's.
final class ExpressionMoved extends PedalEvent {
  /// Creates an [ExpressionMoved] event.
  const ExpressionMoved(this.jack, {required this.raw});

  /// Which jack moved.
  final PedalExpressionJack jack;

  /// The uncalibrated reading, `0..1`.
  final double raw;

  @override
  List<Object?> get props => [jack, raw];

  @override
  String toString() => 'ExpressionMoved(${jack.name}, $raw)';
}
