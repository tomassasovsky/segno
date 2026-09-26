# Architecture Review

September 8, 2026. Independent review of the local session connection-repair
proposal against `/tmp/segno-connection-repair-before`, following the specified
workflow role and build reporting contract. The parent authored Library, host
and CSS integration; another agent authored the pure model and test suite.
The reviewer authored none of this delta. The unchanged prior session-ownership
implementation is an integration dependency, not independently re-reviewed here.

Scope is the approved design plan `docs/plan/2026-09-08-session-connection-repair-plan.md`.
This is JavaScript/HTML/CSS under `docs/design` inside a Flutter repository.
Established study callbacks and pure models are the applicable pattern; no
production Bloc/native refactor is inferred. No commits, PR head, merge, CI,
Pen or physical-controller validation is certified.

## Layer separation

Violations found: 0.

- `session-connection-repair.js` accepts a saved snapshot, current physical state
  and explicit availability. It returns choices or an independent repaired
  snapshot/error result. It has no DOM, storage, timers or device side effects.
- Library owns the original saved entry, base snapshot, pending replacement
  copy, affected-assignment review and interaction lifetime. Selection changes
  only that copy. Reset retains any preceding media repair while discarding
  connection choices; Cancel discards the complete pending request.
- The host supplies current inventories and retains the existing projection and
  storage publication boundary. Source availability and exact target identities
  are rechecked against the incoming session at final Open. Live physical setup
  and held contacts are only handled by the established successful publication
  path, after storage has accepted the candidate.

## State management assessment

Correct for the bounded prototype.

CTRL repair requires matching configured type, valid current expression
calibration and required switch hardware. A destination already assigned in the
incoming session is refused, including dormant or rack-only references. Moving
a control relocates its complete musical port and every rack activation
reference while updating the saved requirement. Physical type/calibration are
not copied from the saved session.

MIDI repair changes exact device IDs for all mappings on that source. It keeps
message kind, number, channel, ranges, target IDs and enabled state. Destination
collisions include Omni overlaps and disabled mappings. Same names do not
resolve identity. Unavailable parameters remain unresolved after a connection
repair rather than becoming an unrelated control.

`pendingUnchanged()` rechecks the actual archived entry before choosing or
applying. Failed storage and newly unavailable dependencies retain the same
pending repair and old playable rig. Successful publication archives the
outgoing session and replaces the incoming state together. The final selection
adapter consumes affected labels from the validated repair result; it no longer
performs a duplicate options lookup.

## Lifecycle and resolved finding

The initial host recomputed foot-button meaning at release. The reviewer
reproduced this in the normal Chrome host: hold the USB replacement button,
disconnect USB, release, and MIDI In was staged instead because choices had
renumbered. This actionable finding is resolved in the recorded revision.

Contacts now retain the exact action and a pending context containing a request
token, revision, dialog kind, source, page, issues and staged changes. Release
consumes the contact and checks that context. The repair model revalidates the
original replacement ID. The monotonic revision also rejects Back followed by
reentering an otherwise identical picker. Cancel/reopen, Reset, issue-list
refresh and page changes cannot reuse a stale held action.

There are no new subscriptions, timers or asynchronous jobs requiring disposal.
Library exit/reveal/Cancel and existing media recovery maintain their explicit
pending-state lifetimes. Foot STOP, MODE, CLEAR and BANK are bounded to repair
while that request owns the contacts.

## Dependency direction and package structure

Direction violations: 0. Pure model → result, Library → injected callbacks,
host → current-state adapters. No cycle or new package dependency was added.
Separate package manifests are not appropriate for these existing local studies.

## Verification and verdict

The new model passes 19 tests; the combined connection, ownership, media and
recovery suites pass 72 tests. The normal-host browser suite passes Chrome and
Firefox, including exact identity, failed publication, retained drafts, reload,
media plus connection repair, full encoder selection and foot/contact races.
Syntax and baseline whitespace checks pass.

Architecture is clean for local design review on the recorded hashes. There
are no unresolved actionable findings; production and hardware remain outside
this conclusion.

## Reviewed SHA-256

Paths are under `docs/design`. Main HTML review is bounded to the new repair
script/adapter, review fixtures and foot-contact integration over the baseline.

| File | SHA-256 |
| --- | --- |
| `session-connection-repair.js` | `43080e7bc69916a0575322e36e1e73cf8cbf954cb7a84a4a70065c50d331ac7a` |
| `session-library-study.js` | `4af02ea38e908b1f44575d8452b8ebe820ad1ad4bdd628f1f23e9456518873e9` |
| `session-library-study.css` | `425905c502838a59d29eae8b24bedebcd21c7a18d547ea4ce2a18b8644438446` |
| `fx-ux-prototype.html` | `c745de666af7687569f823d95bf92949f7a8b02b9792f5625651a946297af3b8` |
| `verify_session_connection_repair.cjs` | `9a61c070580668046bb965ca08b6b41ffb211ae8f6ea604ad3ab28a2d83ad9d4` |
| `verify_session_connection_repair_browser.cjs` | `1bb5c330ac09bfc3b9b7c8319192157b05b19c9eb5bf3b949e03707b12b3a8dd` |
