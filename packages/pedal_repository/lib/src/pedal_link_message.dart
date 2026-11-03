import 'package:equatable/equatable.dart';
import 'package:pedal_repository/src/pedal_ambient_light.dart';
import 'package:pedal_repository/src/pedal_button.dart';
import 'package:pedal_repository/src/pedal_ctrl.dart';
import 'package:pedal_repository/src/pedal_power.dart';
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

/// The encoder's push switch went down or came up (board → segno).
final class EncoderButtonMessage extends PedalLinkMessage {
  /// Creates an [EncoderButtonMessage].
  const EncoderButtonMessage({required this.pressed});

  /// `true` on press, `false` on release.
  final bool pressed;

  @override
  List<Object?> get props => [pressed];
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
  /// position; calibration belongs to the application setup.
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

/// The USB-C supply's contract and the PD trigger's profile (board → segno),
/// once a second after the hello.
final class PdStatusMessage extends PedalLinkMessage {
  /// Creates a [PdStatusMessage].
  const PdStatusMessage(this.supply);

  /// What the board read from the trigger.
  final PedalPowerSupply supply;

  @override
  List<Object?> get props => [supply];
}

/// The light at the plate (board → segno, #1564), once a second after the
/// hello from a board that knows the message (firmware 2.7 and later).
final class AmbientLightMessage extends PedalLinkMessage {
  /// Creates an [AmbientLightMessage].
  const AmbientLightMessage(this.light);

  /// What the board read.
  final PedalAmbientLight light;

  @override
  List<Object?> get props => [light];
}

/// How bright the console's LEDs are (segno → board, #1564): the pills and
/// the ring at [level] of 255, the full brightness every earlier build shows.
///
/// Optional on the wire: a board that does not know the type drops it and
/// stays at full brightness.
final class LedLevelMessage extends PedalLinkMessage {
  /// Creates a [LedLevelMessage].
  const LedLevelMessage(this.level)
    : assert(level >= 1 && level <= 255, 'level must be 1..255');

  /// `1`..`255` of full output. Dark is the state frame's goodbye.
  final int level;

  @override
  List<Object?> get props => [level];
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

/// How far a clear-track hold has run on one pill (segno → board, #1534).
///
/// While the hold is pending the board draws red growing from both ends of
/// [button]'s pill toward its centre, by [progress]. segno sends one every
/// `PedalLinkCodec.clearHoldIntervalMs` while the hold runs, and one with no
/// [button] when it settles.
///
/// Optional on the wire: a board that does not know the type drops it and
/// keeps rendering the state frame, so it shows no fill and nothing wrong.
final class ClearHoldMessage extends PedalLinkMessage {
  /// Creates a [ClearHoldMessage]; no [button] ends the fill.
  const ClearHoldMessage({this.button, this.progress = 0})
    : assert(progress >= 0 && progress <= 255, 'progress must fit a byte'),
      assert(button != null || progress == 0, 'no fill without a button');

  /// The footswitch whose pill fills, or `null` for none.
  final PedalButton? button;

  /// `0`..`254`: how much of the hold has run. 255 is the hold firing, sent
  /// once: the ends meet and the board flashes the pill to confirm the clear.
  final int progress;

  @override
  List<Object?> get props => [button, progress];
}
