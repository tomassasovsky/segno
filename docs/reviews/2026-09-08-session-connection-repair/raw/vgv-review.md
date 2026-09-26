# VGV Code Review

September 8, 2026. Independent review of the local session connection-repair
proposal against `/tmp/segno-connection-repair-before`, following the specified
workflow role and build reporting contract. The parent authored Library, host
and CSS integration; another agent authored the pure model and test suite.
The reviewer authored none of this delta. The unchanged prior session-ownership
implementation is an integration dependency, not independently re-reviewed here.

Scope is the approved design plan `docs/plan/2026-09-08-session-connection-repair-plan.md`.
This is JavaScript/HTML/CSS under `docs/design` inside a Flutter repository.
Established study callbacks and pure models are the applicable pattern; no
production Bloc/native refactor is inferred. No commits, PR head, merge, CI,
Pen or physical-controller validation is certified.

## Summary

The bounded repair proposal is ready for local design review. No unresolved
regression, convention or simplicity finding remains on the recorded hashes.
The implementation keeps compatibility/collision rules in a pure module,
interaction state in Library, and persistent publication in the host.

## Critical findings

None unresolved. The initially reproduced foot-release identity race was fixed
and is covered by the final browser regression. See the separate architecture
report for its reproduction and resolved lifecycle invariant.

## Important findings

None.

## Suggestions

None requiring follow-up in this scope.

## Regression and convention checks

- Source/current state remain independent of option browsing and pending repair.
  Invalid choices return explicit results without partial publication.
- Required callback signatures and the new script dependency are wired in the
  main host. Existing ownership, media and Library test fixtures still pass.
- Target/control IDs are retained exactly; unavailable or colliding sources are
  rejected instead of guessed from labels. Output text is escaped in Library.
- The final Library adapter reuses validated affected-assignment labels from
  the model result, avoiding a second candidate lookup.
- No production dependencies, lint suppressions, old-format compatibility paths,
  test skips or source-debug leftovers were introduced.
- Node syntax and baseline delta whitespace checks pass. No JavaScript formatter
  or linter manifest is configured for these design studies; the repository's
  Dart formatter and Bloc rules are not claimed as checks of JavaScript.

## Simplicity assessment

Complexity verdict: appropriate for the authorized flow. The pure model is
small and specific; it does not add a general device graph, migrations or a
second session browser. Original/base/repaired fields have distinct roles for
freshness, resetting connection choices and preserving preceding media repair.
The foot request token/revision addresses verified stale-contact behavior.

No deletion estimate or speculative abstraction recommendation is warranted.

## Testing assessment

The new model's 19 tests cover success, immutability, invalid/incompatible/current
hardware, occupied ports, rack references, MIDI identities and collisions. The
72-test combined regression remains green. The normal-host Chrome/Firefox suite
verifies actual Library selection, pending/cancel/reset behavior, a real failed
storage writer, final Apply, reload, media sequencing, full encoder navigation,
foot action ownership, stale contacts and BANK pagination.

These checks exercise a silent local prototype and simulated inventories.
They provide no native audio, real device, appliance filesystem or CI evidence.

## Reviewed SHA-256

Paths are under `docs/design`. Main HTML review is bounded to the new repair
script/adapter, review fixtures and foot-contact integration over the baseline.

| File | SHA-256 |
| --- | --- |
| `session-connection-repair.js` | `43080e7bc69916a0575322e36e1e73cf8cbf954cb7a84a4a70065c50d331ac7a` |
| `session-library-study.js` | `4af02ea38e908b1f44575d8452b8ebe820ad1ad4bdd628f1f23e9456518873e9` |
| `session-library-study.css` | `425905c502838a59d29eae8b24bedebcd21c7a18d547ea4ce2a18b8644438446` |
| `fx-ux-prototype.html` | `c745de666af7687569f823d95bf92949f7a8b02b9792f5625651a946297af3b8` |
| `verify_session_connection_repair.cjs` | `9a61c070580668046bb965ca08b6b41ffb211ae8f6ea604ad3ab28a2d83ad9d4` |
| `verify_session_connection_repair_browser.cjs` | `1bb5c330ac09bfc3b9b7c8319192157b05b19c9eb5bf3b949e03707b12b3a8dd` |
