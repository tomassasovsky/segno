# Routing surfaces review

Base: `0e1847046530f99ab72921ab8a6e48867ed5dfad`; original routing head:
`6f7a345173f46e324a54f864e2c8a93861b40c92`. The reviewed source/test/golden
fingerprint is
`38628183d10e773ce182e08ba24795800f1b48bb9a460bbb533ee7cdda5dba5b`.
Publication must preserve these contents and bind the review to its exact head.

## Verdict

No unresolved actionable product finding remains. Native and UI specialists
reviewed each other's changes; a separate adversary traced the full product
diff and replayed counterexamples. Conventions, test quality, architecture,
simplicity and readiness are separate review lenses across those reviewers,
not five claimed independent reviewers. Authors did not certify their own
implementation. Remote CI and the existing human merge gate remain separate.

## Closed findings

| ID | Finding | Closure evidence |
| --- | --- | --- |
| R3C-N1 | Queued source growth followed by recording loses a captured lane on Undo | Independent recorded-sample replay; capture preparation waits for structural publication |
| R3C-U1 | Encoder draft can commit to a different channel | Equal-valued target-change probe refuses the old draft |
| R3C-U2 | Escape retains the cancelled slider preview | Real-widget cancellation restores confirmed state |
| R3C-U3 | Missing meaningful slider reset | Double tap resets once without an intermediate write |
| R3C-U4 | Rename keyboard dismisses on outside tap or drag | Real sheet retains draft and failed Save; explicit Cancel works |
| R3C-U5 | Missing mate of odd output appears reachable | Physical-channel intersection and removable absent intent verified |
| R3C-U6 | New routing choices omit encoder focus | Existing focus wrapper and keyboard activation verified |
| R3C-D1 | Direct changes can break an existing stereo pair | One-sided and compound edits refuse without publication; pair removal succeeds |
| R3C-D2 | Contradictory saved counts reach destructive replacement | Preflight refuses before engine commands and preserves prior audio/revisions |
| R3C-A1 | Same-name reopen retains alias edit lifetime | Real repository and supervisor lifetime replay rejects stale edits |
| R3C-A2 | Alias reload races a failed write and rollback | Independent delayed-read probe fails before repair and passes afterward |
| R3C-D3 | Coalesced source growth misses new lanes in fader edit | Suspended-write probe confirms live and durable levels for both admitted lanes |
| R3C-Q1 | Eight alias Cubit API warnings | Strict analysis and actual 636-file Bloc scan are clean |

## Completed angles and gates

Review covered changed hunks, removed routing paths and guards, UI/domain/
storage/native callers, shared mix ownership, callback allocation and
publication, FFI parity, established helper reuse, simplicity and test oracles.
The native repair preserves completion and cancellation of existing gestures.
The final fixture-only patch has separate peer review with no weakened tests.

The linked [validation report](../../reviews/design-routing-surfaces-restack/README.md)
records complete local suites, coverage, native configurations, author-machine
visual checks and actual desktop interactions. Source remained unchanged while
checks ran; reused results have matching inputs. Pen's implementation note is
saved in the owner design source without copying unrelated design changes.

Hardware audio and physical controls remain explicit verification limits.
Missing later backing/FX implementation is not represented as working routing.
