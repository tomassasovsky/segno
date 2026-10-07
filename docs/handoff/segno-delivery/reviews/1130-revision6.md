## Scope reviewed

Committed delta `6bf1ef0` → `f722ec4` for PR 1130 (revision 6), three paths only, read-only, no execution:

- `lib/looper/view/tracks_commands.dart` (one hunk, mixer Enter/Space branch)
- `test/looper/view/tracks_view_test.dart` (one hunk, extended mixer modifier/transport case)
- `docs/code-review/foot-mixer-performance/review.md` (one prose hunk)

I read `manifest.json`, the whole `change.diff` (both Dart hunks and the doc hunk in full), the complete `tracks_commands.dart` at head plus its base counterpart, the enclosing focus/test logic (`tracks_view.dart:174-182,414`, `foot_mixer_view.dart:85-290,466-520`, `test/helpers/pump_app.dart`, `tracks_view_test.dart:223-431`), `shortcuts_help_sheet.dart:78`, and the evidence files. Diff matches the `before/` objects exactly — nothing outside those three hunks changed.

## Verdict: the refinement is clean — no required corrections

### Independent trace

**Focus hierarchy.** The only handler owner is `tracks_view.dart:180-182`: a single `Focus(autofocus: true, onKeyEvent: TracksCommands(context).handleKey)` wrapping the Scaffold. `SettingsTray` is a *sibling* at `tracks_view.dart:414`, outside that subtree, so tray focus never reaches `handleKey` at all. No new `FocusNode`, owner, or mutable state is introduced — the fix is a pure read of the node the framework already passes.

**Propagation.** `FocusManager` invokes each chain node's handler as `node.onKeyEvent(node, event)`, walking primary focus upward. So `node` at `tracks_commands.dart:232` is TracksView's own node, and `node.hasPrimaryFocus` distinguishes exactly the two intended cases:

- TracksView node primary (nothing focused to activate) → `handled`: key swallowed, no escape, consistent with the mixer branch's general swallow at `:236`.
- Descendant primary → `ignored`: unchanged from base, so the event continues up to `MaterialApp`'s Shortcuts → `ActivateIntent` → the focused control's `ActivateAction`. Verified against the two activation targets, `foot_mixer_exit` (`foot_mixer_view.dart:100`) and the Settings `OutlinedButton` (`:113`).

**Mixer pedals.** `_MixerPedal`'s own `Focus.onKeyEvent` (`foot_mixer_view.dart:483-492`) consumes Enter/Space on both down and up when enabled, and `canRequestFocus: widget.enabled` keeps disabled pedals out of the chain — so a focused pedal never depends on the ancestor path.

**Tab / modifiers / transport.** `:180` returns `ignored` for Tab before anything else; the Meta/Control block (`:196-222`) returns before the mixer branch, so Cmd/Ctrl+Enter and Ctrl+Space still fall through to OS/menu shortcuts. Plain `P`, `Space`, digits in mixer mode remain swallowed with no dispatch: Enter/Space return at `:232-235` and never reach the `space → togglePlayAll` path at `:256`. Key policy is narrower than base in exactly one direction (swallow instead of escape) and only inside `mode == InteractionMode.mixer` for two keys.

### Does the test prove primary-focus consumption?

Partly, and the gap is covered elsewhere. `tracks_view_test.dart:421-426` clears the recorder and asserts `passedKeys isEmpty` after Enter/P/Space/digit2. The ancestor recorder is a `Focus` placed between the providers and `TracksView` (`:270-272`), i.e. below `MaterialApp`'s Shortcuts, so anything `handleKey` returns `ignored` is recorded. With no descendant requesting focus, the autofocus node is primary, so the assertion is a direct escape regression guard — `before.log` confirms it failed with both Enter and Space listed.

It does not assert the `hasPrimaryFocus` precondition, so this case alone would also pass against an unconditional `handled`. The descendant direction is protected by the two parameterized cases at `:348-389`, which focus Exit and Settings and assert real activation plus `verifyNever(LooperPlayAllPressed)`. Together the pair pins both branches; `after.log` shows the five Foot Mixer cases passing.

### Optional suggestions (not required)

1. `test/looper/view/tracks_view_test.dart:421` — make the precondition explicit so the case can't pass for the wrong reason if focus placement ever changes (e.g. a future autofocus on a mixer pedal, which consumes Enter/Space itself and would leave `passedKeys` empty without exercising this branch):
   ```dart
   expect(Focus.of(tester.element(find.byType(FootMixerView))).hasPrimaryFocus, isTrue);
   ```
2. `docs/code-review/foot-mixer-performance/review.md:70-71` — "Strict analysis, formatting and Bloc lint pass for both changed Dart files" has no corresponding artifact in this packet (evidence holds only the two test logs and the spelling scan), and the retained "The final full suite passes" at `:66` plus the 3,137-test/92.64% figures at `:86-87` were measured at the previous head, before this production change; only the five filtered cases were rerun. One clause ("suite and coverage figures predate this keyboard refinement") would remove the ambiguity. The existing "Current-head CI and the final bounded review remain required" already blocks the wrong reading.

### Preexisting / out of scope (not introduced here)

- `tracks_commands.dart:348` — in record/mute/FX/custom modes the catch-all still swallows Enter on a focused control. Same mechanism, untouched by this delta, already recorded in the prior review's out-of-scope list.
- `tracks_commands.dart:159-173` and `shortcuts_help_sheet.dart:78` — the "Every mode … `Space` play/pause all" doc comment and the Space legend row have no mixer caveat, while mixer mode blocks Space. Inaccurate at base too (there Space escaped and did nothing); this change does not widen it.
- `tracks_commands.dart:175` — `KeyRepeatEvent` and key-up return `ignored` for every key, so a held Enter still escapes. Uniform preexisting behavior, not specific to this branch.

### Limitations

No execution, build, analysis, formatting, lint, network, or other checkout; all source and `before/` content read from the packet's immutable Git-object extracts. `before.log`/`after.log` are taken only as the authors' observed test context: `before.log` is one failing case with Enter and Space escaping, `after.log` is five passing Foot Mixer cases from that one test file — not a full suite, not coverage, not CI, and no macOS beep observation is inferred. `spelling-result.json` records a nonzero full-test-file scan with four exact unchanged baseline comment findings (base lines 938, 1030, 1831, 2716) and zero new findings; it is not entirely green, and I did not extend the fix to those comments. `LoopChoiceButton`'s definition is not in the packet, so whether it is focusable is unverified — immaterial here, since the descendant branch returns `ignored` exactly as at base. Native, repository, and earlier Mixer behavior were out of scope and unchanged. Nothing here implies runtime, hardware, merge, or deployment approval.
