# instrument_repository

Repository for Segno's instruments. It holds the instrument definitions
(`InstrumentsWorkingCopy`: each `Instrument` has a stable id, a fixed engine
slot, a sound, three parameters, MIDI input and computer key settings) and
keeps the engine's synth slots, voice limit and MIDI routing table matching
them. It also handles sound auditions, unsaved parameter drafts, notes played
from Dart (`NoteDispatcher`), and sending everything again after an engine
reset. It depends on `segno_engine`. The app creates it in
`lib/app/run_segno.dart` over the looper's engine snapshots, and the
instruments feature reads it.

## Usage

```dart
import 'package:instrument_repository/instrument_repository.dart';
import 'package:segno_engine/segno_engine.dart' show AudioEngine, EngineSnapshot;

void addPiano(AudioEngine engine, Stream<EngineSnapshot> snapshots) {
  final instruments = InstrumentRepository(engine: engine, snapshots: snapshots);
  final sound = instruments.catalogue.patches.first;

  final added = instruments.workingCopy.add(
    id: 'piano-1',
    name: 'Piano',
    soundId: sound.id,
    params: sound.defaults,
  );
  final copy = added.copy;
  if (copy == null) return; // added.refusal says why
  instruments.apply(copy);

  final token = instruments.notes.press('piano-1', [60, 64, 67]);
  if (token != null) instruments.notes.release(token);
}
```

## Notes

- Persistence belongs to the caller: the app's instruments settings write the
  copy (`toJson` / `InstrumentsWorkingCopy.fromJson`) and then call `apply`.
- Nothing the engine refuses is dropped. A slot, voice limit or routing table
  the engine cannot take yet is sent again on the next snapshot, and the
  latest value wins. A note release the engine cannot take yet is retried
  the same way.
- When the engine's synth epoch changes (a reset), auditions, drafts, held
  notes and latches end, the voice limit returns to its default, and every
  slot and the table are sent again.
- While an instrument is sounding, a new late audio period lowers the voice
  limit to three quarters (never below 8) and emits the new limit on
  `polyphonyReductions`. `restoreVoiceLimit` puts it back.
- `compileRoutes` reports what the engine's table cannot hold as
  `RouteProblem`s instead of dropping it silently.

## Testing

```sh
flutter test
```

`test/instrument_native_test.dart` runs against the real engine library and
skips itself unless `SEGNO_ENGINE_LIB` is set:

```sh
export SEGNO_ENGINE_LIB="$(bash ../segno_engine/tool/build_test_lib.sh)"
flutter test
```

## License

Part of [Segno](../../README.md), licensed under the GNU General Public License
v3.0 or later. See [LICENSE](../../LICENSE).
