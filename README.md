# Segno

A loopstation for recording and layering live music, with a Flutter interface, a native audio engine, and built-in foot controls.

Record a phrase, let it repeat, and add another part over it. Segno brings the recording controls, track state, and audio engine into one application. Its current product direction is a dedicated Linux appliance.

## See the interface

![Segno’s Tracks interface showing four named tracks](https://raw.githubusercontent.com/tomassasovsky/segno/80c30d6ac3d09e49635decf3bf20a480f1419824/test/screenshots/goldens/tracks_main_window.png)

*Flutter UI-test capture with simulated track state. Live audio demo pending.*

## Implemented capabilities

- **Record and layer audio.** The native engine implements loop recording, playback, overdubbing, undo, and redo.
- **Operate the looper by foot.** The console board connects ten footswitches, an encoder, and LED feedback to the app. External MIDI controllers use the controller mapping layer.
- **Save a session.** The session layer writes recorded audio and a manifest so the application can restore a loop’s state.
- **Keep the interface and audio engine separate.** Flutter handles the interface; a Dart engine interface connects the application to the native implementation through FFI.

## Explore the engineering

Created by [Tomás Sasovsky](https://github.com/tomassasovsky). The project includes the application, native audio engine, controller integration, pedal firmware, and hardware designs.

- [Audio engine and Dart interface](https://github.com/tomassasovsky/segno/tree/master/packages/segno_engine)
- [Console board and firmware](firmware/console_board/README.md)
- [Controller mapping](https://github.com/tomassasovsky/segno/tree/master/packages/controller_repository)
- [Session storage](https://github.com/tomassasovsky/segno/tree/master/packages/session_repository)

## Development and project status

Start with the [build and test notes](https://github.com/tomassasovsky/segno/blob/master/docs/PROGRESS.md#how-to-build--test-environment-gotchas--read-first) for the development environment, native engine checks, and Flutter test commands.
