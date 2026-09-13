import 'package:controller_repository/controller_repository.dart';
import 'package:equatable/equatable.dart';

/// A MIDI Learn in progress: which device and format it is listening in, and
/// what it has heard.
class MidiLearn extends Equatable {
  /// Creates a [MidiLearn] listening on [device] in [protocol].
  const MidiLearn({
    required this.device,
    required this.protocol,
    this.editingId,
    this.reading,
    this.conflictId,
  });

  /// The device being learned from. Only its messages are read, and while
  /// Learn or the editor is open it dispatches nothing.
  final String device;

  /// The format the next control is read in. Chosen before learning, because
  /// one CC byte cannot say which format it belongs to.
  final MidiProtocol protocol;

  /// The mapping being edited, or `null` for a new one. Its own source never
  /// counts as a conflict.
  final String? editingId;

  /// The complete reading Learn captured, or `null` while still listening.
  final MidiControlEvent? reading;

  /// The saved mapping the captured source overlaps, or `null`. Disabled
  /// mappings count: the accepted design refuses the overlap either way, and
  /// offers Edit existing mapping instead.
  final String? conflictId;

  /// Whether Learn is still waiting for a control.
  bool get isListening => reading == null;

  /// Returns this Learn with [reading] captured and its [conflictId].
  MidiLearn captured(MidiControlEvent reading, {String? conflictId}) =>
      MidiLearn(
        device: device,
        protocol: protocol,
        editingId: editingId,
        reading: reading,
        conflictId: conflictId,
      );

  @override
  List<Object?> get props => [device, protocol, editingId, reading, conflictId];
}
