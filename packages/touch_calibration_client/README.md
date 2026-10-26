# touch_calibration_client

Data client for touchscreen calibration on the Segno appliance. It reads and
writes the libinput calibration matrix of each screen through the
`/usr/bin/segno-touch-ctl` helper, and fits a new matrix from measured taps.
The app's touch calibration page (`TouchCalibrationCubit`) and Displays
settings use it. The app builds it with `createTouchCalibrationClient()`.

## Usage

```dart
import 'package:touch_calibration_client/touch_calibration_client.dart';

final client = createTouchCalibrationClient();
if (await client.isSupported()) {
  final current = await client.read(TouchScreen.main); // null: identity

  // Where the taps landed, and where they were aimed, in 0..1 coordinates.
  final matrix = fitTouchMatrix(
    [(x: 0.12, y: 0.11), (x: 0.88, y: 0.10), (x: 0.51, y: 0.90)],
    [(x: 0.10, y: 0.10), (x: 0.90, y: 0.10), (x: 0.50, y: 0.90)],
  );
  if (matrix != null) {
    await client.apply(TouchScreen.main, matrix); // try it, not stored
    await client.write(TouchScreen.main, matrix); // store and apply
  }
}
```

`TouchScreen` names the two panels by role: `main` and `readout` (the 7"
Track display).

## Notes

- `apply` changes the running calibration only; a reboot or `restore` brings
  back the stored one. `write` stores and applies.
- `fitTouchMatrix` is a least-squares fit. It returns `null` for fewer than
  three points or points on one line.
- The helper runs through `spawn_process`, never `fork`. `apply`, `write` and
  `restore` re-add the touchscreen, so on a timeout the helper is left to
  finish instead of being killed mid-way.
- On macOS, and on Linux without the helper, the factory returns
  `UnsupportedTouchCalibrationClient`.

## Testing

Pure Dart package:

```sh
dart test
```

## License

Part of [Segno](../../README.md), licensed under the GNU General Public License
v3.0 or later. See [LICENSE](../../LICENSE).
