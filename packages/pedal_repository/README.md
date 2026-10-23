# pedal_repository

Repository for the Segno console board, the foot-operated controller built
into the appliance. It turns messages from the board (footswitches, the
encoder, the CTRL inputs, hellos) into `PedalEvent`s, and sends the board
`PedalStateFrame`s that set its LEDs. The binary link format
(`PedalLinkCodec`) is shared byte for byte with the board's RP2350 firmware
(`firmware/console_board/pedal_link.h`). The app creates one
`PedalRepository` in `lib/app/run_segno.dart`.

## Usage

```dart
import 'package:pedal_repository/pedal_repository.dart';

final link = isAppliance ? UartPedalLink(log: print) : NoopPedalLink();
final pedal = PedalRepository(link, log: print);

pedal.events.listen((event) {
  switch (event) {
    case ButtonPressed(:final button, :final timestamp):
      print('$button down at $timestamp');
    case EncoderDelta(:final delta):
      print('encoder $delta');
    default:
      break;
  }
});

pedal.statusChanges.listen((status) { /* disconnected, connected, ... */ });

// A frame projected from looper state; identical frames are not resent.
pedal.pushState(frame);
```

## Notes

- `UartPedalLink` opens `/dev/ttyAMA3` (the Pi 5's uart3) at 115200 baud,
  raw 8N1, through `termios` over FFI with no helper process. It retries
  while the device cannot be opened. It is Linux only.
- Link status comes from traffic: the board sends a hello every second, and
  the link reads as disconnected after three missed hellos. Each hello is
  answered with the last frame.
- If a hello names another `PedalLinkCodec.protocolVersion`, the status is
  `incompatible`; the repository then drops the board's input and sends no
  frames until one side is updated.
- `package:pedal_repository/testing.dart` provides `FakePedalLink` for driving
  a real `PedalRepository` in tests.

## Testing

```sh
flutter test
```

The firmware side of the link is tested against the golden fixtures in
`test/fixtures/`, which the Dart codec generates. Run it from the repository
root whenever this package or `firmware/` changes:

```sh
bash firmware/test/run_tests.sh
```

After changing `test/helpers/golden_frames.dart`, regenerate the fixtures
from this directory with `flutter test tool/generate_golden_fixtures.dart`.

## License

Part of [Segno](../../README.md), licensed under the GNU General Public License
v3.0 or later. See [LICENSE](../../LICENSE).
