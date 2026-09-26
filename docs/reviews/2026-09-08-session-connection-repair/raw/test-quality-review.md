# Test Quality Review

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

## Coverage summary

- New pure model: 19/19 tests pass, with no skips.
- Combined connection/ownership/media/recovery command: 72/72 pass.
- Normal-host connection browser journey: Chrome and Firefox pass.
- Every new behavioral unit has tests. The Library and host delta is exercised
  through the real main page in addition to inherited lifecycle regressions.
- `node --experimental-test-coverage --test
  docs/design/verify_session_connection_repair.cjs` reports **98.59% lines,
  83.82% branches and 100% functions** for `session-connection-repair.js`.
  The unexecuted lines are human-readable label fallback paths. No repository
  threshold is configured for these JavaScript studies. This is model coverage,
  not HTML/browser, production or appliance coverage.

## Model test quality

The suite imports the actual repair model and ownership projection. Frozen
inputs and independent output mutation verify ownership rather than mere
absence of exceptions. Known vectors assert moved mappings/rack references,
original hardware requirements, physical calibration retention and unchanged
unrelated musical state.

Failure cases include wrong/disconnected/uncalibrated CTRL destinations, current
hardware changes, incoming occupation (including dormant assignments), removed
sources and destinations, MIDI same-name identities, Omni collision in both
directions, disabled mappings and malformed message sources. Missing parameter
targets are deliberately still blocked by final ownership projection.

The suite does not mock the implementation or duplicate its branch logic. The
expected MIDI mapping copy changes only device ID, which directly expresses the
contract and protects the remaining fields from unintended edits.

## Browser test quality

`verify_session_connection_repair_browser.cjs` seeds contrasting saved/current
states into normal browser storage, opens the real main host and performs its
public UI/encoder/pedal actions. Functional checks assert that no `review` query
is active. Simulated connection calls affect inventories; they do not replace
the Library or storage implementation.

The suite verifies pending selections and Back/Reset/Cancel against complete
live and stored before-state, then uses a throwing `Storage.prototype.setItem`
to verify failed publication retains the repair. The writer is restored in a
`finally` block. Successful retry and reload preserve exact mappings and current
physical/global settings. Separate tests cover media repair before connection
repair and MIDI collision refusal.

The full encoder journey chooses Replace, selects its replacement and applies.
Foot checks cover STOP Back/Apply, CLEAR Reset, MODE Cancel, BANK pagination and
wrap. Held-contact regressions now include USB disconnection, Cancel/reopen,
Back, Back/reenter and Reset with Apply held; these protect the independently
reproduced stale-identity bug. Screenshots and bounds checks are author-style
prototype evidence, distinct from native/CI validation.

## Anti-patterns and limitations

No actionable tautologies, assertion-free cases, tests of mocks, ignored async
results, test skips or implementation-mirroring issues were found. Fixtures are
explicit and the browser checks reject page errors. Actual controller discovery,
audio rendering and durable appliance storage remain outside the fixtures.
Existing archived-source mutation/removal tests are included in the combined
regression; this review does not claim broader native restore coverage.

## Verdict

All scoped tests meet the quality bar on the recorded revision. No unresolved
actionable test-quality findings remain.

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
