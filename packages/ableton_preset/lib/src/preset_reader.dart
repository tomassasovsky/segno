// cspell:words ISIZE Timeable

import 'dart:convert';
import 'dart:io';

import 'package:ableton_preset/src/ableton_preset.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

/// Why a preset file could not be read.
enum PresetFailure {
  /// The file could not be opened or read.
  file,

  /// Not gzip, or the gzip stream is cut short or damaged.
  compression,

  /// Not well-formed XML (or not UTF-8).
  xml,

  /// Not an `<Ableton>` document of the schema this reader knows
  /// (`MajorVersion="5"`, Live 11 and 12).
  schema,

  /// The document holds no device.
  device,
}

/// A preset file that could not be read, and why.
final class AbletonPresetException implements Exception {
  /// A failure to read a preset.
  const new(this.failure, this.message);

  /// Which stage of reading failed.
  final PresetFailure failure;

  /// What went wrong, for logs.
  final String message;

  @override
  String toString() => 'AbletonPresetException(${failure.name}): $message';
}

/// The schema version this reader understands.
const presetMajorVersion = '5';

/// Children of a device element that are Live's own bookkeeping (browser,
/// view and automation state, the preset's own metadata), not parameters.
const _ignored = {
  'Annotation',
  'BreakoutIsExpanded',
  'IsExpanded',
  'IsFolded',
  'LastPresetRef',
  'LastSelectedClipEnvelopeIndex',
  'LastSelectedTimeableIndex',
  'LockedScripts',
  'LomId',
  'LomIdView',
  'ModulationSourceCount',
  'MpePitchBendUsesTuning',
  'OverwriteProtectionNumber',
  'ParametersListWrapper',
  'Pointee',
  'ShouldShowPresetName',
  'SourceContext',
  'UserName',
};

/// Reads Live device presets: `.adv` (one device) and `.adg` (a rack).
abstract final class AbletonPresetReader {
  /// Reads the preset file at [file]. [folderPath] is where the file sits
  /// in its library (see [AbletonPreset.folderPath]).
  ///
  /// Throws an [AbletonPresetException] when the file cannot be read.
  static Future<AbletonPreset> read(
    File file, {
    List<String> folderPath = const [],
  }) async {
    final List<int> bytes;
    try {
      bytes = await file.readAsBytes();
    } on FileSystemException catch (error) {
      throw AbletonPresetException(PresetFailure.file, error.toString());
    }
    return decode(
      bytes,
      name: p.basenameWithoutExtension(file.path),
      folderPath: folderPath,
    );
  }

  /// Reads a preset from the gzip-compressed bytes of its file.
  ///
  /// Throws an [AbletonPresetException] when the bytes are not a preset.
  static AbletonPreset decode(
    List<int> bytes, {
    required String name,
    List<String> folderPath = const [],
  }) {
    final root = _root(_gunzip(bytes));
    if (root.name.local != 'Ableton' ||
        root.getAttribute('MajorVersion') != presetMajorVersion) {
      throw AbletonPresetException(
        PresetFailure.schema,
        'expected <Ableton MajorVersion="$presetMajorVersion">, found '
        '<${root.name.local} '
        'MajorVersion="${root.getAttribute('MajorVersion')}">',
      );
    }
    final element = root.childElements.firstOrNull;
    if (element == null) {
      throw const AbletonPresetException(
        PresetFailure.device,
        'the document holds no device',
      );
    }
    if (element.name.local == 'GroupDevicePreset') {
      final rack = element.getElement('Device')?.childElements.firstOrNull;
      if (rack == null) {
        throw const AbletonPresetException(
          PresetFailure.device,
          'the rack preset holds no device',
        );
      }
      return AbletonPreset(
        device: rack.name.local,
        kind: PresetKind.rack,
        name: name,
        folderPath: folderPath,
        values: const {},
        unread: const [],
      );
    }
    final values = <String, StoredValue>{};
    final unread = <String>[];
    for (final child in element.childElements) {
      final key = child.name.local;
      if (_ignored.contains(key)) continue;
      final value = _parameter(child);
      if (value == null || values.containsKey(key)) {
        unread.add(key);
      } else {
        values[key] = value;
      }
    }
    return AbletonPreset(
      device: element.name.local,
      kind: PresetKind.device,
      name: name,
      folderPath: folderPath,
      values: values,
      unread: unread,
    );
  }

  /// A parameter is an element holding `<Manual Value=...>` (with its
  /// `<MidiControllerRange>` when stored), or a childless element with a
  /// `Value` attribute (the enum selectors, such as `Filter_ModSource1`).
  static StoredValue? _parameter(XmlElement element) {
    final manual = element.getElement('Manual');
    if (manual != null) {
      final raw = manual.getAttribute('Value');
      if (raw == null) return null;
      final range = element.getElement('MidiControllerRange');
      return StoredValue(
        raw,
        min: _number(range?.getElement('Min')),
        max: _number(range?.getElement('Max')),
      );
    }
    final raw = element.getAttribute('Value');
    if (raw == null || element.childElements.isNotEmpty) return null;
    return StoredValue(raw);
  }

  static double? _number(XmlElement? element) {
    final raw = element?.getAttribute('Value');
    return raw == null ? null : double.tryParse(raw);
  }

  /// `dart:io`'s decoder returns what it could decode from a cut-short
  /// stream without complaint, so the trailer's size (ISIZE, the last four
  /// bytes, little-endian, modulo 2^32) is checked against the output. Live
  /// writes one gzip member per file.
  static List<int> _gunzip(List<int> bytes) {
    if (bytes.length < 18 || bytes[0] != 0x1f || bytes[1] != 0x8b) {
      throw const AbletonPresetException(PresetFailure.compression, 'not gzip');
    }
    final List<int> out;
    try {
      out = gzip.decode(bytes);
    } on FormatException catch (error) {
      throw AbletonPresetException(PresetFailure.compression, error.message);
    }
    final n = bytes.length;
    final size =
        bytes[n - 4] |
        bytes[n - 3] << 8 |
        bytes[n - 2] << 16 |
        bytes[n - 1] << 24;
    if (size != out.length & 0xffffffff) {
      throw AbletonPresetException(
        PresetFailure.compression,
        'the gzip stream is cut short or damaged: the trailer says $size '
        'bytes, ${out.length} decoded',
      );
    }
    return out;
  }

  /// The document's root element. `package:xml` reports every parse
  /// error as a [FormatException].
  static XmlElement _root(List<int> bytes) {
    final XmlDocument document;
    try {
      document = XmlDocument.parse(utf8.decode(bytes));
    } on FormatException catch (error) {
      throw AbletonPresetException(PresetFailure.xml, error.message);
    }
    final root = document.childElements.firstOrNull;
    if (root == null) {
      throw const AbletonPresetException(
        PresetFailure.xml,
        'the document has no root element',
      );
    }
    return root;
  }
}
