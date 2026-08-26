# Generator debt from the 2026-08-19 review sweep — the sequencing call (#767)

Status: **items 1–4 shipped, items 5–14 verified still open, sequencing is the
decision.** The sweep's verifier-integrity half (frozen ring station, unchecked
STAND_ANCHORS, phantom render screws, the POST_H stack) landed in PRs #771 and
#772 and is on master. What remains is the dedup/altitude batch — and the only
real question left is *when* each piece runs relative to two events: the #762
caliper batch (the next geometry change) and the once-only metal order.

## Current state (verified against master, 2026-08-25)

Every remaining item was re-checked against `hardware/enclosure/segno_enclosure.py`
on master (post-#792, which resized the ring to the Ring 24 — the item-1 fix in
#771 is exactly the verifier that validated that resize). Line numbers below are
from this audit.

- **5 — the 0.443 reseat constant.** Still pasted at `RING_FLOOR` (l.239),
  `FACE_SEAT` (l.280), and disguised as `0.43 / cos` in `FSW_FRONT_EXTRA`
  (l.877). One site fewer than the issue lists: `POST_FACEDRIFT` was retired
  outright by #771's POST_H derivation. Three copies of `2*tan(SLOPE)` remain,
  each with its own prose.
- **6 — M3 literals.** `D_M3 = 3.2` (l.673) is the only named M3 constant.
  The tap pilot is a bare `2.5` in `dxf_base` (l.2584) and the lid clearance a
  bare `3.4` at l.2387/2389, l.822, and l.3820 (the 15.6 stand's anchor bores).
- **7 — post-foot keep-out, twice.** The gate carves it with a +2 margin
  (l.1526), the vent generator with +4 (l.2012); both hand-roll the overlap
  test beside the existing `_overlap()` (l.1411). The keep-out currently drops
  ZERO vent slots (field ends u571, feet start u601) — its comment oversells.
- **8 — front-lip screw height, twice.** `dxf_faceplate` computes it inline
  (l.2387, the trig expression); `dxf_base` computes `_fscrew_flat` (l.2452).
  Equal today to 15 decimals — nothing asserts they stay equal.
- **9 — the underside plane, thrice.** The measured `12.437` intercept lives
  at l.1130 (POST_H), l.3733 (15.6 stand), and by proxy in `S7T_H0 = 66.06`
  (l.363, whose comment quotes `12.43`). Two hand-rolled sloped-`wp()` helpers
  (l.3734, l.3900).
- **10 — tab-boss recipe.** Still magic numbers duplicated between the 7in fit
  test and the tower; no `S7C_BOSS_R` / `S7C_PILOT_D` exist. The fit test is
  supposed to *validate the tower's recipe* — it validates a copy.
- **11 — tower notch.** Raw literals in mixed frames at l.3968
  (`.center(0.0, -64.0).rect(70.0, 32.0)`).
- **12 — `PEDAL_AP_DEV`** (l.870) still applied at exactly one leaf, the pedal
  slots (l.1149), and the pad-vs-slot gate still tests the pre-shift edge.
- **13 — `hardware/segno_enclosure_design.md`** still carries `screen_bracket`
  rows (l.206, 470, 615) and PEM/clinch rows (l.538, 592, 609–610).
  `hardware/MANUFACTURING.md` was purged in-branch and now **actively
  contradicts** them: "NO clinch nuts anywhere", screen-bracket row deleted
  with a note saying why. Two fab-facing documents, one wrong.
- **14 — `above_deck` cutter** built at l.3918 and rebuilt inside the rib loop
  (l.3930).

Context shift since the issue was filed: the vendor zips now have real
producers with a freshness gate (`build_quote_packages`, l.4824+), and the
metal is **not yet ordered** — release is gated on #762's caliper session.

## The decision for the owner: when does each slice run?

None of items 5–14 blocks the metal release; that gate belongs to #762 alone.
But the items are not equal in risk, and "before or after the metal order" is
the wrong axis — the right axis is **before or after the #762 caliper batch**,
because that batch is the next real geometry change and it lands directly on
the traps items 5 and 8 describe.

**Option A — everything before the metal order.** Maximum cleanliness, but it
puts a 10-item refactor of fab-truth code between today and a once-only
manufacturing run, for zero fab benefit — the refactor changes no dimension by
construction.

**Option B — everything after.** No pre-order risk, but the caliper batch then
executes on top of the known duplication: item 8's twin encodings are exactly
the kind of pair that splits silently when someone touches `H_FRONT`-adjacent
geometry, item 5's pasted reseat is the same story, and item 13's stale doc is
*read by the human preparing the order*.

**Option C (recommended) — slice by what the caliper batch and the order
actually consume:**

- **Slice 1, now, before the caliper batch:** items **13** (doc purge — pure
  docs, zero risk, directly order-facing), **8** and **5** (one
  `FRONT_SCREW_Z`, one `RESEAT_CAL = 2*math.tan(math.radians(SLOPE_ANGLE))`).
  Three tiny, individually revertable changes under the identical-output gate
  below.
- **Slice 2, after the metal order ships:** items **6, 7, 9, 10, 11, 14** as
  one mechanical-dedup PR. Same gate. These share no geometry risk with the
  caliper batch, so there is nothing to gain from doing them under time
  pressure next to it.
- **Slice 3, after the metal order, as its own mini-design:** item **12**. The
  `v_lid -> v_plan` transform is not a dedup — it changes where a compensation
  is *expressed*, other lid features carry their own compensations with their
  own reasons, and the pad-vs-slot gate currently tests the pre-shift edge (a
  behavior question, not a style one). It needs a short design note deciding
  the exemption list and what the gate should test, then a PR.

Recommendation: **C.** Sub-question for the owner inside C: slice 2 is
mechanical and fully verified by the gate — is it `autonomy:auto` at the PR
level, or does the "fab-truth file" location alone keep it `merge-gate`? The
plan assumes `merge-gate` for all three slices unless told otherwise.

## Implementation outline

Slice 1 (one PR, or three commits in one PR):
1. Purge `hardware/segno_enclosure_design.md` rows 206/470/538/592/605–611 the
   same way `MANUFACTURING.md` was purged (state what replaced them, don't
   just delete).
2. `FRONT_SCREW_Z`: hoist the shared expression, use it in `dxf_faceplate` and
   `dxf_base`, and keep one assert pinning its value so the next `H_FRONT`
   change is a conscious one.
3. `RESEAT_CAL`: define once next to `SLOPE_ANGLE`, substitute at l.239/280/877
   (the 877 site keeps its own `/cos` development factor — only the raw 0.43
   collapses), keep each site's comment pointing at the shared story.

Slice 2 (one PR): `D_M3_TAP_PILOT` / `D_M3_LID_CLR` beside `D_M3`; one
post-foot keep-out helper reusing `_overlap()` with ONE margin (decide +2 vs +4
by what the gate is protecting, and fix the "drops slots" comment); one
`LID_UNDERSIDE_Z0 = 12.437` + `lid_underside_z(y)` helper consumed by POST_H,
the stand, and `S7T_H0`'s derivation comment; one shared sloped-`wp` factory;
`S7C_BOSS_R` / `S7C_PILOT_D`; notch anchored to `cy_w`/`wall`; hoist the
`above_deck` cutter out of the rib loop.

Slice 3 (design note + PR): the `PEDAL_AP_DEV` transform, per the decision
above.

## Verification plan

- **The identical-output gate, applied to every slice:** run the full
  generator on master, snapshot `out/` (DXF entity dumps via `ezdxf` +
  SHA-256 of STEP/STL), apply the slice, run again, diff. DXFs and STEPs must
  be geometry-identical; PDFs are excluded from raw hashing if timestamps make
  them noisy (their DXF sources are the fab truth anyway). Any diff at all
  fails the slice — these changes claim to move nothing.
- All existing gates stay green with **unchanged counts**: `_check()`, the
  drawing/package gates (#775), the fold render + collision audit
  (`_fold_from_dxf.py` — which now exits 1 on ERROR, per #772).
- Slice 1 doc purge: grep proves no `screen_bracket`/`PEM`/`clinch` row
  survives in `segno_enclosure_design.md` outside history notes.
- Nothing here needs a physical fit test — no `blocked-verify`. The existing
  physical validation (7in fit-test round-2 PASS) is exactly what the
  identical-output gate preserves.

## Acceptance criteria

- Items 5–11, 13, 14 closed with zero geometry deltas, proven by the gate.
- Item 12 has a written decision (transform + exemptions + what the pad gate
  tests) before its code lands; the issue closes only after that PR.
- The 0.443/0.43, 2.5, 3.4, and 12.437 literals each exist in exactly one
  place; the front-lip screw height and the post keep-out each have one
  encoding.
- `segno_enclosure_design.md` and `MANUFACTURING.md` agree with each other and
  with the generator.

## Non-goals

- No geometry, tolerance, or fab-output changes of any kind — that is the
  point of the gate.
- Not the #762 caliper batch, and not blocking it: slice 1 lands before it,
  slices 2–3 after the order ships.
- No new verifier features beyond the constants the dedup naturally creates
  (the verifier-integrity work was items 1–4 and is done).
- No purge of `docs/` history notes that mention brackets/PEM as *history*.
