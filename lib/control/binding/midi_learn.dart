import 'package:controller_repository/controller_repository.dart';
import 'package:equatable/equatable.dart';

/// A MIDI Learn in progress: the format it is listening in, and what it has
/// heard.
class MidiLearn extends Equatable {
  /// Creates a [MidiLearn] listening in [protocol].
  const MidiLearn({required this.protocol, this.reading});

  /// The format the next control is read in. Chosen before learning, because
  /// one CC byte cannot say which format it belongs to.
  final MidiProtocol protocol;

  /// The complete reading Learn captured, or `null` while still listening.
  final MidiControlEvent? reading;

  /// Whether Learn is still waiting for a control.
  bool get isListening => reading == null;

  @override
  List<Object?> get props => [protocol, reading];
}
