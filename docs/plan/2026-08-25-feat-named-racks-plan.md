# Named racks — save a chain, load it anywhere, notice when it drifts (#535)

Status: **direction settled, plan ready for review.** The two calls that made
this `plan-gate` were answered by the owner on the issue (2026-08-10): racks
are **rig-global**, and MODIFIED means **any audible difference** from the
saved copy. This plan grounds those calls in today's code and leaves three
narrower decisions, each with a recommendation.

## Current state (verified 2026-08-25)

**What exists is the chain, not the rack.** `TrackEffect`
(`packages/looper_repository/lib/src/models/track_effect.dart`) is a sealed
pair: `BuiltInEffect` (type + params + `enabled`) and `PluginEffect` (a
`PluginRef`, a base64 `state` blob — the persisted plugin state, D-P1 —
transient `params` metadata, a resolved `name`, and `enabled`). Chains hang
off lanes, tracks, inputs, and the master insert, and are edited through
`lib/looper/view/signal/signal_fx_editor.dart`. (The issue body's
`SignalFxRack` reference is stale — that widget predates the IA rebuild.)
Nothing names, saves, loads, or tracks divergence: no rack model, no storage
key, and the cards' empty state already says so
(`signalTapToLoadRack` in `lib/looper/view/signal/signal_cards.dart`).

**The pen is ahead of the app.** The manager screens are drawn:
`SIGNAL / library`, `rack-new`, `rack-delete`, plus `signal-detail`'s rack
chips and `signal-input`'s MODIFIED badge — confirmed absent-but-drawn by the
#663 geometry audit ("absent, tracked #535"). Delete semantics are pinned in
the pen's `c/` notes: deleting a rack never reaches into loaded cards (their
chain is their own copy — the card reads "no rack" on next draw) nor into
frozen copies in takes, where the name is provenance, not a reference.

**One pen note is stale against the settled rule.** The `c/signal-input` note
excludes the chain's own power from MODIFIED ("on/off is the card's switch");
the owner's later 2026-08-10 call deliberately **includes** chain power and
per-entry bypass ("a bypassed reverb is not the rack you saved"). Per the
repo's deviation-updates-the-pen rule, the note must be rewritten before
build — see prerequisites.

**The fingerprint is not the diff.** The issue thread points at
`fxChainFingerprint` as the shape to reuse. Verified: it folds
`chainEnabled`, each entry's `typeCode` + `enabled`, and **built-in params
only** — for plugins it deliberately folds type + enabled bit and skips the
state blob. Under the settled "would this render differently" rule that
under-detects: a knob moved in an open plugin window is audible and must show
the badge, but never flips the fingerprint. MODIFIED needs its own compare.

**Persistence landscape.** Rig-level settings live in `settings_repository`
over a `KeyValueStore` (SharedPreferences via `local_storage_client`).
Sessions are `.segno` bundle directories with a versioned manifest
(`packages/session_repository`, currently v7, forward-rejecting). The epic's
decision record (PR #480, D1–D3) binds: global library with session
references; an inherited rack is a frozen copy carrying its origin name;
existing anonymous chains migrate unnamed.

## Decisions for the owner

### D-A. Storage medium for the rig-global library

- **A1 — `KeyValueStore` JSON under a `racks.*` namespace.** Literally
  "beside the device-keyed settings". Cheap, but a rack carries plugin state
  blobs (base64, easily tens of KB each), and SharedPreferences rewrites one
  file for the whole store on every set — poor fit on the appliance, and no
  per-rack atomicity.
- **A2 — a `racks/` directory sibling to the session root, one JSON file per
  rack** (recommended). Same file-IO idiom `session_repository` already
  uses, atomic per-rack writes, no size anxiety, and a future
  bundle-embedding export is a file copy. "Beside the rig-level settings" in
  the owner's call reads as a scoping statement (rig-global, not
  per-session), not a medium mandate.

**Recommendation: A2**, housed in a new `rack_repository` package (model +
file store) depending on `looper_repository` for `TrackEffect` — mirroring
how `session_repository` owns its own IO, and keeping the layer boundaries
the repo enforces.

### D-B. Rack identity: name or id?

- **B1 — name is the key.** Matches the pen's surfaces (everything displays
  names), but rename breaks every session reference, or forces a rewrite of
  every manifest on disk.
- **B2 — generated id + display name** (recommended). Sessions reference the
  id; rename is free; the reference also stores the last-known **name** so
  an unresolvable reference on another rig can still read "this slot came
  from *Dirty rhythm*, which you do not have" — the exact state the owner's
  call requires — and a frozen copy's provenance name (D2) costs nothing.

**Recommendation: B2.**

### D-C. The MODIFIED compare for plugins

Built-ins are fully comparable (type, `enabled`, params — value-compare, per
the audible rule). Plugins are not: their audible parameters live inside the
opaque state blob.

