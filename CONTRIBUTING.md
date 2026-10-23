# Contributing to Segno

Thank you for your interest. Segno is a one-person project with a fixed
product direction, so the most useful contributions are bug reports with clear
steps to reproduce, fixes for those bugs, and corrections to the
documentation. Before starting a larger change, open an issue to discuss it.

## Before you start

- Read the [README](README.md) for what Segno is and how the repository is
  laid out.
- Check [open issues](https://github.com/tomassasovsky/segno/issues) and
  [pull requests](https://github.com/tomassasovsky/segno/pulls) so you don't
  duplicate work in progress.
- [docs/PROGRESS.md](docs/PROGRESS.md) records what has been built, settled
  design decisions, and environment notes for building and testing.

## Branches

All work lands on the development branch, `claude/segno-integration`. The
default branch, `master`, receives it at release. Branch from
`claude/segno-integration` and open your pull request against it.

## Making a change

The code follows a layered architecture: presentation, then blocs, then
repositories, then data clients. Presentation never imports a data client
directly. The audio engine's `AudioEngine` interface is the seam for tests, so
application code is tested against a fake engine.

Every change comes with tests:

- Blocs, cubits, repositories and widgets get Dart tests next to the code they
  cover. CI enforces 90% line coverage for the application.
- Engine changes get native tests in `packages/segno_engine/src/test`.
- Changes to the console link, under `firmware/` or
  `packages/pedal_repository`, must keep the link contract test passing.

After changing the engine's public header
(`packages/segno_engine/src/segno_engine_api.h`), regenerate the Dart
bindings with `dart run ffigen --config ffigen.yaml` from
`packages/segno_engine`, then run `dart format` on the generated file.

## Checks

Run these before opening a pull request. CI runs the same checks.

```sh
dart format .
dart analyze
bloc lint lib test packages
flutter test
bash packages/segno_engine/src/test/run_native_tests.sh
bash firmware/test/run_tests.sh
```

`bloc lint` comes from bloc_tools: install it once with
`dart pub global activate bloc_tools`. Run `flutter pub get` first in a fresh
checkout. Without it, `dart format` cannot find the lint settings and
reformats the whole repository.

CI also spell-checks every Markdown file with cspell. Project-specific words
go in the `words` list in `.github/cspell.json`.

## Pull requests

- Use a [Conventional Commits](https://www.conventionalcommits.org/) title,
  such as `fix(engine): ...` or `docs: ...`. CI rejects other titles.
- Reference the issue: `Closes #123` when the pull request completes it.
- Keep each pull request to one change. Large features land as a series of
  smaller pull requests.
- Do not preserve old behavior behind flags or compatibility layers. Remove
  the code a change makes obsolete.

## Reporting bugs

Use the [bug report form](https://github.com/tomassasovsky/segno/issues/new/choose).
For security problems, follow [SECURITY.md](SECURITY.md) instead.

## License

By contributing, you agree that your contribution is licensed under the
[GNU General Public License v3.0 or later](LICENSE), the license of the
project.

Everyone taking part is expected to follow the
[code of conduct](CODE_OF_CONDUCT.md).
