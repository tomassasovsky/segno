# M3.13 independent review — VGV conventions

Reviewed product base: `f186bb952d1d000522c5e8e55226bc2ee0931538`, plus the frozen M3.13 working changes. [Executed source manifest](adversary-executed-source-v1.json), SHA-256 `a90df12d01eded02aa009b9512262e1df1d9dcf2a301c5eb69541cb2b7d674eb`, binds 87 changed product/test/artifact paths, including 29 product source paths. The broader executable binding covers 1,487 inputs. Source, private oracle/harness and frozen native library were unchanged before/after the final normal run and negative control.

Product review is complete for that binding. The coordinator subsequently reopened **test fixtures only** after aggregate failures in old short-track/readiness fixtures. Those later test changes are outside this report's binding and require a delta review. No final PR-head approval or green aggregate is implied. The unrelated controller-package analysis exclusion remains outside approved feature scope.

Read scope includes every changed product source and relevant tracked/untracked tests: bootstrap/App/shutdown, typed target/resolver/catalogue/UI, Control MIDI/External lifetime/priority, Playback owner/port, repository receipt/restart/session paths, exact Settings checkpoints, ordinary Bloc writes, Session gate and file mapping. Runtime author output was read only after independent expectations and tests were bound/executed. See [independent execution](adversary-independent-execution-v1.md) for results, attempt history and limitations.

## VGV perspective: completed for executed product

No additional VGV convention blocker remains. The required pure port keeps one application-owned Playback owner and avoids ownerless fallback. UI renders accepted state and edits drafts; Settings scalar verification and native receipt logic remain outside widgets. New snapshots copy maps; nullable false/membership semantics are explicit. New subscriptions/streams and receipt timers have disposal paths. Obsolete direct ordinary write routes and the old Decay-only Session gate were replaced rather than aliased.

The two startup correctness findings were resolved and re-reviewed as detailed in the bug report. The independent run passes 50 behavioral cases. The coordinator reports formatter/analyzer/Bloc/whitespace checks passing; this reviewer did not rerun those tools. Later test-only changes still need a delta review, and full CI belongs to the final PR gate.
