# segno_engine

Segno's native audio engine, written in C, with a typed Dart API over FFI. It
opens the audio device through [miniaudio](https://miniaud.io), runs the
whole real-time signal path on the device callback thread, and publishes its
state for Dart to read. In the layered architecture it is a data client:
`looper_repository` owns the engine, and `session_repository`,
`performance_repository`, `storage_repository`, `backing_repository` and
`instrument_repository` use the same `AudioEngine` interface. `midi_client`
uses the generated bindings directly through `segno_engine_ffi.dart`.

## What the engine does

- **Devices.** Opens a duplex device with up to 32 input and 32 output
  channels, enumerates devices, detects loopback devices, and reopens after a
  device loss without discarding the recorded loops. It meters every channel,
  measures round-trip latency, and reports callback timing
  (`CallbackTelemetry`).
- **Looper.** Eight tracks, each with up to eight lanes. A lane records one
  hardware input into its own mono buffer; the track owns the transport.
  Record, overdub, play, stop and clear, with multi-level undo and redo per
  track and Peel (remove the newest overdub layer). Tracks share one master
  loop clock, with per-track multiples, length presets, quantized record start,
  count-in, overdub decay and One Shot playback. Looper modes: Multi, Sync,
  Song, Band and Free.
- **Track transforms.** Fade, Reverse, Speed, Transpose, length edits, and
  Follow tempo with a pitch mode. Time-stretch and pitch-shift use the
  vendored Signalsmith Stretch library.
- **Tempo and sync.** Tempo, time signature and tap tempo; a click with its
  own modes, outputs, level and pan; MIDI clock send, and following an
  external MIDI clock.
- **Signal path.** A conditioning stage per input (high-pass filter, mains hum
  notches, downward expander). Live monitoring per input with separate wet and
  dry sends. Effect chains of up to 64 entries on each lane, each track, each
  monitored input, the All tracks mix and each output bus. The built-in
  effects are drive, filter, delay, tremolo, octaver, echo and reverb. A
  background worker renders stable lane chains ahead of time (the wet cache).
  Output buses have level, mono, balance and mute; master gain and a limiter
  follow. There is also a tuner.
- **Restoration.** After a loop closes, a background worker can de-clip the
  take and denoise it with RNNoise. The result is one undo layer.
- **Other voices.** A backing player that plays a decoded WAV or MP3 file
  (up to 900 seconds), a Library audition voice, and instruments that play
  built-in synth patches from MIDI notes.
- **MIDI.** Native USB MIDI input and output: Core MIDI on macOS, the ALSA
  sequencer on Linux.
- **Rendering and files.** Performance recording: while armed, a drain thread
  writes the master and monitored inputs to disk as ordered 32-bit float WAV
  parts, and an offline renderer rebuilds dry stems, wet stems and the master
  from the take. Bounce and Save selected audio render chosen tracks offline.
  Session export and import of tracks, layers and undo history. File helpers:
  SHA-256 digests, directory sync, rename without replace, and free space
  (`VolumeSpace`).
- **Plugin hosting.** VST3 and CLAP effects, built only on macOS. Linux builds
  link stubs, so the FFI symbols still resolve.

## The FFI boundary contract

```text
Dart (UI isolate)                         Native engine (C)
─────────────────                         ─────────────────
AudioEngine API  ──► le_engine_post_command ──► SPSC ring ─┐
                                                           ▼
snapshot() ◄── le_engine_get_snapshot ◄── atomics ◄── AUDIO CALLBACK THREAD
```

- **Commands** flow from Dart to the engine through a single-producer,
  single-consumer lock-free ring (`lockfree_ring.[ch]`), drained at the top of
  each callback. Most `le_engine_*` setters validate on the calling thread and
  post to this ring.
- **State** flows from the engine to Dart through per-field atomics.
  `snapshot()` copies them into an `le_snapshot` struct and returns an
  immutable `EngineSnapshot`.
- Some edits (Fade, Reverse, Speed, Transpose, length, Follow tempo, pitch)
  return a `RequestAdmission`. The callback's result for that request is read
  later with `readRequestResult`.
- Dart never blocks or allocates on the audio thread, and the engine never
  calls back into Dart.

### Real-time safety rules (audio callback)

The audio callback (`le_engine_process` in `src/core/engine_process.c`) must
never:

- `malloc`/`free`, take a lock, make a system call, or perform file or
  socket I/O;
- run an unbounded loop or call back into Dart.

Buffers the audio thread writes are allocated on the control thread through
`rt_alloc.h`. On Linux it excludes them from `fork()`, locks them in RAM and
faults them in before use; a background thread keeps a recording's buffer
faulted in ahead of the write head. File writing, rendering, restoration and
the wet cache run on their own threads.

## Layout

| Path | Role |
| --- | --- |
| `src/core/segno_engine_api.h` | The C ABI consumed by ffigen (POD types and an opaque handle). |
| `src/core/` | The portable engine. `engine.c` holds lifecycle and shared helpers, `engine_process.c` is the only audio-thread file, `engine_commands.c` holds the control-thread setters. Other files cover effects, snapshots, sessions, rendering, the performance drain, decoding, the backing player, instruments and file helpers. |
| `src/platform/` | Per-OS device code: `engine_apple.c` and `engine_linux.c`. |
| `src/midi/` | MIDI input, output and clock: `midi.c` plus a backend per OS. |
| `src/stretch/` | The C wrapper over Signalsmith Stretch. |
| `src/host/` | VST3 and CLAP plugin hosting (macOS builds only). |
| `src/miniaudio/` | Vendored miniaudio and `miniaudio_impl.c`. |
| `src/test/` | Native tests, benchmarks and `run_native_tests.sh`. |
| `third_party/` | Vendored CLAP, RNNoise, Signalsmith Stretch and VST3 SDK sources. |
| `vst3/` | A separate build of the seven built-in effects as VST3 plugins. |
| `lib/src/audio_engine.dart` | The `AudioEngine` interface, the test seam. |
| `lib/src/native_audio_engine.dart` | The FFI implementation, `NativeAudioEngine`, and the device-free `PumpedNativeEngine`. |
| `lib/src/mock_audio_engine.dart` | `MockAudioEngine`, an in-memory engine for tests and the mock app. |
| `lib/src/generated/` | ffigen output. Do not edit by hand. |

Every `src/` subdirectory that holds headers is on the compiler include path
(`src/CMakeLists.txt`), so sources use flat includes such as
`#include "engine_private.h"`.

## Building

The plugin builds as part of `flutter run` and `flutter build` on macOS and
Linux. C11 is required for `<stdatomic.h>`.

- **macOS:** Swift Package Manager (`macos/segno_engine/Package.swift`), with
  `macos/segno_engine.podspec` as the CocoaPods fallback. Uses CoreAudio and
  builds plugin hosting.
- **Linux:** `linux/CMakeLists.txt` adds `src/CMakeLists.txt`. On the
  appliance the engine uses ALSA only; on a desktop it prefers JACK, then
  PulseAudio, then ALSA.

### Regenerate FFI bindings

From this directory:

```sh
dart run ffigen --config ffigen.yaml
dart format lib/src/generated/segno_engine_bindings.dart
```

ffigen needs `libclang` (it ships with Xcode and LLVM). The `dart format` step
is required: without it the whole generated file changes on every run.
`tool/check_ffi_symbols.sh` checks that every symbol the bindings look up is
exported by a built `libsegno_engine.so`.

### Run the native tests

From the repository root:

```sh
bash packages/segno_engine/src/test/run_native_tests.sh
```

The script builds and runs the engine and MIDI suites, the race tests and a
decoder fuzz driver with the host toolchain, and on macOS also the plugin
scan and slot tests. It needs no audio device. Each suite prints
"ALL PASSED". Its source list mirrors `src/CMakeLists.txt`; keep the two in
sync when adding a file. CI also runs it with
`EXTRA_CFLAGS="-fsanitize=address -g"` and with
`EXTRA_CFLAGS="-DLE_CALLBACK_TELEMETRY=0"`.

### Run the Dart tests

```sh
flutter test
```

Tests tagged `fuzz` drive the real engine through `PumpedNativeEngine` and
skip unless a test build of the library is available:

```sh
export SEGNO_ENGINE_LIB="$(bash tool/build_test_lib.sh)"
flutter test --tags fuzz
```

## Usage

```dart
final engine = NativeAudioEngine();
final result = engine.start(const EngineConfig(sampleRate: 48000));
if (result.isOk) {
  engine.record(channel: 0); // track 1 starts recording
  engine.record(channel: 0); // the loop closes and defines the master length
  engine.record(channel: 0); // overdub starts
  engine.record(channel: 0); // overdub ends
  engine.undo(channel: 0); // the overdub is removed

  final snap = engine.snapshot(); // levels, track states, latency
}
engine.stop();
engine.dispose();
```

## Latency measurement

`measureLatency()` emits one full-scale impulse on the output and counts the
frames until it returns on the input. The round-trip time appears in
`EngineSnapshot.measuredLatencyMs` when `latencyState` is `LatencyState.done`.
It needs a physical output-to-input loopback (a cable or a loopback device);
without one the harness reports `timeout`.

## License

Part of [Segno](../../README.md), licensed under the GNU General Public License
v3.0 or later. See [LICENSE](../../LICENSE). Vendored code keeps its own
license; see `third_party/README.md` and `src/miniaudio/LICENSE`.
