# cpu_load_repository

Repository for the console's CPU load as a share of the whole machine, where
all cores together are 100%. It reads the cores' idle time from the Linux
kernel's `/proc/stat` and the clock from `/proc/uptime`, and reports a whole
percent. It is pure Dart with no
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
final earlier = parseCpuSample(stat: firstStat, uptime: firstUptime);
final later = parseCpuSample(stat: secondStat, uptime: secondUptime);
if (earlier != null && later != null) {
  print(loadPercent(earlier, later, cores: 4));
}
```

## Notes

- `CpuLoadRepository.system()` returns `CpuLoadRepository.unsupported()` when
  `/proc/stat` or `/proc/uptime` does not exist (the macOS desktop). Its
  `watch()` stream is empty.
- Load is the share of the elapsed time on every online core that was not
  idle: 1 - (idle + I/O wait) / (elapsed time x cores) between two reads.
  Idle and I/O wait come from the aggregate `cpu` line of `/proc/stat`,
  elapsed time from `/proc/uptime`.
- The busy fields of `/proc/stat` (user, system, irq, softirq) are not used
  (#1868). The kernel samples them at the scheduler tick, which misses work
  done in short bursts between ticks. On the console it missed most of the
  audio callback and credited the USB interrupt thread's time in one lump
  every 4.4 s, so an idle console read 0-2% with jumps to 16% while the real
  load was a steady 10%. Idle and I/O wait are measured as each core enters
  and leaves idle.
- `/proc/stat` counts in ticks of `USER_HZ`, a hundredth of a second on Linux
  for arm64 and x86-64; `/proc/uptime` counts seconds to two decimals.
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
