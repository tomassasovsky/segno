# Architecture review

Complete with no unresolved actionable finding at the [source binding and
review disclosure](source-review.md). This is one of five roles performed by
the same independent source reviewer.

One console ingress reaches one application dispatcher; MIDI retains its
separate mapping route and shares accepted FX ownership where required.
PedalCubit projects link/raw/frame state without settings mutation. Directed
calibration and retained profiles belong to the typed PedalSetup transaction.
Accepted live logical On remains distinct from confirmed durable state, with
an unsaved warning after storage failure.

The writer reuses native owner setters and complete sibling recipes. Structural
validation prevents owner aliases. Cleanup uses the existing FIFO, while
accepted contribution order fences deferred MIDI release. There is no new
native interface, reversed package dependency, second settings store or change
to the audio callback. Atomic admission is per owner; cross-owner atomicity is
not claimed.
