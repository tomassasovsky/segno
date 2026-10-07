# M3.13 independent review — bug-focused review

Reviewed product base: `f186bb952d1d000522c5e8e55226bc2ee0931538`, plus the frozen M3.13 working changes. [Executed source manifest](adversary-executed-source-v1.json), SHA-256 `a90df12d01eded02aa009b9512262e1df1d9dcf2a301c5eb69541cb2b7d674eb`, binds 87 changed product/test/artifact paths, including 29 product source paths. The broader executable binding covers 1,487 inputs. Source, private oracle/harness and frozen native library were unchanged before/after the final normal run and negative control.

Product review is complete for that binding. The coordinator subsequently reopened **test fixtures only** after aggregate failures in old short-track/readiness fixtures. Those later test changes are outside this report's binding and require a delta review. No final PR-head approval or green aggregate is implied. The unrelated controller-package analysis exclusion remains outside approved feature scope.

Read scope includes every changed product source and relevant tracked/untracked tests: bootstrap/App/shutdown, typed target/resolver/catalogue/UI, Control MIDI/External lifetime/priority, Playback owner/port, repository receipt/restart/session paths, exact Settings checkpoints, ordinary Bloc writes, Session gate and file mapping. Runtime author output was read only after independent expectations and tests were bound/executed. See [independent execution](adversary-independent-execution-v1.md) for results, attempt history and limitations.

## Disposition

**No unresolved actionable product finding for the executed source.** Both independently identified startup findings are repaired and source re-reviewed. This is scoped product evidence; post-run fixture deltas and exact-head CI remain pending.

### M313-A1 — failed startup validation bypass (P1), repaired

Original owner SHA `a1c58e31aa7f2a48bccec8051810d0956036c44145365cb136997ea3ffd9c462`. Trigger: malformed `track_one_shot.7` refuses startup validation; independent replay enters native recovery; Retry previously repaired native state then set initialized/ready without validating the scalar. Final `recoverOneShot` repairs native state inside the serial queue and, if initialization has not succeeded, performs staged `_restoreOnce` outside the queue before reporting accepted readiness. It cannot manufacture validation from native recovery. Final owner SHA `8c3c4c8b355eac94cf6a2225708015946be6c1ba57053126f265674873fdd2e5`.

Author regression evidence, reviewed rather than claimed as independent execution: `recovery-init-red.log` (SHA `ae1407decd42fb9347ebd3ae495aad6148dd39338f5a69919df167c331e330b8`) fails with expected false/actual true; final 15-case owner run includes the corrected case. Independent 50-case coverage separately exercises malformed last-slot refusal, delayed readiness, autonomous timeout/mismatch and explicit recovery, but does not add this exact combined regression to its count.

### M313-A2 — superseded first initialization stalls readiness (P2), repaired

Original `_restoreOnce` silently returned after the device generation changed during initial reads, leaving the completed load Future and false initialization flag indefinitely. Final `_restoreOnce` stages all nine validated settings first, captures an admission lifetime on each attempt, and retries after a changed device generation. A changed session revision takes the current repository session vector instead of replaying old startup preferences. Receipt awaits are fenced before publication. Closing terminates the retry loop. Final source uses one Playback queue without waiting recursively on that queue.

Author regression `init-reconnect-red.log` (SHA `79a8ddf60db5582c8cf3a1651a578308370a48da051f562acebfe6bd7b01a1d8`) fails expected non-null/actual null. The reviewed final `owner-lifetime-v7.log` is 15/15 (SHA `38bdef02be98403a3d628df5ef6b652af15991fb7e1c971bc5bb8bd1f6c7d0b6`) and includes actual repository applySession while initial reads are blocked. This is not a claim that full live-Control Session Load is fixed.

## Other checked risks

Running receipts require command drainage and fresh native bits; immutable vectors/masks and pending identity protect later changes/cancellation. Live versus durable Released retains explicit false versus absent membership. Ordinary reset invalidates old cleanup only after acceptance. Session lock order is Mixer → Click → one Playback queue. App first cuts Control ingress and drains cleanup; explicit Retry repairs then drains owed cleanup again before final Playback flushes/halt. Dispose drains Control before Playback. The already-known misplaced Once flush in Click toast Retry was removed and not counted twice.
