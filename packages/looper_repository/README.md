# looper_repository

Repository that owns Segno's audio engine. `LooperRepository` polls the
`segno_engine` snapshot, projects it into domain models (`LooperState` with
its `TransportState`, `Track`s and `EngineStatus`), and forwards looper
commands to the engine: start and stop the device, record, play, stop,
undo, mix, routing, input monitoring and effect chains. The package also
holds the effect chain models (`TrackEffect`, `FxRack`, `FxChainEnvelope`),
plugin discovery (`PluginCatalog`) and render jobs. It depends on
`segno_engine` and `fx_catalogue`. It is the app's main repository: the
looper, control, audio setup and FX features read it, and the app never
imports `segno_engine` itself.

## Usage

```dart
import 'package:looper_repository/looper_repository.dart';

Future<void> recordFirstLoop() async {
  final mock = createMockEngine(); // createNativeAudioEngine() on hardware
  final looper = LooperRepository(engine: mock.engine);

  final subscription = looper.looperState.listen((state) {
    for (final track in state.tracks) {
      print('track ${track.channel}: ${track.state}');
    }
  });

  if (looper.startEngine(mock.startConfig).isOk) {
    looper.record(channel: 0);
  }

  // Later:
  await subscription.cancel();
  await looper.dispose();
}
```

## Notes

- The engine is polled about every 16 ms, and only while `looperState` has a
  listener. `meterLevels` and `engineSnapshots` emit on that same poll, so
  they stay quiet without a `looperState` listener.
- `state` walks the engine through FFI on every call. Use `lastState` on a
  timer; use `state` only when the caller must see a write it just made.
- Commands return an `EngineResult` instead of throwing. Many settings are
  confirmed against a receipt the audio callback publishes, so the repository
  knows whether a value was applied or refused. Some refusals are also
  reported on streams such as `recordRefusals`.
- When a specific audio device is lost, the repository tries to reopen it
  once a second until it returns.
- `dispose` stops polling, closes every stream and disposes the engine.

## Testing

```sh
flutter test
```

The `*_native_test.dart` suites and a few others run against the real engine
library and skip themselves unless `SEGNO_ENGINE_LIB` is set:

```sh
export SEGNO_ENGINE_LIB="$(bash ../segno_engine/tool/build_test_lib.sh)"
flutter test
```

## License

Part of [Segno](../../README.md), licensed under the GNU General Public License
v3.0 or later. See [LICENSE](../../LICENSE).
