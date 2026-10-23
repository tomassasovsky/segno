# spawn_process

Starts helper programs with `posix_spawn` through `dart:ffi`, never with
`fork`. `dart:io` `Process.run` and `Process.start` call `fork()` on Linux,
and on the appliance a fork of the app stalls the real-time audio thread for
milliseconds (#1367). This standalone library covers what the app needs from
`Process`. The app and the `wifi_client`, `touch_calibration_client` and
`brightness_client` data clients use it to run the appliance's helper programs.

## Usage

```dart
import 'dart:convert';

import 'package:spawn_process/spawn_process.dart';

// Run to completion, like Process.run.
final result = await runProcess(
  '/usr/bin/segno-wifi-ctl',
  ['status'],
  timeout: const Duration(seconds: 10),
);
print(result.exitCode);
print(result.stdout);

// Start and stream, like Process.start.
final process = await startProcess('journalctl', ['-f']);
process.stdout.transform(utf8.decoder).listen(print);
process.kill(); // SIGTERM to the child's process group
final code = await process.exitCode;
```

## Notes

- Each call runs on its own worker isolate, so the calling isolate never
  blocks. The worker wakes every 100 ms while the child runs.
- The child keeps only stdin, stdout and stderr, and runs in a process group
  of its own. `kill` and a timeout signal the whole group.
- With `timeout`, a child still running is killed with SIGKILL unless
  `killOnTimeout` is `false`.
- Nothing in the app may use `dart:io` `Process`. The VM's own child reaper
  would otherwise collect this package's children, which then fail with a
  "no child process" error. `tool/check_no_dart_process.sh` enforces this in
  CI.
- Works on Linux and macOS.

## Testing

Pure Dart package. The tests start real processes:

```sh
dart test
```

## License

Part of [Segno](../../README.md), licensed under the GNU General Public License
v3.0 or later. See [LICENSE](../../LICENSE).
