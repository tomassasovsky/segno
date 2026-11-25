import 'dart:convert';
import 'dart:io';

import 'package:ableton_preset/ableton_preset.dart';
import 'package:test/test.dart';

import 'helpers/fixtures.dart';

Matcher _fails(PresetFailure failure) => throwsA(
  isA<AbletonPresetException>().having((e) => e.failure, 'failure', failure),
);

AbletonPreset _decode(String xml) =>
    AbletonPresetReader.decode(gzipped(xml), name: 'Test');

void main() {
  group('AbletonPresetReader.decode', () {
    test('reads the device, its name and folder path', () {
      final preset = AbletonPresetReader.decode(
        gzipped(devicePreset('Drift', [manual('On', true)])),
        name: 'Deep Thing',
        folderPath: ['Instruments', 'Drift', 'Bass'],
      );
      expect(preset.device, 'Drift');
      expect(preset.kind, PresetKind.device);
      expect(preset.name, 'Deep Thing');
      expect(preset.folderPath, ['Instruments', 'Drift', 'Bass']);
    });

    test('reads a Manual value with its stored range', () {
      final preset = _decode(
        devicePreset('Drift', [
          manual('Filter_Frequency', 440, min: 20, max: 20000),
        ]),
      );
      expect(preset.values, {
        'Filter_Frequency': const StoredValue('440', min: 20, max: 20000),
      });
    });

    test('reads a Manual value without a range', () {
      final preset = _decode(devicePreset('Drift', [manual('On', false)]));
      expect(preset.values, {'On': const StoredValue('false')});
    });

    test('reads a childless element with a Value as a parameter', () {
      final preset = _decode(
        devicePreset('Drift', [leaf('Filter_ModSource1', 3)]),
      );
      expect(preset.values, {'Filter_ModSource1': const StoredValue('3')});
    });

    test('keeps the parameters in file order', () {
      final preset = _decode(
        devicePreset('Drift', [leaf('B', 1), leaf('A', 2), leaf('C', 3)]),
      );
      expect(preset.values.keys, ['B', 'A', 'C']);
    });

    test("skips Live's bookkeeping and lists nothing unread", () {
      final preset = _decode(devicePreset('Drift', const []));
      expect(preset.values, isEmpty);
      expect(preset.unread, isEmpty);
    });

    test('lists elements it cannot read as a parameter as unread', () {
      final preset = _decode(
        devicePreset('Operator', [
          '<Envelope><Attack Value="1" /></Envelope>',
          '<Odd><Manual /></Odd>',
          '<Empty />',
          '<WithChildren Value="1"><Child /></WithChildren>',
          leaf('Kept', 1),
        ]),
      );
      expect(preset.values.keys, ['Kept']);
      expect(preset.unread, ['Envelope', 'Odd', 'Empty', 'WithChildren']);
    });

    test('lists a repeated parameter as unread and keeps the first', () {
      final preset = _decode(
        devicePreset('Drift', [leaf('Twice', 1), leaf('Twice', 2)]),
      );
      expect(preset.values, {'Twice': const StoredValue('1')});
      expect(preset.unread, ['Twice']);
    });

    test('reads a range whose bounds do not parse as missing bounds', () {
      final preset = _decode(
        devicePreset('Drift', [
          '<P><Manual Value="1" />',
          '<MidiControllerRange><Min Value="x" /></MidiControllerRange></P>',
        ]),
      );
      expect(preset.values, {'P': const StoredValue('1')});
    });

    test('reads any device, known to Segno or not', () {
      final preset = _decode(
        devicePreset('Operator', [manual('Volume', 0.5, min: 0, max: 1)]),
      );
      expect(preset.device, 'Operator');
      expect(preset.kind, PresetKind.device);
      expect(preset.values.keys, ['Volume']);
    });

    test('reads a rack as its rack device, without parameters', () {
      final preset = _decode(rackPreset('InstrumentGroupDevice'));
      expect(preset.device, 'InstrumentGroupDevice');
      expect(preset.kind, PresetKind.rack);
      expect(preset.values, isEmpty);
      expect(preset.unread, isEmpty);
    });

    test('refuses a rack that holds no device', () {
      expect(
        () => _decode(
          document('<GroupDevicePreset><Device /></GroupDevicePreset>'),
        ),
        _fails(PresetFailure.device),
      );
    });

    test('refuses a document that holds no device', () {
      expect(() => _decode(document('')), _fails(PresetFailure.device));
    });

    test('refuses another schema version', () {
      expect(
        () => _decode(devicePreset('Drift', const [], major: '4')),
        _fails(PresetFailure.schema),
      );
    });

    test('refuses a document that is not an Ableton document', () {
      expect(
        () => _decode('<Other MajorVersion="5"><Drift /></Other>'),
        _fails(PresetFailure.schema),
      );
    });

    test('refuses bytes that are not gzip', () {
      expect(
        () => AbletonPresetReader.decode(
          utf8.encode(devicePreset('Drift', const [])),
          name: 'Plain',
        ),
        _fails(PresetFailure.compression),
      );
      expect(
        () => AbletonPresetReader.decode(const [0x1f, 0x8b], name: 'Short'),
        _fails(PresetFailure.compression),
      );
    });

    test('refuses a damaged gzip stream', () {
      final bytes = gzipped(devicePreset('Drift', driftParameters()));
      final damaged = [...bytes.take(10), ...List.filled(bytes.length, 0xff)];
      expect(
        () => AbletonPresetReader.decode(damaged, name: 'Damaged'),
        _fails(PresetFailure.compression),
      );
    });

    test('refuses a gzip stream cut short anywhere', () {
      final bytes = gzipped(devicePreset('Drift', driftParameters()));
      for (final length in [
        bytes.length - 1,
        bytes.length - 4,
        bytes.length - 8,
        bytes.length - 9,
        bytes.length ~/ 2,
        20,
      ]) {
        expect(
          () =>
              AbletonPresetReader.decode(bytes.sublist(0, length), name: 'Cut'),
          _fails(PresetFailure.compression),
          reason: 'cut at $length of ${bytes.length} bytes',
        );
      }
    });

    test('refuses a document that is not XML', () {
      expect(
        () => _decode('<Ableton MajorVersion="5"><Drift>'),
        _fails(PresetFailure.xml),
      );
    });

    test('refuses a document without a root element', () {
      expect(
        () => _decode('<?xml version="1.0" encoding="UTF-8"?>\n'),
        _fails(PresetFailure.xml),
      );
      expect(() => _decode(''), _fails(PresetFailure.xml));
    });

    test('refuses a document that is not UTF-8', () {
      expect(
        () => AbletonPresetReader.decode(
          gzip.encode([0x3c, 0xff, 0xfe, 0x3e]),
          name: 'Binary',
        ),
        _fails(PresetFailure.xml),
      );
    });
  });

  group('AbletonPresetReader.read', () {
    late Directory directory;

    setUp(() {
      directory = Directory.systemTemp.createTempSync('ableton_preset_');
    });

    tearDown(() => directory.deleteSync(recursive: true));

    test('names the preset after its file', () async {
      final file = File('${directory.path}/Warm Keys.adv')
        ..writeAsBytesSync(gzipped(devicePreset('Drift', [leaf('A', 1)])));
      final preset = await AbletonPresetReader.read(file, folderPath: ['Keys']);
      expect(preset.name, 'Warm Keys');
      expect(preset.folderPath, ['Keys']);
      expect(preset.values.keys, ['A']);
    });

    test('refuses a file that cannot be read', () {
      expect(
        AbletonPresetReader.read(File('${directory.path}/Missing.adv')),
        throwsA(
          isA<AbletonPresetException>()
              .having((e) => e.failure, 'failure', PresetFailure.file)
              .having((e) => e.toString(), 'toString', contains('file')),
        ),
      );
    });
  });

  group('StoredValue', () {
    test('compares by value and range', () {
      const a = StoredValue('1', min: 0, max: 2);
      expect(a, const StoredValue('1', min: 0, max: 2));
      expect(a.hashCode, const StoredValue('1', min: 0, max: 2).hashCode);
      expect(a, isNot(const StoredValue('1', min: 0, max: 3)));
      expect(a.toString(), 'StoredValue(1, 0.0..2.0)');
    });
  });
}
