<!-- cspell:ignore readset -->
# M3.12 integration source advisory

One runtime author independently reviewed the cross-author App/bootstrap/Session/Looper integration. This is a bounded advisory, not independent certification of the runtime files I authored or a complete current-head gate. Hashes are in integration-readset-v1.json. No product edits; only the two expressly authorized private storage-error probes were executed.

## Cross-file traces and removed invariants

- App creates one PlaybackOptions owner before providers, provides the same owner to LooperBloc and Control, exposes it by value, subscribes to refusal/recovery notifications, and closes Control before PlaybackOptions/Tempo/Mix. The prior duplicate provider construction is removed.
- Bootstrap stages and validates all nine scalar reads before any Decay setter and audio start; absent track values are deliberately applied as null rather than skipped. Once and unrelated restore paths remain independent. Native engine.c establishes eight tracks; the atomic per-track feedback setter accepts inheritance through a negative sentinel.
- Session gates acquire Mixer, then Click, then Decay. Session capture reads the immutable durable default/override map under that gate, preserving explicit zero and projecting Released. Load does not await queued outgoing Control cleanup while holding the owner queue; repository lifetime advancement fences late cleanup. No flush/recovery self-wait was added inside the Decay gate.
- Looper ordinary track events use the shared owner, retain admitted futures for persistence flushing, and remove them in finally. The old unchecked repository-plus-unawaited-store path is removed. Default edits already call PlaybackOptions.
- Playback UI reads accepted owner membership, gates uninitialized Decay editing/readout, and keeps Once available. Settings recovery and PowerOff Retry use the owner result; shutdown synchronously retires controls before waiting, recovers only on explicit Retry, retries owed cleanup, and flushes Decay before goodbye/halt.

## Findings and disposition

1. Confirmed all-eight restart omission in runtime LooperRepository (outside independently authored integration): bootstrap nulls correctly remove overrides while stopped, but replay iterated only explicit entries. Thus inherited slots never reached native and Track 8 refusal was missed. Root owns the minimal fixed-eight loop repair. The bootstrap fake records actual null setter calls correctly; assertions must remain unchanged. My earlier package tests asserted only explicit slots and missed this invariant.
2. Confirmed stale plain storage exceptions in runtime PlaybackOptions (also outside independent integration scope): delayed checkpoint read failure, and a mutated write failure followed by successful rollback, after repository replacement poison the replacement flush through rejected _last. Both private probes fail against owner SHA 3c5940ffda51bab2117e7ce22eff1d76756e01fc99224ba725715a1ee29bf75f. Root owns the catch guard after compensation; failed compensation must remain recoveryRequired. Evidence runtime-stale-error-before.log and unchanged probe SHA daa1b704393515e10935c8cc68d35709c6e8c3baa67021e3959ee7368e3e81ea.

No additional actionable integration-source finding was identified in the inspected delta. Tests inspect persisted membership, pending barriers, actual refusal and halted/not-halted outcomes, rather than implementation text. The native session suite is explicitly environment-gated; screenshots and actual device behavior are not certified here. Aggregate/static/current-head CI and independent native oracle remain coordinator gates; this advisory does not mark readiness.
