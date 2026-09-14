import 'package:equatable/equatable.dart';
import 'package:segno/control/binding/midi_learn.dart';

/// The MIDI mapping editor being open.
///
/// While it is, the device it edits dispatches nothing: the accepted design
/// pauses a controller for editing as well as for Learn, so moving the control
/// being set up cannot change the rig underneath the editor.
class MidiEdit extends Equatable {
  /// Creates a [MidiEdit] on [device].
  const MidiEdit({
    required this.device,
    this.editingId,
    this.learn,
    this.learnTimedOut = false,
  });

  /// The device whose mappings are being edited, by its stable identity. It
  /// stays paused while the editor is open, connected or not.
  final String device;

  /// The saved mapping being edited, or `null` for a new one. Its own source
  /// never counts as a conflict.
  final String? editingId;

  /// The Learn in progress, or `null`.
  final MidiLearn? learn;

  /// Whether the last Learn ended because nothing arrived in time. Cleared by
  /// the next Learn.
  final bool learnTimedOut;

  /// Returns this edit with [learn] in place, or with none when [learn] is
  /// `null`.
  MidiEdit withLearn(MidiLearn? learn, {bool timedOut = false}) => MidiEdit(
    device: device,
    editingId: editingId,
    learn: learn,
    learnTimedOut: timedOut,
  );

  @override
  List<Object?> get props => [device, editingId, learn, learnTimedOut];
}
