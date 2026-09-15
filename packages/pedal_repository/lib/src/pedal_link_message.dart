import 'package:equatable/equatable.dart';
import 'package:pedal_repository/src/pedal_button.dart';
import 'package:pedal_repository/src/pedal_ctrl.dart';
import 'package:pedal_repository/src/pedal_state_frame.dart';

/// One message on the pedal link, in either direction.
///
/// The console board's Pico 2 and segno exchange these over the Pi's uart3.
/// `PedalLinkCodec` is the byte form; a `PedalLink` carries them.
sealed class PedalLinkMessage extends Equatable {
  const PedalLinkMessage();
}

/// A footswitch went down or came up (board → segno).
final class ButtonMessage extends PedalLinkMessage {
  /// Creates a [ButtonMessage].
  const ButtonMessage(this.button, {required this.pressed});

  /// The footswitch.
  final PedalButton button;

  /// `true` on press, `false` on release.
  final bool pressed;

  @override
  List<Object?> get props => [button, pressed];
}

/// The encoder turned (board → segno).
final class EncoderMessage extends PedalLinkMessage {
  /// Creates an [EncoderMessage].
  const EncoderMessage(this.delta)
    : assert(delta >= -128 && delta <= 127, 'delta must fit an int8');

  /// Signed detents since the previous message; positive is clockwise.
  final int delta;

  @override
  List<Object?> get props => [delta];
}

/// A CTRL jack reporting (board → segno): a footswitch edge, or an
/// expression pedal's raw position.
final class CtrlMessage extends PedalLinkMessage {
  /// Creates a [CtrlMessage].
  const CtrlMessage({
    required this.jack,
    required this.kind,
    required this.value,
    this.contact = PedalCtrlContact.tip,
  }) : assert(value >= 0 && value <= 255, 'value must fit a byte'),
       assert(
         contact == PedalCtrlContact.tip || kind == PedalCtrlKind.switchPedal,
         'the ring can only carry a switch',
       ),
       assert(
         kind != PedalCtrlKind.none || value == 0,
         'an empty jack carries no value',
       );

  /// Which jack reported.
  final PedalCtrlJack jack;

  /// Which contact of it.
  final PedalCtrlContact contact;

  /// What the board decided is plugged into it.
  final PedalCtrlKind kind;

  /// `0`..`255`: a switch sends the ends, an expression pedal its RAW
  /// position — uncalibrated; see [PedalCtrlCalibration].
  final int value;

  @override
  List<Object?> get props => [jack, contact, kind, value];
}

/// The board announcing itself (board → segno), at boot and once a second
/// while it runs. Its arrival is what "connected" means; its absence for a
/// few seconds is what "disconnected" means.
final class HelloMessage extends PedalLinkMessage {
  /// Creates a [HelloMessage].
  const HelloMessage({
    required this.protocolVersion,
    required this.firmwareMajor,
    required this.firmwareMinor,
  });

  /// The link protocol the firmware speaks (`PedalLinkCodec.protocolVersion`).
  final int protocolVersion;

  /// Firmware version, major part.
  final int firmwareMajor;

  /// Firmware version, minor part.
  final int firmwareMinor;

  /// `major.minor`, for the settings and About screens.
  String get firmwareVersion => '$firmwareMajor.$firmwareMinor';

  @override
  List<Object?> get props => [protocolVersion, firmwareMajor, firmwareMinor];
}

/// Everything the board renders (segno → board).
final class StateMessage extends PedalLinkMessage {
  /// Creates a [StateMessage].
  const StateMessage(this.frame);

  /// The frame to render.
  final PedalStateFrame frame;

  @override
  List<Object?> get props => [frame];
}
