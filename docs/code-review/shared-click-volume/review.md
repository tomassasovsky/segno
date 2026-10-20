# Bug-focused review: shared Click volume

Base: `42e5e849ec21bc5cd6a6feae0251a96923556ba7`.
Reviewed 83 intended files in the [source manifest](../../reviews/shared-click-volume/source.json),
fingerprint `54e4f2763b5467a67d42a31eb4d0e5eb3d896eeb7362c14b7f414794f12953cd`.
A published commit must contain those exact blobs to retain this review.

**Clean for this bounded revision: no unresolved actionable findings.**
All required review perspectives completed. Cross-author runtime, model/UI,
fixture, App/session/shutdown and final repair reviews were combined with a
separate behavioral adversary and coordinator integration review. Sequential
role reports do not imply five distinct reviewers.

Completed angles: changed functions and callers, removed immediate-save and
log-and-continue behavior, exact scalar absence, callback publication, queued
source lifetimes, target serialization, startup and close ordering, lock order,
held-value projection, failure UI, existing helper reuse and scope/simplicity.
No real-time C callback, FFI symbol, generated binding or firmware changed.
Presentation still calls owners/repositories rather than data clients. The
Click owner is shared; it does not duplicate the MIDI interpreter or Mixer
scale. The resolver keeps blocked-but-known targets visible for owed cleanup,
while owner admission rejects writes during unresolved recovery.

All 55 final independent probes pass, including the unchanged regression for
replacement-session gain and both checkpoint-failure guard probes. Ordinary
application and affected package suites, configured coverage, explicit format,
strict analysis, positive Bloc scan and whitespace pass. Four native renders
and the actual desktop Save/Cancel journey were inspected; matching Pen
references are saved. See [verification](../../reviews/shared-click-volume/verification.md)
and [resolved findings](../../reviews/shared-click-volume/review.md).

Limits: desktop/native tests do not establish physical control timing or
appliance halt. The inherited complete session-load defect with a live
Control owner remains M5 work. The independent report names other unexecuted
interleavings. Ready-to-merge requires observed CI on the final committed head;
no merge authority is implied by this clean review.
