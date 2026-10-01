# FX surfaces integration code review

Base: `a52fe34d42a719624762f7756518a7e54cf7fd0c`.
Original surface parent: `95dcea0d81f000c87a51c7a67cc931cc2da4df67`.
Reviewed candidate: 424 implementation, configuration, asset and test paths,
including deletions and new files. Source fingerprint:
`2cb63739fd8328fc25d000f2b2b5e4328ff3ec1b5ecc0175e350c60177f6b3f5`.
The integration preserves both parents. Committed-blob verification binds
this review to the published head; later source changes reopen that binding.

## Result

Independent review is complete with no unresolved actionable finding in the
intended diff. Two reviewers split app/UI and native/domain ownership; the
native author does not certify their own packages. Five quality roles share
those reviewers. Root consolidates the whole-candidate result and owns Git,
aggregate checks and current-head CI.

The complete diff was reviewed for changed lines, removed guards and tests,
cross-file call chains, reuse, simplicity, efficiency, fix depth and project
conventions. Review traced destination-keyed recipes through C/FFI, repository,
Bloc/Cubit, persistence and navigation. Callback storage remains bounded;
the change introduces no callback allocation, blocking I/O or locks.

Closed findings cover rack boundary retention, singleton preset identity,
invalid-row isolation, load/write ordering, stale modal writes, exact native
acknowledgment, chain bypass, route lifetime, editor opening and actual-capacity
append refusal. Original failing independent cases remain recorded; expected
samples and failure behavior were not rewritten to agree with production.
Local screenshots were inspected independently rather than accepted only
because regenerated files passed their own comparison.

The final lifetime predicate uses a narrowly documented method-level lint
exception. Initial edits retain the displayed generation; only subsequent
validity checks read the actual generation, and a closed Bloc refuses.
Two explicit Cubit exceptions document operation-specific asynchronous
acknowledgments. An installed linter parser blind spot was reproduced and
does not substitute for architectural review of these methods.

Normal, address-sanitized, telemetry-disabled, race, C++ header and 186-symbol
native checks pass. Seven package suites and their coverage floors pass with
bound inputs. The full app suite passed 2,229 tests, six existing skips and
91.07% coverage. The narrow final predicate/comment/test amendment has 190
affected tests passing; receipt mechanisms are unchanged. Strict analysis,
formatting, actual 649-file Bloc lint and whitespace checks pass on the final
source with no drift. Aggregate reuse and the one model formatting amendment
are explicit in the [verification record](../../reviews/design-fx-surfaces-restack/README.md).

The running Mac app confirms direct editor opening for new singles and racks,
correct Back destination and Stage closing the tray. These are development
journey checks, not physical-appliance or listening evidence.

## Limits

Exact factory parameter and DSP completion remains mandatory M6 work; the
catalogue alone does not prove it. Already-started platform storage writes
across session replacement remain M7 work. A prior development-window overflow
without a captured viewport is retained for the final responsive-layout audit;
it did not recur in the final FX journey. Hardware controls, physical displays,
audio-device operation and remote CI retain their separate validation gates.
No merge, deployment or full-campaign completion is implied by this review.
