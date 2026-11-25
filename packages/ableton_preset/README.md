# ableton_preset

<!-- cspell:words adv adg -->

Reads Ableton Live device presets from the user's own library (SEG-109).
Pure Dart, no Flutter dependency.

- `AbletonPresetReader` reads one `.adv` (a device) or `.adg` (a rack):
  gunzip, XML, the schema check (`<Ableton MajorVersion="5">`), then every
  parameter of the device with its stored value and `MidiControllerRange`.
  The result is an `AbletonPreset` with the device's element name, the
  preset's name and folder path, the values, and the elements it could not
  read. A rack is read as its rack device, without parameters.
- A `DeviceSchema` types a device's values. `DriftSchema` covers all 83
  parameters Drift stores: numbers clamped to the stored range, stepped
  integers, switches, and choices named in stored order (the oscillator
  types, modulation sources, matrix targets, voice modes and filter types).
  `DeviceValues` lists the parameters it could not map and the ones the
  preset does not store.
- `PresetLibrary.scan` walks a folder (a USB drive, Internal, or Live's own
  `Ableton Live Devices`), reads each preset once, and lists them by device
  with Live's folder names. Each entry is playable (Drift), an unsupported
  device, a rack, or unreadable with the reason.

## Boundary

No Ableton presets, files or data are in this package or its tests. The
tests write their own fixtures: small XML documents with invented values,
gzipped in the test. Drift's parameter names, ranges and option order come
from the behavior description in
`docs/brainstorm/2026-11-24-ableton-devices-brainstorm-doc.md`.

## Usage

```dart
import 'dart:io';

import 'package:ableton_preset/ableton_preset.dart';

final library = await PresetLibrary.scan(Directory('/media/usb/Presets'));
for (final entry in library.byDevice['Drift'] ?? const <LibraryEntry>[]) {
  final values = DriftSchema().read(entry.preset!);
  print('${entry.folderPath.join(' / ')} / ${entry.name}: '
      '${values.values['Oscillator1_Type']}');
}
```