- **C1 — reuse `fxChainFingerprint`.** Rejected above: blind to plugin
  audible changes, the badge would lie exactly where plugins are used.
- **C2 — dedicated `rackDiffers(live, saved)`** (recommended): entry count +
  order + type/ref, per-entry `enabled`, chain power, built-in params by
  value, and for plugins **ref + `enabled` + state blob equality** as the
  closest computable proxy for "renders differently". Over-detects only when
  a plugin rewrites its blob without an audible change — acceptable: the
  badge errs toward showing, never toward hiding a drift. Excluded, per the
  owner's rule: nothing (a bypassed entry still contributes its `enabled`
  bit; its params still compare — see caveat below).

**Caveat to pin in review:** the owner's rule excludes "a bypassed entry's
parameter values" as inaudible. Strict compliance means skipping param/state
compare for entries whose `enabled` is false — but re-enabling such an entry
then flips MODIFIED late (on the toggle, not the nudge), which is still
correct at every moment the badge is read. **Recommendation: implement the
strict rule** (skip params of bypassed entries); it is the rule as given and
the late flip is its designed behaviour.

### D-D. Bundle embedding — reconcile the two proposals

The pen-era proposal had session bundles embed the racks they reference; the
settled 2026-08-10 call is reference-only with a graceful missing-rack state.
**Recommendation: reference-only now** (it is the settled call); embedding
becomes an explicit non-goal, one to revisit as an export option.

## Implementation outline

Three parts, buildable in order; each is a PR-sized slice.

**Part 1 — domain + store.** New `rack_repository` package: `Rack` model
(id, name, ordered `TrackEffect` list — reusing looper_repository's
serialization), file store under `racks/` (list, read, write, rename,
delete; atomic write-then-rename like the session writer), `rackDiffers`
per D-C. Anonymous existing chains are untouched (D3): no migration code at
all, absence of a reference *is* the migrated state.

**Part 2 — manager + load/save UI.** `SIGNAL / library` (count, rename,
`+ New rack`), `rack-new`, `rack-delete` (confirm names what is loaded and
what deleting costs), rack chips in `signal-detail`, card headers naming
their rack or `no rack · tap to load one`. Load copies the rack's effects
onto the target scope (input live chain, lane, track bus, master insert) and
records the reference; save captures the live chain under a name. Delete
follows the pinned semantics: loaded cards keep their chain and drop to
"no rack" on next draw; frozen take copies keep their provenance name.

**Part 3 — MODIFIED + session references.** Session manifest gains an
additive, presence-keyed rack reference per slot (id + last-known name); an
older bundle without the key loads unchanged; an unresolvable id renders the
"rack you do not have" state and never clears the chain. `signal-input`
draws the MODIFIED badge off `rackDiffers`.

### Build prerequisites (pen)

`segno-ui.pen` is authoritative and must be touched before part 2/3 build:

1. Rewrite the `c/signal-input` MODIFIED note to the settled rule — chain
   power and per-entry bypass **included**, bypassed entries' params and
   inaudible state excluded.
2. Verify `SIGNAL / library` / `rack-new` / `rack-delete` /
   `signal-detail` still fit the current tray geometry post-#663 sweeps; add
   the missing-rack ("came from a rack you do not have") state to
   `signal-detail` or `signal-input` — it is not mentioned in the audit and
   is likely undrawn.

## Verification plan

- `rack_repository` unit tests: store round-trip including plugin state
  blobs; rename preserves id; delete removes the file only; corrupt/partial
  file skipped not fatal (session enumeration's idiom).
- `rackDiffers` table tests, one row per clause of the audible rule: entry
  added/removed/reordered/retyped, per-entry bypass, chain power, built-in
  param nudge, plugin blob change, plugin relink — each flips; a bypassed
  entry's param nudge does **not**.
- Manifest tests: v7 bundle without references loads; reference survives
  save/load; unresolvable id yields the missing state and an intact chain.
- Widget tests: library CRUD flows, chips load, badge appears/disappears
  across a save. Screenshot goldens regenerate on the author's machine only
  (known constraint) — regen + eyeball after part 2.
- `dart analyze`, `bloc lint`, full `flutter test` per the repo verify loop.

## Acceptance criteria

- A chain saved as "Dirty rhythm" on one session is loadable onto any card
  in any session on the same rig.
- Rename never breaks a session's reference; delete never mutates a loaded
  chain or a frozen take copy.
- MODIFIED shows exactly per the settled audible rule, including plugin
  knob moves, and never shows on a freshly loaded rack.
- A `.segno` bundle from a rig without the rack resolves to the named
  missing state with its chain intact; pre-rack bundles load unchanged.

## Non-goals

- Embedding racks in session bundles (D-D).
- Pedal bindings to racks — that is #763's product call.
- The FX-mode stage surface (#692), even though it will want rack names.
- Rack-level presets/variations, import/export of single racks.
