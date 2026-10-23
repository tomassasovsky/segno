# cpu_load_repository

Repository for the console's CPU load as a share of the whole machine, where
all cores together are 100%. It samples the aggregate `cpu` line of the Linux
kernel's `/proc/stat` and reports a whole percent. It is pure Dart with no
Flutter dependency. The app creates it with `CpuLoadRepository.system()` in
`lib/app/run_segno.dart`, and `CpuLoadCubit` feeds the figure to the looper
screen's top bar.

## Usage

```dart
import 'package:cpu_load_repository/cpu_load_repository.dart';

void showLoad() {
  final cpu = CpuLoadRepository.system();
  if (!cpu.isSupported) return;
  final subscription = cpu.watch().listen((percent) => print('CPU $percent%'));
  // Later: subscription.cancel() stops sampling.
}
```

The parsing is also available on its own:

```dart
final earlier = parseProcStat(firstRead);
final later = parseProcStat(secondRead);
if (earlier != null && later != null) print(loadPercent(earlier, later));
```

## Notes

- `CpuLoadRepository.system()` returns `CpuLoadRepository.unsupported()` when
  `/proc/stat` does not exist (the macOS desktop). Its `watch()` stream is
  empty.
- Load is busy time over total time between two reads, summed over the first
  eight fields of the line. Idle and I/O wait count as not busy; the guest
  fields are left out because user and nice already include them.
- `watch()` samples every `interval` (one second by default) only while it
  has a listener. The first value arrives one interval after listening, and a
  value equal to the previous one is not emitted again.

## Testing

```sh
dart test
```

## License

Part of [Segno](../../README.md), licensed under the GNU General Public License
v3.0 or later. See [LICENSE](../../LICENSE).
