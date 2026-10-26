# session_repository

Repository that saves and opens Segno sessions. A session is a `.segno` bundle
directory: a `session.json` manifest, one 32-bit float WAV per layer, and a
`mixdown.wav`. The package also keeps the session catalog (ids, display names,
one level of folders, backups), exports a bundle's mixdown and stems, and
plays Library previews through the engine's audition voice. It reads audio
from the engine (`AudioEngine` from `segno_engine`) and writes WAV with
`wav_codec`. The app's session and Library cubits use it.

## Usage

```dart
import 'package:session_repository/session_repository.dart';

final sessions = SessionRepository(
  engine: engine,
  guards: guardRegistry,
  sessionsRoot: () async => '$documents/sessions',
);

final id = await sessions.newSessionId();
final path = await sessions.bundlePathOf(id);
await sessions.save(path, settings: sessionSettings, name: 'Rehearsal');

final summaries = await sessions.listSessions();

final opened = await sessions.open(path, liveSettings: currentSettings);
// Hand opened.bundle to the looper repository to apply it, then:
if (opened.conversion case final conversion?) {
  await sessions.commitConversion(path, conversion);
}
```

## Notes

- This package does file I/O and reads the engine; it never applies a session
  to the engine. Applying a loaded bundle is the looper repository's job.
- The manifest format is at version 16 (`Session.formatVersion`). `open`
  converts an older manifest in memory, one step per version.
  `commitConversion` writes the result and keeps the original manifest beside
  it as `session.v<N>.json`.
- A save writes a new copy of the bundle and swaps it in, so an interrupted
  save leaves the previous one in place. It holds a `sessionWrite` guard on
  the bundle (`operation_guards`) while it writes.
- `open` refuses a bundle whose audio was recorded at a different sample rate
  than the running device (`SessionSampleRateMismatch`). There is no
  resampling.

## Testing

```sh
flutter test
```

`test/fixtures/` holds saved bundles and the generators that wrote them for
older manifest versions; the migration tests open them.

## License

Part of [Segno](../../README.md), licensed under the GNU General Public License
v3.0 or later. See [LICENSE](../../LICENSE).
