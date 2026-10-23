# backing_repository

Repository for Segno's backing player. `BackingAssetStore` keeps the managed
store of backing tracks, and `BackingRepository` drives the audio engine's
backing voice: loading a file, staging the next one, transport, level, pan,
output, and recovery after an engine restart. It depends on `segno_engine` and
never on the UI. The app builds one in `lib/app/run_segno.dart`, and the
backing and looper features read it.

## Usage

```dart
import 'package:backing_repository/backing_repository.dart';
import 'package:segno_engine/segno_engine.dart' show AudioEngine;

Future<void> playBacking(
  AudioEngine engine,
  Future<String> Function() exportsRoot,
  String sourcePath,
) async {
  final decoder = createNativeAudioDecoder();
  final backing = BackingRepository.forEngine(
    engine,
    decoder: decoder,
    store: BackingAssetStore(
      root: exportsRoot,
      decoder: decoder,
      copier: internalBackingCopier(exportsRoot),
    ),
  );
  backing.failures.listen((failure) => print(failure.reason));

  final asset = await backing.store.import(sourcePath);
  backing.setEnd(BackingEnd.repeat);
  await backing.load(asset.digest, play: true);
}
```

## Notes

- Store layout: `<root>/Backing tracks/<first 16 hex digits of the digest>/`
  holds the copied file and an `info.json`. An asset's identity is the full
  SHA-256 of its bytes (`sha256:<64 hex>`), checked again before every load.
- `import` copies the file, decodes all of it to validate it, and checks the
  copy's digest before it publishes `info.json`. On failure nothing new is
  left in the store. Only `.wav` and `.mp3` files are accepted.
- After an engine restart the repository sends the saved End, level, pan,
  output and click pan settings again, leaves the transport stopped, and
  loads the current and staged files again if the restart freed them. If the
  backing was playing, `notices` emits `BackingNotice.interfaceChanged`.
- The default digest and directory sync call the native engine library, so a
  test without that library must inject `digester` and `syncDirectory`.

## Testing

```sh
flutter test
```

`test/native_backing_repository_test.dart` runs against the real engine
library and skips itself unless `SEGNO_ENGINE_LIB` is set:

```sh
export SEGNO_ENGINE_LIB="$(bash ../segno_engine/tool/build_test_lib.sh)"
flutter test
```

## License

Part of [Segno](../../README.md), licensed under the GNU General Public License
v3.0 or later. See [LICENSE](../../LICENSE).
