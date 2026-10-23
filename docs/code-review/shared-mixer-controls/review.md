# Bug-focused review: shared Mixer controls

Base: `06633b2b537efba4c59108e38764e58c0b2c542e`.
Scope: intended shared Mixer target, dispatch, persistence, endpoint editor,
session projection, test and design-reference changes. Unrelated working
changes are excluded.

Reviewed source: 56 files in the [source manifest](../../reviews/shared-mixer-controls/source.json),
fingerprint `4f84e5257a79f854588a263055cf236c0c684f28f1f794cf13fc566646c77f45`.
Status: clean for this bounded revision, with no unresolved actionable
findings. A commit must contain these exact blobs to retain this evidence.
Ready-to-merge additionally requires observed CI on that committed head;
the existing human merge gate remains in effect.

Reviewed angles include changed functions and their callers, removed
track-only/direct-write paths, target serialization, source and session
lifetimes, durable rollback, failed cleanup, topology invalidation, hot-path
catalogue cost, shared scale reuse and Save/Cancel behavior. No native C/FFI
or firmware code changes are in this slice.

Cross-author reviews and a separate behavioral adversary found and repaired
the issues recorded in the [consolidated review](../../reviews/shared-mixer-controls/review.md).
All 52 final independent probes pass, including the unchanged regression
that exposed stale durable state. The final ordinary application run passes
2,525 tests at 90.0054% coverage; the controller package passes 30 tests at
83.2237%. Formatter, strict analysis, positive Bloc scan and whitespace pass.
The twelve fixture repairs retain all assertions and have a separate
independent review. The sole later product edit after adversarial execution
is an equivalent adjacent-string split for the line-length lint.

No hardware proof or full live-owner session-load recovery is claimed. The
inherited load failure reproduces on the parent and remains an M5 item.
