# console_facts_client

Data client for facts that only the Segno appliance image knows about itself:
how the disk is used (sessions, captures, plugins, system, free space), what
the console is (serial number, system image build, display panel names, the
firmware last flashed onto the console board), and how many Bluetooth
pairings an earlier build left on the data volume. It is pure Dart with no
Flutter dependency. The app creates it in `lib/app/run_segno.dart`; the
System Storage and About pages and the startup notices read it.

## Usage

```dart
import 'package:console_facts_client/console_facts_client.dart';

Future<void> printFacts({
  required Future<String> Function() sessionsRoot,
  required Future<String> Function() capturesRoot,
  required Future<DiskSpace?> Function(String path) diskSpace,
}) async {
  final client = createConsoleFactsClient(
    sessionsRoot: sessionsRoot,
    capturesRoot: capturesRoot,
    diskSpace: diskSpace,
  );

  final usage = await client.storage();
  if (usage.known) print('${usage.freeBytes} bytes free');

  final facts = await client.facts();
  if (facts.serial.isNotEmpty) print('Serial ${facts.serial}');
}
```

## Notes

- `createConsoleFactsClient` returns `FakeConsoleFactsClient` when the app is
  built with `--dart-define=SEGNO_FAKE_RADIOS=true`,
  `LocalConsoleFactsClient` on Linux and macOS, and
  `UnsupportedConsoleFactsClient` everywhere else.
- Missing values are explicit, not zero: `StorageUsage.known` is false when
  the disk cannot be read, and every `ConsoleFacts` string is empty when its
  source file is missing. Callers hide the row instead of drawing a default.
- `LocalConsoleFactsClient` only reads files (the device tree serial number,
  `/etc/segno/build-version`, the panel names under `/sys/class/drm`, the
  console board flash record under `/data/segno`) and never starts a
  process. Volume capacity comes from the caller's `diskSpace` function; the
  app passes the engine's `statvfs` reading.
- Parts of the real client are not implemented yet: `deleteCapturesOlderThan`
  deletes nothing and returns 0, and `StorageUsage.pluginBytes` is always 0
  (plugin data is counted in `systemBytes`).

## Testing

```sh
dart test
```

## License

Part of [Segno](../../README.md), licensed under the GNU General Public License
v3.0 or later. See [LICENSE](../../LICENSE).
