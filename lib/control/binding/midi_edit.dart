import 'package:equatable/equatable.dart';
import 'package:segno/control/binding/midi_learn.dart';

/// The route/draft lifetime that pauses one device's remote assignments.
class MidiEdit extends Equatable {
  /// Creates an editor owned by [owner].
  const MidiEdit({
    required this.device,
    required this.owner,
    this.learn,
    this.learnTimedOut = false,
  });

  /// Stable device identity.
  final String device;

  /// Route/draft owner; an older page cannot end a replacement editor.
  final Object owner;

  /// Learning capture, if any.
  final MidiLearn? learn;

  /// Whether the last capture expired without receiving a complete input.
  final bool learnTimedOut;

  /// Replaces or clears Learn within the same editor lifetime.
  MidiEdit withLearn(MidiLearn? learn, {bool timedOut = false}) => MidiEdit(
    device: device,
    owner: owner,
    learn: learn,
    learnTimedOut: timedOut,
  );

  @override
  List<Object?> get props => [device, owner, learn, learnTimedOut];
}

/// Explicit confirmed Save outcome; equality of live values is not a receipt.
class MidiSaveResult {
  /// A confirmed mutation, including the committed identity for a new mapping.
  const MidiSaveResult.saved({this.mappingId}) : saved = true, error = null;

  /// A refused mutation; the complete editor draft should remain open.
  const MidiSaveResult.refused(this.error) : saved = false, mappingId = null;

  /// Whether storage confirmed the requested envelope.
  final bool saved;

  /// Stable identity allocated by the serialized Save transaction.
  final String? mappingId;

  /// A refusal description, independent of current-value equality.
  final String? error;
}
