# A card reads the same whether its entries are bypassed or not (#601)

Status: **idiom options defined, one recommended; the pen drawing is the
blocker, the code change is mechanical.** Follow-up from #600, which fixed
the chain-level case (`Chain off · Drive → Tremolo`) and deliberately left
this one because there was no mockup for a per-entry marker.

## Current state (verified 2026-08-25)

- `TrackEffect.enabled` is documented as bit-exact passthrough (R16,
  `packages/looper_repository/lib/src/models/track_effect.dart:143-149`) and
  is reachable from the surface — the FX editor toggles it
  (`lib/looper/view/signal/signal_fx_editor.dart:556-558`; the issue's
  `:351` line reference has drifted, the toggle survives).
- `chainSummary` (`lib/looper/view/signal/signal_cards.dart:473`) reads only
  the chain-level `enabled` flag. Bypass both entries of `Drive → Tremolo`
  and the card still reads `Drive → Tremolo` — the same false promise #525
  was about, one level down.
- `sameChainLine` (`signal_cards.dart:521`) compares type / name+ref only,
  on purpose (its doc: a knob in an open plugin window rewrites the entry at
  poll rate). So even a corrected summary would not redraw on a bypass
  toggle until `enabled` joins the comparison — safe to add: `enabled` is a
  bool flipped by an explicit user action, not a polled value.
- The summary renders as a single `Text` in `signal_card.dart` (`maxLines:
  2` on the card face, `maxLines: 1` in the compact rows) — a per-segment
  visual treatment therefore means moving those sites to `Text.rich`
  (`InlineSpan`s), or the idiom must survive in plain text.

## Decision for the owner — the idiom

How does a one-line run mark a bypassed entry?

- **Option A — dimmed segment.** `Drive → Tremolo` with the bypassed name at
  muted color. Needs `Text.rich`; and color/opacity alone conveying state
  fails the WCAG 1.4.1 bar the codebase already respects elsewhere
  (`track_column.dart` adds chain state to labels for exactly this reason).
- **Option B — dimmed + struck-through segment** (recommended). Same
  `Text.rich` move, two visual channels (weight *and* decoration), the
  universal audio idiom for "in the chain but not sounding". Reads at card
  size, keeps the run's order intact, marks *which* entry, and the a11y
  string carries it textually (below).
- **Option C — textual marker, plain `Text`.** e.g. an interpunct or
  parentheses: `Drive → (Tremolo)`. No rich-text change, but parentheses
  read as annotation, not state; and it collides with the plugin
  placeholder/loading vocabulary the cards already use.
- **Option D — count suffix.** `Drive → Tremolo · 1 off`. Cheapest, keeps
  the run clean, but names no entry — on a two-entry chain it forces the
  panel open to learn which, which is the false-promise gap half-fixed.

**Recommendation: Option B**, with two riders:

1. **All-bypassed reads like chain-off.** When every entry is bypassed the
   audible result equals `Chain off`; the run shows all segments struck
   rather than borrowing the `Chain off` prefix (the chain's own switch is
   still on — the card must not claim otherwise; this mirrors the settled
   #535 rule that chain power and entry bypass are distinct facts).
2. **Text is not the only carrier.** The card's semantic label appends the
   bypassed entries by name, in the spirit of `a11yTrackTileFxOff`.

**Pen prerequisite (gating, per the design-source rule):** draw the idiom in
`segno-ui.pen` before build — the struck/dimmed segment on the `SIGNAL`
card summaries (`signal-input` and the track/lane cards), plus the
all-bypassed state, with a `c/` note recording the rule and the 1.4.1
reasoning. #600's chain-level case borrowed the panel's own `Chain off`
word; this one gets its vocabulary pinned the same way.

## Implementation outline

1. `chainSummary` grows per-entry awareness: return structured segments
   (name + bypassed flag) or an `InlineSpan` list; the l10n `Chain off`
   composition is unchanged.
2. `signal_card.dart` summary sites move to `Text.rich`, styling bypassed
   segments muted + `TextDecoration.lineThrough`; `maxLines`/overflow
   behaviour unchanged.
3. `sameChainLine` compares `enabled` per entry so a toggle redraws the
   card (`sameChainShape` already forwards to it from both faces'
   `buildWhen`).
4. Semantic label composition extends with the bypassed names.

## Verification plan

- Unit tests: a bypassed entry reads differently from an active one; the
  all-bypassed run differs from both the normal run and the `Chain off`
  form; `sameChainLine` returns false on an `enabled` flip and true on a
  param-only rewrite (guarding the poll-rate rebuild concern its doc pins).
- Widget test: toggling an entry in the FX editor while the card is up
  redraws the summary (the issue's own acceptance line).
- Golden/screenshot regen + eyeball on the author machine for the Signal
  cards.
- `dart analyze`, `bloc lint`, `flutter test`.

## Acceptance criteria

- A card whose entries are partly or wholly bypassed is visually and
  semantically distinct from the same card fully active, and from `Chain
  off`, at both `maxLines: 1` and `maxLines: 2` renderings.
- The marked entry is identifiable (not just counted).
- The pen carries the drawn idiom + `c/` rationale before the PR lands.

## Non-goals

- Chain-level display (shipped in #600) and the FX-mode stage surface
  (#692).
- Any behavioural change to bypass itself — `TrackEffect.enabled` semantics
  are untouched.
- Redrawing on plugin param changes — the poll-rate exclusion stands.
