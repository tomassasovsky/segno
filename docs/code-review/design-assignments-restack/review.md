# Pedal assignments: bug review

Base: `0d601db8ec3450afb8ca94071ce96c969ffde1d9`.
Incoming assignments parent: `b89342e2dd8c64d08d2fa928f635016cc1f69374`.
The reviewed head is the publication commit containing the exact twelve-path
source manifest in [source.json](../../reviews/design-assignments-restack/source.json).
Its fingerprint is `410241c0e710f3dc6174cf9c175fff241f73669baab7ff78ab4f74913b602e40`.
The coordinator verifies committed blobs against that manifest before publishing;
subsequent changed bytes invalidate this binding.

No unresolved actionable findings remain. The independent reviewer inspected
the entire intended code, test and configuration diff and traced surrounding
callers, serialization, target identity, native admission, asynchronous session
ownership, cancellation, timing and actual pedal frame indexing. Removed
guards and their replacements, dependency reuse, complexity, hot-path work
and test sensitivity were included. Five quality roles were completed by one
independent reviewer; a separate adversary challenged the accepted contracts.
Neither authored the implementation.

Six product findings and one obsolete test timing fixture were repaired. The
independent probes preserve their original expectations; later display-only
changes explicitly reuse unchanged gesture evidence. See the
[consolidated evidence](../../reviews/design-assignments-restack/README.md),
[full source review](../../reviews/design-assignments-restack/bug-review.md) and
[adversarial review](../../reviews/design-assignments-restack/adversarial-review.md).

The final full application run, fresh Settings suite, source-bound unchanged
package evidence, strict analysis, formatting and actual Bloc lint pass. No
reviewer failed or remains pending. Remote CI must pass on the published head
before merge readiness; publication alone does not meet that gate.

Scope excludes the later setup and MIDI screens. Host gesture tests and native
recipe probes do not verify electrical disconnects, footswitch debounce or LED
rendering on the appliance. No physical-device validation or merge is claimed.
