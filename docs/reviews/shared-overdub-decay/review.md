# Shared overdub decay: consolidated review

Base: `8b740c093b7ae84fb36c19fac88914246d6278b3`.
The [source manifest](source.json) binds 76 intended product, test and render
files, fingerprint
`014a8e7cbb7887233d60c2b99c7725b7ae4b539b09f9793e0e104cbdb61a8780`.
The encrypted design has a separate [saved binding](design.json). Unrelated
controller analyzer configuration and older raw reviews are excluded.

No unresolved actionable finding remains in this bounded slice. One independent
non-author reviewer completed the five quality perspectives and independent
behavioral execution. A runtime author separately reviewed coordinator-owned
App, bootstrap and Session integration. The coordinator reviewed the combined
product changes, removed behavior, call sites and reported findings. These are
complementary roles, not five different people. See the reports under `raw/` and
the [bug-focused gate](../../code-review/shared-overdub-decay/review.md).

## Resolved review findings

- Restart replay skipped inherited slots. All eight track slots are now
  explicitly published, including null, so absent overrides cannot leave stale
  native state. Startup validates every saved scalar before audio is opened.
- Late scalar success or failure could report into a replacement session.
  Results are fenced by session/device identity and per-address revisions;
  successful compensation returns superseded without poisoning current flush.
  Failed compensation still requires explicit storage recovery.
- An old startup read failure could reject an already adopted replacement.
  Its original lifetime is checked before reporting the error.
- Retry could report success despite a failed native replay. It now preserves
  the refusal until a normal restart has confirmed the desired replay.
- Ordinary Use default and held cleanup need different meanings. The nullable
  ordinary intent invalidates only that address; a numeric Released zero stays
  an explicit override. MIDI source contact and toggle state remain intact.
- Default and track touch edits previously used separate persistence paths.
  Both now share the required Decay owner. Session capture and shutdown await
  the same confirmed writes and capture durable Released values.

Fixture adjustments preserve existing musical assertions while introducing
required owner/readiness state. Independent field initialization intentionally
allows Once editing without discarding saved Decay. Invalid percentages are
refused rather than silently clamped. There is no compatibility target, new
native API, storage envelope or alternate controller interpreter.

The [verification](verification.md) distinguishes ordinary, native, visual and
sensitivity evidence, retained failures and omitted permutations. Hardware and
the inherited M5 live-controller load defect are not cleared. These local
reviews bind the exact source blobs; published-head CI and human merge approval
remain separate.
