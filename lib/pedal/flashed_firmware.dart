import 'dart:io';

/// Where `segno-update-ctl flash-pedal` records what it wrote to the pedal.
///
/// On `/data`, not `/etc`: `/etc` lives inside the A/B slot image, so an OS
/// update would erase it — and this describes the attached hardware, not the
/// image.
const kFlashedPedalFirmwarePath = '/data/segno/pedal-firmware-version';

/// Parses the wire-protocol version out of the record the flasher writes,
/// whose format is `<semver> <protocolVersion>` (e.g. `0.2.0 3`).
///
/// Returns `null` for anything it cannot read as a positive protocol number —
/// absent file, truncated write, a future format with extra fields, `0` (the
/// flasher's own "unknown"). `null` means "learn nothing here", which leaves
/// the caller on its existing safety floor rather than encoding at a version
/// the pedal may not speak.
int? parseFlashedPedalProtocolVersion(String? contents) {
  if (contents == null) return null;
  final fields = contents.trim().split(RegExp(r'\s+'));
  if (fields.length < 2) return null;
  final version = int.tryParse(fields[1]);
  if (version == null || version <= 0) return null;
  return version;
}

/// Reads the protocol version the console last flashed onto the pedal, or
/// `null` when nothing was recorded (every desktop build, and any console that
/// has not flashed firmware yet).
///
/// This is the appliance's answer to "what firmware is on the pedal": the
/// flasher is the only thing that ever writes that pedal, so it already knows,
/// and no round trip to the hardware is needed — which matters because segno's
/// 3-byte MIDI capture cannot carry a SysEx identity reply back from it.
Future<int?> readFlashedPedalProtocolVersion({
  String path = kFlashedPedalFirmwarePath,
}) async {
  try {
    final file = File(path);
    if (!file.existsSync()) return null;
    return parseFlashedPedalProtocolVersion(await file.readAsString());
  } on IOException {
    return null;
  }
}

/// The flashed-firmware reader for this build.
const Future<int?> Function() kFlashedPedalProtocolVersionReader =
    readFlashedPedalProtocolVersion;
