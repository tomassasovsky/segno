# Shared Playback: consolidated review

Base: `f186bb952d1d000522c5e8e55226bc2ee0931538`.
The [source manifest](source.json) binds 91 product, test and render files,
fingerprint `d8ceaa9043a2050772f4f953c646ac326010af35159b50702c18e88924f81faf`.
The saved design has its own [binding](design.json). Unrelated controller
analyzer configuration and older raw reviews are excluded.

One independent non-author reviewer completed VGV, architecture, test quality,
simplicity and PR-readiness perspectives, plus the independent 50-case matrix
and negative control. The coordinator reviewed the combined source and callers,
App/bootstrap/Session integration, retained failures, actual UI and design.
These are complementary roles, not five separate reviewers. Final test-fixture
delta review is recorded [separately](raw/adversary-fixture-delta-review-v1.md)
from the initial executed binding. Exactly seven test inputs changed; all 29
product sources, independent harness/oracle and native library are unchanged.
No unresolved actionable finding remains in this bounded source review.

## Resolved findings

- **M313-A1:** Retry could repair native state and bypass failed initial stored
  bool validation. Recovery now repeats staged initialization when needed.
- **M313-A2:** A restart during blocked startup reads could permanently strand
  readiness. Admission retries with the new device lifetime; a replacing
  session instead supplies its verified snapshot.
- Startup and reconnect now replay all eight effective bits, including false,
  with autonomous callback receipt and a bounded deadline. Empty inheritor
  masks are owner-only changes, without invented engine commands.
- A session's Once choices apply as one final vector. Session Save reads
  durable Once and Decay under one Playback gate rather than nesting the same
  queue or capturing live Held values.
- Touch, MIDI and External now share confirmed values and exact bool
  checkpoints. Nullable ordinary resets invalidate older cleanup without
  confusing explicit false with inheritance or erasing source contact.

No compatibility target, duplicate owner, new native API or storage envelope
was added. The [verification](verification.md) distinguishes ordinary, native,
visual and sensitivity evidence. Physical proof and the inherited M5 live
Control recall issue remain outside this slice. Published-head CI and human
merge approval remain separate from the local source review.
