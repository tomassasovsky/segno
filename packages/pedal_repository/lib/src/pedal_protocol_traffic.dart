import 'package:controller_repository/controller_repository.dart';
import 'package:pedal_repository/src/pedal_button.dart';
import 'package:pedal_repository/src/pedal_codec.dart';
import 'package:pedal_repository/src/pedal_expression_jack.dart';
import 'package:pedal_repository/src/pedal_external_switch.dart';

/// Whether [input] is the Segno pedal talking its own protocol — one of the
/// fixed footswitch notes ([PedalButtonNote]) or the relative encoder CC
/// ([PedalCodec.encoderCc]).
///
/// MIDI-learn passes this to `ControllerRepository` as its ignore filter (B8).
/// The pedal and any third-party controller share ONE MIDI input stream, so
/// without it a stomp — or a nudge of the encoder — during a capture would
/// bind a control the app already owns end to end, and the pedal would start
/// doing two things at once.
///
/// It lives here because this package owns the wire contract those numbers come
/// from: `pedal_repository` already depends on `controller_repository`, so the
/// predicate can be stated once, against the real tables, instead of mirrored
/// into a package that would have no way to notice the pedal renumbering.
///
/// Channel-agnostic: the pedal's own traffic is ignored whatever channel it
/// arrives on, since a capture that is wrong on channel 0 is wrong on all of
/// them.
bool isPedalProtocolInput(RawControllerInput input) => switch (input.kind) {
  // The ten footswitches, and the two jacks' external switches after them:
  // both are the console board's own traffic, dispatched by the pedal setup,
  // and a learned MIDI binding on either would run the same stomp twice.
  ControllerSourceKind.midiNote =>
    PedalButtonNote.fromNote(input.id) != null ||
        PedalExternalSwitchNote.fromNote(input.id) != null,
  ControllerSourceKind.midiCc =>
    input.id == PedalCodec.encoderCc ||
        PedalExpressionJackCc.fromCc(input.id) != null,
  ControllerSourceKind.midiProgram => false,
};
