import 'dart:ffi';
import 'dart:io';

/// Opens the bundled native engine library for the current platform.
///
/// On Apple platforms the engine is compiled directly into the application
/// binary (Swift Package Manager static-links the plugin into the Runner; the
/// CocoaPods fallback embeds it as a framework). In both cases its exported
/// symbols live in the process's global namespace, so [DynamicLibrary.process]
/// resolves them — there is no standalone library file to open. This relies on
/// the `LE_EXPORT` symbols being marked `visibility("default")` + `used` so the
/// linker keeps them. See macos/segno_engine/Package.swift.
///
/// On Linux/Windows the engine is a separate shared library opened by name.
///
/// A `SEGNO_ENGINE_LIB` environment variable overrides the lookup with an
/// explicit path on every platform — how the device-free test suites (the
/// sequence fuzzer via `PumpedNativeEngine`) point at a freshly built library
/// outside an app bundle.
///
/// Shared by `NativeAudioEngine` and the engine-free `NativeStorageIo`, which
/// opens it inside whatever isolate it is constructed in.
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
