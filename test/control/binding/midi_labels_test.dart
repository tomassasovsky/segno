import 'package:controller_repository/controller_repository.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/control/binding/midi_labels.dart';
import 'package:segno/l10n/l10n.dart';

MidiSource _source({
  ControllerSourceKind kind = ControllerSourceKind.midiCc,
  int number = 21,
  int? channel = 0,
  MidiProtocol protocol = MidiProtocol.standard,
  int? parameter,
  int? bank,
}) => MidiSource(
  device: 'usb',
  kind: kind,
  number: number,
  channel: channel,
  protocol: protocol,
  parameter: parameter,
  bank: bank,
);

/// The accepted design's names, one for each format.
void main() {
  late AppLocalizations l10n;

  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('en'));
  });

  test('a source reads as the design names it', () {
    expect(midiSourceName(l10n, _source()), 'CC 21 · Ch 1');
    expect(
      midiSourceName(
        l10n,
        _source(kind: ControllerSourceKind.midiNote, number: 60),
      ),
      'Note 60 · Ch 1',
    );
    expect(
      midiSourceName(
        l10n,
        _source(kind: ControllerSourceKind.midiProgram, number: 8, channel: 9),
      ),
      'Program 8 · Ch 10',
    );
    expect(
      midiSourceName(l10n, _source(protocol: MidiProtocol.cc14)),
      'CC 21 / 53 · 14-bit · Ch 1',
    );
    expect(
      midiSourceName(
        l10n,
        _source(protocol: MidiProtocol.nrpn, number: 6, parameter: 259),
      ),
      'NRPN 259 · Ch 1',
    );
    expect(
      midiSourceName(
        l10n,
        _source(
          kind: ControllerSourceKind.midiProgram,
          protocol: MidiProtocol.bankProgram,
          number: 8,
          bank: 260,
        ),
      ),
      'Bank 260 · Program 8 · Ch 1',
    );
    expect(
      midiSourceName(
        l10n,
        _source(protocol: MidiProtocol.relative, number: 22),
      ),
      'CC 22 · Relative · Ch 1',
    );
    expect(midiSourceName(l10n, _source(channel: null)), 'CC 21 · Omni');
  });

  test('what Learn received', () {
    expect(
      midiReceivedLine(
        l10n,
        MidiControlEvent(source: _source(), value: 8193, maximum: 16383),
      ),
      'Received 8193 / 16383',
    );
    expect(
      midiReceivedLine(
        l10n,
        MidiControlEvent(
          source: _source(),
          value: 127,
          maximum: 127,
          delta: -1,
        ),
      ),
      'Received -1 step',
    );
    expect(
      midiReceivedLine(
        l10n,
        MidiControlEvent(source: _source(), value: 3, maximum: 127, delta: 3),
      ),
      'Received +3 steps',
    );
  });

  test('the channel and the formats', () {
    expect(midiReceiveLabel(l10n, 0), 'Receive · Channel 1');
    expect(midiReceiveLabel(l10n, null), 'Receive · Omni');
    expect(
      [for (final p in MidiProtocol.values) midiFormatLabel(l10n, p)],
      [
        'CC, Note or Program',
        '14-bit CC',
        'NRPN',
        'Bank + Program',
        'Relative CC',
      ],
    );
    expect(
      midiFormatDetail(l10n, MidiProtocol.relative),
      'Two’s complement · 1 up, 127 down',
    );
  });
}
