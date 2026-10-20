# M3.13 independent review — architecture

Reviewed product base: `f186bb952d1d000522c5e8e55226bc2ee0931538`, plus the frozen M3.13 working changes. [Executed source manifest](adversary-executed-source-v1.json), SHA-256 `a90df12d01eded02aa009b9512262e1df1d9dcf2a301c5eb69541cb2b7d674eb`, binds 87 changed product/test/artifact paths, including 29 product source paths. The broader executable binding covers 1,487 inputs. Source, private oracle/harness and frozen native library were unchanged before/after the final normal run and negative control.

Product review is complete for that binding. The coordinator subsequently reopened **test fixtures only** after aggregate failures in old short-track/readiness fixtures. Those later test changes are outside this report's binding and require a delta review. No final PR-head approval or green aggregate is implied. The unrelated controller-package analysis exclusion remains outside approved feature scope.

Read scope includes every changed product source and relevant tracked/untracked tests: bootstrap/App/shutdown, typed target/resolver/catalogue/UI, Control MIDI/External lifetime/priority, Playback owner/port, repository receipt/restart/session paths, exact Settings checkpoints, ordinary Bloc writes, Session gate and file mapping. Runtime author output was read only after independent expectations and tests were bound/executed. See [independent execution](adversary-independent-execution-v1.md) for results, attempt history and limitations.

## Architecture perspective: completed for executed product

No new layer or dependency-direction violation was found. App composition injects the same PlaybackOptionsCubit into ordinary settings, Control and Session. OneShotControl is a narrow application port; package repositories retain primitive bool/default/override data and do not depend on app types. The existing shared Control ledger remains the arbitration authority; the owner adds receipt/persistence verification rather than another source-priority mechanism.

Initialization stages independent field reads before queue acquisition. Session waits both initializations, then takes one Playback lock after Mixer and Click, reading durable snapshots directly. There is no nested field queue or Control cleanup awaited from the Playback lock. Exact checkpoint ownership, native pending identity and separate live/restart vectors satisfy current requirements. The two initialization repairs remain localized to this owner. No native API, FFI symbol or callback implementation changed; no new real-time allocation/lock path was introduced.

No additional abstraction or persistence envelope is required. Test fixture revisions after execution do not alter this product assessment but must be checked before final merge readiness.
