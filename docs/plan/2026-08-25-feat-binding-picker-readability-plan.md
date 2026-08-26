# The binding picker reads like a rig, not a graph (#494)

Status: **half the issue shipped, the other half re-scoped.** The
consolidation this issue opens with is done — the console IA rebuild moved
Settings and Signal/Routing into the tray rail (#578, #549, #532, #626), and
the rail question ("nine or ten destinations?") was answered at eight domains
plus a pinned brightness button (`lib/looper/view/tray/tray_navigation_rail.dart`
says both out loud: "with eight domains", "a button pinned below these, not a
ninth domain"). What remains is the picker — and the picker premise has
drifted too, in a way that changes what should be built. This plan verifies
where the wall actually still stands and defines the remainder.

## Current state (verified against master, 2026-08-25)

`availableBindingTargets()` (`lib/control/binding/fx_binding_resolver.dart:31`)
still emits the flat signal-order list: every configured chain followed by its
slots — inputs, loop lanes, track buses, master. Four surfaces consume it, and
they are NOT equally broken:

- **`lib/control/view/pedal_tray_body.dart:286`** — the pedal assign picker —
  already got partial readability work: chains list first, slots hide behind an
  `_EffectsToggle` reveal (`_showEffects`, line 50), and a revealed slot row is
  named by its own effect (`fxSlotName`), indented, with the chain named at its
  trailing edge. This is NOT the fifty-entry wall anymore. What it still lacks
  is rack-level naming: a chain row reads positionally
  (`bindingTargetLabel` → "the <stage> chain"), not by the sound it changes.
- **`lib/control/view/midi_tray_body.dart:528`** — the Add sweep / Add switch
  target drawer — IS the wall, verbatim: one flat `ConsolePickRow` run over the
  whole list, and a slot's title falls back to
  `'$stage · $slotId'` (`lib/control/binding/binding_labels.dart:55`) — the
  literal FxAddress-plus-slotId label this issue was filed about.
- **`lib/pedal/view/pedal_assignment_page.dart:225`** and
  **`lib/audio_setup/view/midi_learn_section.dart:104`** — the desktop
  full-screen surfaces — also consume the flat list, with the same labels.

The dependency is still real: #535 (named racks) is open at `stage:plan`, and
its scope is the rack model and library, not this picker. This issue remains
the tracker for the consumer side.

**One premise dissolves on inspection.** The issue asks about "migration for
bindings stored against an `FxAddress`". There is none to do: #535's racks
are named chain payloads, not a new addressing scheme — a binding target stays
the canonical `FxAddress`/`slotId` string it is today
(`target.canonicalString()`), and the resolver's A9 rule (stale targets go
inert, never remapped) is untouched. Racks change what the picker *says*, not
what the binding *stores*. Any plan that invents a rack-addressed binding
format should be rejected as scope creep.

## Decisions for the owner

**D1 — keep or close.** Recommend **keep, re-scoped**: the MIDI add-target
drawer is unreadable today and the rack-naming gap spans all four surfaces.
Closing would orphan the only tracker for the #535 consumer work. The
consolidation half should be declared shipped in the issue body.

**D2 — the two-level shape.** Options:

- (a) **Two-level drill**: level 1 lists chains (named by rack once #535
  lands, positional label until then), tapping one shows its slots. List
  length scales with racks, exactly the issue's ask.
- (b) **Extend the pedal picker's reveal shape everywhere**: chains + one
  global "show effects" toggle. Cheapest, but a revealed list still scales
  with total effects, and on a MIDI drawer of ~50 entries the toggle just
  toggles the wall.
- (c) **Grouped single list with section headers**: middle ground, still one
  long scroll.

Recommend **(a) for the MIDI add-target drawer** — it is a `ConsoleDrawer`
picking exactly one target, the natural drill — and **keeping the pedal
picker's shipped chains-plus-reveal shape**, upgrading only its labels. Two
surfaces, two shapes, each already half-built toward its own.

**D3 — sequencing against #535.** The drill structure and the label plumbing
do not need rack names to exist; they need a name *slot* to render. Recommend
building the structure now with today's chain labels and letting #535's rack
names drop in, rather than blocking this behind #535 — the MIDI drawer is the
worst surface in the tray today and the fix is structural, not nominal. If the
owner prefers one motion, fold this into #535's build as its last part.

## Pen prerequisite (blocking build)

The two-level picker is explicitly *not drawn* — the issue says so, and the
Pencil app was not reachable this session to verify or add it. **Build step 0
is drawing into `segno-ui.pen`** (design source, per repo rule):

- `CONTROL / midi-add-target` — the drawer's two levels: chain list state,
  opened-chain slot list state, and the back affordance.
- The pedal picker's slot rows renamed by rack (post-#535 state), if the
  owner wants that drawn rather than inherited.
- A `c/` note recording why the two surfaces get two shapes (D2).

## Implementation outline

1. **Grouping, not a new resolver API.** The picker groups the existing flat
   list by `target.address` — `FxChainTarget` heads a group, its
   `FxSlotTarget`s are its children. No `looper_repository` change; the
   resolver's ordering guarantee (chain then its own slots) is already the
   group structure.
2. **`midi_tray_body.dart`**: replace the flat `choices` run (line ~519) with
   a two-level drill inside the existing `ConsoleDrawer` — local
   `_openChain: FxAddress?` state, level 1 rows show chain title + slot count,
   level 2 shows the chain's slots named by `fxSlotName` (the pedal picker's
   existing labeler) with a back row. Sweeps (`availableValueTargets`) get the
   same grouping — a value target also carries an address.
3. **Labels**: route every chain title through one function that prefers the
   rack name when the chain carries one (a no-op stub until #535's model
   lands, one-line adoption after).
4. **Desktop surfaces** (`pedal_assignment_page.dart`,
   `midi_learn_section.dart`): adopt the same grouped widget or leave as-is
   behind a follow-up — recommend follow-up; the console is the product
   surface.

## Verification plan

- Widget tests on `midi_tray_body`: drawer opens to chains not slots; drill
  in/out; picking a slot passes the same `canonicalString` it does today
  (regression pin: stored bindings unchanged); a chain with no stable-id slots
  drills to an empty-state row, not a crash.
- Widget test on the pedal picker: reveal + labels unchanged (pin the shipped
  behavior so this slice cannot regress it).
- Goldens: regen `test/screenshots` for the Control domain after the drawer
  change and eyeball — goldens rot silently off the author's machine.
- `dart analyze`, `bloc lint lib test packages` clean.

## Acceptance criteria

- Adding a sweep or switch mapping never shows a `$stage · $slotId` row.
- The add-target drawer's first level scales with chains (racks), not with
  effects.
- Slot targets remain reachable (both granularities stay — "depends on the
  song").
- A binding stored before this change resolves identically after it.
- Issue body updated: consolidation declared shipped, scope = picker.

## Non-goals

- The rack model, library, drift detection — #535.
- Any change to binding storage format or `FxAddress` semantics.
- Tray consolidation — shipped; this plan only records it.
- Dropping inaudible targets from the resolver (worth doing, but it is
  resolver policy, not picker shape — split if wanted).
