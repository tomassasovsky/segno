import 'package:controller_repository/controller_repository.dart';
import 'package:segno/l10n/l10n.dart';

/// How a MIDI control is NAMED, in one place: the mapping row, the editor's
/// heading and the power button's accessible name all say the same words.
///
/// Numbers are the ones a controller's manual prints: a CC, Note or Program
/// from 0, a channel from 1.
String midiSourceName(AppLocalizations l10n, MidiSource source) {
  final control = switch (source.protocol) {
    MidiProtocol.standard => switch (source.kind) {
      ControllerSourceKind.midiCc => l10n.midiSourceCc(source.number),
      ControllerSourceKind.midiNote => l10n.midiSourceNote(source.number),
      ControllerSourceKind.midiProgram => l10n.midiSourceProgram(
        source.number,
      ),
      ControllerSourceKind.consoleSwitch ||
      ControllerSourceKind.consoleExpression => throw StateError(
        'Console CTRL is not a MIDI source',
      ),
    },
    MidiProtocol.cc14 => l10n.midiSourceCc14(source.number, source.number + 32),
    MidiProtocol.nrpn => l10n.midiSourceNrpn(source.parameter ?? 0),
    MidiProtocol.bankProgram => l10n.midiSourceBankProgram(
      source.bank ?? 0,
      source.number,
    ),
    MidiProtocol.relative => l10n.midiSourceRelative(source.number),
  };
  final channel = source.channel;
  return channel == null
      ? l10n.midiSourceOnOmni(control)
      : l10n.midiSourceOnChannel(control, channel + 1);
}

/// What Learn received: the value out of the largest the format carries, or
/// the step a relative control moved.
String midiReceivedLine(AppLocalizations l10n, MidiControlEvent event) {
  final delta = event.delta;
  if (delta == null) return l10n.midiReceived(event.value, event.maximum);
  return l10n.midiReceivedSteps(delta.abs(), delta > 0 ? '+$delta' : '$delta');
}

/// The channel a mapping receives on, as its picker button reads.
String midiReceiveLabel(AppLocalizations l10n, int? channel) => channel == null
    ? l10n.midiReceiveOmni
    : l10n.midiReceiveChannel(channel + 1);

/// What a message format is called.
String midiFormatLabel(AppLocalizations l10n, MidiProtocol protocol) =>
    switch (protocol) {
      MidiProtocol.standard => l10n.midiFormatStandard,
      MidiProtocol.cc14 => l10n.midiFormatCc14,
      MidiProtocol.nrpn => l10n.midiFormatNrpn,
      MidiProtocol.bankProgram => l10n.midiFormatBankProgram,
      MidiProtocol.relative => l10n.midiFormatRelative,
    };

/// The line under a message format's name, saying what it reads.
String midiFormatDetail(AppLocalizations l10n, MidiProtocol protocol) =>
    switch (protocol) {
      MidiProtocol.standard => l10n.midiFormatStandardDetail,
      MidiProtocol.cc14 => l10n.midiFormatCc14Detail,
      MidiProtocol.nrpn => l10n.midiFormatNrpnDetail,
      MidiProtocol.bankProgram => l10n.midiFormatBankProgramDetail,
      MidiProtocol.relative => l10n.midiFormatRelativeDetail,
    };
