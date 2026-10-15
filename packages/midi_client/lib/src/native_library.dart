// The platform shared-library loader cannot be exercised in a unit test (it
// resolves a real native library by name / process namespace). Excluded from
// coverage, like the generated FFI bindings.
// coverage:ignore-file
import 'dart:ffi';
import 'dart:io';

/// Opens the bundled `segno_engine` native library for the current platform.
///
/// Shared by every MIDI FFI wrapper in this package (`MidiClient` for input,
/// `MidiOutClient` for output): the MIDI symbols (`le_midi_*` / `le_midi_out_*`)
/// are exported from the same library as the audio engine. On Apple platforms
/// they live in the process's global namespace (static-linked into the Runner),
/// so [DynamicLibrary.process] resolves them; on Linux/Windows the engine is a
/// separate shared library opened by name.
///
/// A `SEGNO_ENGINE_LIB` environment variable overrides the lookup with an
/// explicit path, exactly as the audio engine's loader does — the two must
/// open the same file. The appliance image sets it, because ivi-homescreen
/// does not put the bundle's `lib/` on the loader's path.
DynamicLibrary openSegnoEngineLibrary() {
  final override = Platform.environment['SEGNO_ENGINE_LIB'];
  if (override != null && override.isNotEmpty) {
    return DynamicLibrary.open(override);
  }
  if (Platform.isMacOS || Platform.isIOS) {
    return DynamicLibrary.process();
  }
  if (Platform.isWindows) return DynamicLibrary.open('segno_engine.dll');
  return DynamicLibrary.open('libsegno_engine.so');
}
