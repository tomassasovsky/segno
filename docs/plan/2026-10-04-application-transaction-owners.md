# Application transaction ownership

Issue #1109, following architecture audit #1026. Implementation and corrective
review are authorized; merging remains human gated.

## Problem and outcome

FX edits currently mix widget transactions with several save queues. Session
loading and shutdown can therefore finish before the same edits are durable.
Settings Cubits also own application transactions while the composition root
wires peers together. The correction gives each transaction one application
owner, with thin presentation adapters and one shared application lifetime.

This publication carries FX saving, the four existing settings transaction
cores, Session capture/load/recovery, and application shutdown together. Splitting
the shared save queue from Session would remove the old post-load persistence
before its replacement exists. The supporting control-availability projection
reads the new owners' confirmed state without retaining a second state copy.

## Boundaries

- FX Cubit handles edit intentions using stable effect identities. Widgets keep
  navigation and local drafts; LooperRepository remains authoritative for audio.
- FxChainPersistence owns admitted save obligations, debounce, replay, failure
  retention and the loaded session's complete FX/monitor boot image.
- Tempo, Playback, Record and Timing application owners contain the existing
  transactions. Their Cubits expose view state without peer-Cubit dependencies.
- SessionSettingsCoordinator captures one coherent durable settings image.
  Session completion includes boot persistence and binding installation.
- AppRuntime constructs one set of actors, retires new control input before
  shutdown and drains admitted work before disposing its owners.
- Repository receipt observation follows the engine/session lifetime. Session
  import does not expose staged audio as a completed recording and verifies
  cleanup after failure.

The separate Count-in changes, aliases, brightness, secondary-display extraction,
platform changes and unrelated visual geometry are excluded. Existing published
MIDI recovery, native fence, passive FX readiness and lookup corrections stay
intact. No compatibility wrappers or temporary persistence fallback are added.

## Acceptance and verification

Verify accepted FX edits remain owed after navigation changes, failed storage
is retryable, and monitor state plus Released controller values are preserved.
Session load must wait for required persistence, clear omitted boot keys, retain
an exact retry image, and never publish partially imported audio. Shutdown must
use the same actors as the UI, refuse to halt after failed cleanup, and drain
successfully on Retry. Ordinary recording and saved-session behavior must remain
unchanged.

Use the existing independent repair evidence to explain intent, then validate
the assembled extraction. Run focused failure-path regressions, applicable
repository and app coverage gates, strict analysis, explicit-path formatting and
a verified Bloc scan. Review the complete resulting diff and its dependencies,
including independent adversarial review. Do not treat an earlier integration
run as proof for this newly composed source. Record author-only visual failures
separately; no blind golden refresh. Current-head CI and a complete clean review
are both required for ready-to-merge.
