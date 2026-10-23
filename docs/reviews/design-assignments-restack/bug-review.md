# M3.1 complete bounded source bug review

Scope: the twelve changed M3.1 code, test and configuration paths in `final-hashes.json`, compared with base `0d601db8ec3450afb8ca94071ce96c969ffde1d9`. This includes the independent root Settings default and fuzzer timing amendments. The same reviewer performed these five role passes sequentially and authored none of this delta. Earlier M2.6 package/native work is excluded from the review's authorship claim; unchanged repository and wire code was read only to trace the current contracts. Later assignment UI/action-catalogue work and the pre-existing app overflow are outside this slice.

Binding: the final source snapshot and `final-hashes.json` bind this report. ControlCubit is `3de5752f05393cdcebe5d27e6bea600756ef128a2b6e120d2c78c545c63a5eaa`; its test is `e5f7ecad7f6fd140e66b0ca6692c2354519a7f57bf783922daca7fc0d3f99a1d`. The entire changed diff and relevant enclosing functions/callers were inspected. This is a source review, not an assertion that the eventual remote PR head has green CI.

The bounded source review is complete with no unresolved actionable source finding. Final independent bank-neighbor revalidation passes unchanged, and root's final full-app/static/coverage packets are green. Those executions belong to their named owners; exact-head remote CI remains a separate gate.

Completed angles: line-by-line changed hunks and enclosing functions; removed behavior and caller replacement; parser/equality/copy round trips; scope resolution and stable identity; timer/contact lifetime; repository admission and exact acknowledgment; frame projection through the physical board indexing contract; reuse, complexity and resource ownership; review of every changed test and configuration path. The original incoming delta was checked against the accepted controls oracle, not used as its own expected behavior.

Closed candidates and mechanisms:

- Invalid direct/persisted Hold combinations and orphan metadata now reject consistently; clearHold restores canonical defaults. Unknown explicit scope/behavior values no longer silently retarget or throw from unchecked casts during decode.
- M3-01: unchanged-recipe acknowledgment wakes the captured restore through one readiness barrier. The original failing real-engine case passes unchanged. The later real second-recipe sequence also passes; no reproducible second-refusal race was found, and speculative scheduling is not filed as a defect.
- M3-02: a fired Hold projects its successful resolved target, including a toggle after release. Display memory is checked against the actual bank binding. All bound LED writes use the active bank channel offset consumed by the board, closing the subsequent Bank B wire-index trigger.
- M3-03: removal of the captured stable slot retires its restore obligation, allowing a valid replacement assignment to receive input without ever substituting that replacement for the old target.
- M3-04: inherited system Hold callbacks use the same firing-time take-lock predicate as bound gestures. Releasing a completed momentary still attempts its restore.
- M3-05: pending gestures capture session revision before asynchronous session application; they cannot dispatch while the replacement awaits. Applying equal-valued binding configuration still cancels old gestures.

Removed behavior was deliberately replaced: ignored native write results became admission checks; unconditional restore-record clearing became retained/refused or retired/absent handling; Press-only LED lookup became successful-function projection; individual system timer arming became the shared validity helper. Normal immediate Record/Play, Stop and Tracks behavior, stable slot lookup, source-specific CTRL/MIDI ownership and the inert direct CTRL branch remain intact.

The retained test failure history, independently authored probes and source snapshots are distinct from author checks. This reviewer ran no tests/builds and changed no product source. Physical electrical behavior, UART noise/recovery, actual foot timing and hardware LEDs remain device validation; no host-only evidence substitutes for them.
