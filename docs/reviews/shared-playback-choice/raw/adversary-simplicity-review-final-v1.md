# M3.13 independent review — code simplicity

Reviewed product base: `f186bb952d1d000522c5e8e55226bc2ee0931538`, plus the frozen M3.13 working changes. [Executed source manifest](adversary-executed-source-v1.json), SHA-256 `a90df12d01eded02aa009b9512262e1df1d9dcf2a301c5eb69541cb2b7d674eb`, binds 87 changed product/test/artifact paths, including 29 product source paths. The broader executable binding covers 1,487 inputs. Source, private oracle/harness and frozen native library were unchanged before/after the final normal run and negative control.

Product review is complete for that binding. The coordinator subsequently reopened **test fixtures only** after aggregate failures in old short-track/readiness fixtures. Those later test changes are outside this report's binding and require a delta review. No final PR-head approval or green aggregate is implied. The unrelated controller-package analysis exclusion remains outside approved feature scope.

Read scope includes every changed product source and relevant tracked/untracked tests: bootstrap/App/shutdown, typed target/resolver/catalogue/UI, Control MIDI/External lifetime/priority, Playback owner/port, repository receipt/restart/session paths, exact Settings checkpoints, ordinary Bloc writes, Session gate and file mapping. Runtime author output was read only after independent expectations and tests were bound/executed. See [independent execution](adversary-independent-execution-v1.md) for results, attempt history and limitations.

## Simplicity perspective: completed for executed product

No actionable YAGNI or unnecessary compatibility path was found. The narrow bool target/port and endpoint widget are used by current default/track ownership and the three existing mapping editors. Live/restart vectors, exact nullable checkpoints, address revisions and pending receipt identity each serve an accepted requirement. The empty inheritor mask correctly avoids a fake native command.

One shared Playback queue and one Session gate avoid nested-lock complexity. Decay retains its existing atomic setter; Once gains the actual callback proof it needs, without generalizing both into a new transaction framework. The two startup repairs add bounded ownership logic in the existing owner. They do not add a second owner or global registry.

No safely removable LOC estimate or speculative target family was identified. Retain this scope rather than introduce a broad rewrite while publishing the verified slice.
