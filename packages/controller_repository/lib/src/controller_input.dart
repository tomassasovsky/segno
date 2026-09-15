import 'package:equatable/equatable.dart';

/// The kind of hardware input that produced a [RawControllerInput].
enum ControllerSourceKind {
  /// A MIDI Note On/Off message.
  midiNote,

  /// A MIDI Control Change message.
  midiCc,

  /// A MIDI Program Change message: a number with no value.
  midiProgram;

  /// Maps a persisted [name] back to a kind, or `null` when it names none.
  static ControllerSourceKind? fromName(String? name) {
    for (final kind in values) {
      if (kind.name == name) return kind;
    }
    return null;
  }
}

/// One raw MIDI message: its kind, number, value and channel.
class RawControllerInput extends Equatable {
  /// Creates a [RawControllerInput].
  const RawControllerInput({
    required this.kind,
    required this.id,
    required this.value,
    this.midiChannel = 0,
  });

  /// The source kind.
  final ControllerSourceKind kind;

  /// The control number: MIDI note or CC number.
  final int id;

  /// The momentary value: note velocity or CC value.
  final int value;

  /// The MIDI channel this message arrived on (`0..15`).
  final int midiChannel;

  @override
  List<Object?> get props => [kind, id, value, midiChannel];

  @override
  String toString() =>
      'RawControllerInput(${kind.name}#$id@$midiChannel = $value)';
}
