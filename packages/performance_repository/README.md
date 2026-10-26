# performance_repository

Repository that owns performance recording: a take of the whole set, written to
disk while it plays. It arms and disarms the engine's capture taps, snapshots
the settled loops and the monitor and master state, finalizes the take into a
`{exports}/perf-YYYYMMDD-HHMMSS/` bundle, starts the offline render of stems,
and recovers takes that a crash or power loss left unfinished. It depends on
the `AudioEngine` interface from `segno_engine`, never on `NativeAudioEngine`,
and on `wav_codec`. The app's performance recorder, session, control and
Library cubits use it.

## Usage

```dart
import 'package:performance_repository/performance_repository.dart';

final performance = PerformanceRepository(
  engine: engine,
  exportsRoot: () async => '$documents/exports',
  guards: guardRegistry,
);

await performance.runBootRecovery(); // once, at startup

performance.captureStatus.listen((status) { /* idle, armed, ... */ });

await performance.arm(chains: chains);
// ... the performance ...
await performance.disarmAndFinalize();

final progress = performance.renderProgress; // poll for the offline render
final takes = await performance.listCaptures();
```

## Notes

- The capture directory is the final bundle from the moment of `arm`. The
  native drain thread writes ordered float WAV parts (`master-001.wav`,
  `input-<n>-001.wav`, ...) and the `performance.json` sidecar straight into
  it; finalize copies no audio.
- `arm` and both disarm calls are idempotent. `disarm` (the toggle gesture)
  ignores a second press inside `disarmGuardWindow`; programmatic callers,
  such as a session load, use `disarmAndFinalize`.
- `arm` does nothing while a salvage finalize or an offline render is in
  progress. Callers see this through `captureStatus` not reporting armed.
- A take holds a `capture` guard (`operation_guards`) from `arm` until it is
  finalized, so a device change, a calibration, a session apply or a shutdown
  sees the take at its own commit. `arm(root: ..., scope: ...)` records to a
  USB volume.

## Testing

```sh
flutter test
```

## License

Part of [Segno](../../README.md), licensed under the GNU General Public License
v3.0 or later. See [LICENSE](../../LICENSE).
