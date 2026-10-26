# operation_guards

Standalone library that holds one table of which appliance operations may
commit while others are in flight: a performance capture, applying or writing
a session, a USB transfer or eject, an audio device change, a calibration,
and a restart. Each owner checks the table at its commit point, not when its
dialog opens. It is pure Dart with no Flutter dependency.
`performance_repository`, `session_repository` and `storage_repository`
enter guards through it, and the app's storage, library, session and
performance cubits read it (the Storage page, for example, disables Eject
and shows what is blocking it). The app creates one `GuardRegistry` and
shares it.

## Usage

```dart
import 'package:operation_guards/operation_guards.dart';

final registry = GuardRegistry();

void saveSession(String bundlePath) {
  final scope = GuardScope.internal(item: bundlePath);
  try {
    final guard = registry.enter(
      GuardKind.sessionWrite,
      scope,
      purpose: 'Saving session',
    );
    try {
      // Write the bundle.
    } finally {
      guard.release();
    }
  } on GuardRefused catch (refused) {
    print('Blocked by ${refused.blockers.map((op) => op.purpose)}');
  }
}

// To disable a control ahead of time:
final blocked = registry.blockers(GuardKind.eject, const GuardScope.removable(3));
```

## Notes

- `GuardRegistry.ruleFor(wants, active)` returns the rule from the table:
  `allow`, `refuse`, `refuseSameVolume` or `refuseSameItem`. A scope is
  Internal storage or one removable volume generation (a replug is a new
  generation), optionally narrowed to one item such as a session bundle.
- `enter` checks the table and registers the guard in one synchronous step.
  All owners run on one isolate, so no other operation can commit between the
  check and the registration.
- `blockers` is only for showing state. The commit itself must still call
  `enter`.
- An owner that already tracks its own operations implements
  `ActiveOperationSource` and is added with `addSource`; the USB storage
  service reports its write leases and ejects this way.
- `OperationGuard.release` can be called more than once.

## Testing

```sh
dart test
```

## License

Part of [Segno](../../README.md), licensed under the GNU General Public License
v3.0 or later. See [LICENSE](../../LICENSE).
