# Screen mounting: the endgame to metal release (#762)

Status: **most of the build is done and physically validated; what remains is
one caliper session, one batched update, and the release itself.** This
document pins what is actually left (the issue body predates ~50 landed
commits), the contingencies if the 15.6in panel measures differently than the
listing, and the order of operations — so the batch lands once, not as a
dribble of corrections.

## Current state (verified on master, 2026-08-25)

- **7in (APROTII): DONE and empirically closed.** Vendor-exact tab geometry
  (measured reference `hardware/enclosure/ref/screen7_module_measured.step`),
  lit-area re-anchor (+2.75 y), 2.0 mm fit-test plate — **round-2 fit test
  PASS** (2026-08-19): active area fills the aperture, screws land, glass
  clamps flat. Tower + fit-test builders in the generator; the fit-test jig is
  deliberately out of the vendor pack.
- **15.6in (UPERFECT): built PROVISIONAL.** `segno_screen16_stand_L/R`
  (`segno_enclosure.py` l.3704+): modular for the Ender 3 V3's 220 mm bed
  (203/185 mm segments, lap splice at x=600), each independently
  floor-anchored, VESA Ø9.3 float holes on Ø18 bosses (±2.5 mm both axes) —
  the sheet metal is already monitor-independent for VESA position.
  `BIG_BEZEL = (353.0, 208.0)` (l.297) and `S16_BODY_*`/`S16_VESA` (l.3704–13)
  are **listing numbers, flagged PROVISIONAL in-code**.
- **Anchors: in the metal and gated.** 14 stations (6 tower + 4+4 stand) in
  the base DXF and both Fusion base bodies; `STAND_ANCHORS` split 7in/156 and
  cross-checked at build time (l.2048–2107, l.3794–98) — absolute match for
  the stands, pairwise-pattern match for the tower — after the 6.0 mm
  transcription drift was caught and re-probed (46ab3221). The standing rule
  (re-probe the doc's flange holes after any `S7C_*`/placement change) is in
  the code comment.
- **Support posts: reconciled.** Generator posts won over the stale Fusion
  models; `POST_H` is derived from the measured underside plane and pinned
  45.107 ± 0.05 (l.1131–37). The posts' **rear margin is PROVISIONAL against
  the UPERFECT listing bezel** — flagged in the issue thread.
- **Docs:** `MANUFACTURING.md` already reflects stands-not-brackets and the
  M3 seam. (Its sibling `segno_enclosure_design.md` still carries stale
  bracket/PEM rows — that is #767 item 13, not this issue.)
- **Not verified anywhere yet:** the lid-service drop-over — floor-anchored
  screens mean the lid lifts off *over* the seated glass, and no gate or test
  covers that clearance today (`grep drop.over segno_enclosure.py` → nothing).
- **Loose thread:** the ring-board JST outboard ~3 mm move. The ring PCB was
  since re-cut Ø68 for the Ring 24 (#794 per `MANUFACTURING.md` §3); whether
  that re-cut subsumed the JST move must be confirmed against the #794 board,
  not assumed.

The UPERFECT panel was ordered 2026-08-15 with ~11-day transit: **the caliper
session is days away at most.**

## Decisions for the owner

**1. What gates the metal release?** Recommendation: **hold the entire
sheet-metal package for the caliper session.** The 342.5×193 faceplate
aperture is the single highest-consequence cut in the order, and the only
thing standing between it and a real measurement is a shipping delay measured
in days. Releasing the base early (its anchors are already truth-checked)
would split one vendor order in two for no schedule gain. The alternative —
release now and let the Ø9.3 floats absorb the error — covers VESA *position*
only, not body size, viewport offsets, or the posts' rear margin.

**2. VESA contingency.** If the real pattern is inside the ±2.5 mm float:
nothing to do. If it is off-pattern or a 2-hole ultra-slim variant: the fix is
a **reprinted deck with a re-derived boss field — printed part only, no metal
change** (this is what the float-hole conversion bought). The real metal
contingency is different: if the *body outline* differs enough to move the
stand feet off their clear floor strips, `STAND_ANCHORS_156` moves, the base
gets re-drilled, and the Fusion bodies get healed+recut — which is exactly why
the release waits (decision 1). Recommendation: plan the printed-deck fallback,
accept the base re-drill as the caliper session's worst case.

**3. Port side.** Ports exit the side edge in-plane. Options: right-angle
USB-C + mini-HDMI adapters with a keep-clear (no metal, no print change), or a
windowed stand wall / metal relief (new geometry days before the order).
Recommendation: **adapters + keep-clear**, already the approved direction in
the thread; only reopen if the caliper session finds a port that cannot take a
right-angle plug (e.g. kickstand hinge interference).

## Implementation outline

Strictly ordered; steps 2–4 are **one batched change**, not three PRs.

1. **Caliper session** (on arrival, the checklist from the thread): body
   W×H×D; viewport offsets on all four sides (do NOT assume centred) vs the
   342.5×193 aperture; VESA size/count/centre offset/thread depth; port edge,
   positions, kickstand hinge; glass front flatness; body bottom edge (the
   posts' rear-margin check). Also: confirm the #794 Ø68 ring board's JST
   position closes the outboard-move thread.
2. **Generator batch:** `BIG_BEZEL`, `S16_BODY_*`, `S16_VESA`, viewport
   offsets; re-run every gate (`SCREEN_RETENTION`, rear-window/body keep-outs,
   vent-clearance, post-front-vs-platform, `_check_stand_anchors`). If feet
   move: update `STAND_ANCHORS_156` from the rebuilt stands, then re-probe.
3. **Fusion batch** per `hardware/enclosure/FUSION_MODELS.md` (the editing
   contract): re-import stands, apply any base-body hole changes
   (heal+recut, never edit-in-place), full-assembly interference sweep via
   TemporaryBRep volumes (never bboxes), save both docs. After any placement
   change: re-probe flange holes before trusting the base DXF (the standing
   rule that already caught one fabrication bug).
4. **Print verification:** `_print_check.py` on `segno_screen16_stand_L/R`
   STLs (and any re-derived deck). The thresholds encode the lessons this
   project paid for: ADHESION_BAD = 0.25 (the mini tray printed on 2.5 % of
   its footprint and warped), WARP lever scoring, ISLAND/SUPPORT checks — the
   stands' corbelled 45° construction must keep them support-free, and every
   segment must stay under the 220 mm bed.
5. **Physical fit:** print the stands, bolt to the anchor stations, seat the
   panel, then the lid drop-over test — lid on and off with both screens
   floor-anchored, apertures clearing glass, cables staying put. Consider
   capturing the drop-over as a generator clearance assert while the measured
   numbers are on the bench.
6. **Release:** full regen, freshness-gated `build_quote_packages()`, drawing
   gates green, and freeze the exact zips sent on a tag/release (the ritual
   proposed in the #236 plan).

## Verification plan

- **Generator asserts:** the existing gate suite re-run post-batch, with
  `_check_stand_anchors` proving frozen==computed after any station move.
- **`_print_check.py`:** clean BED/WARP/ISLAND/SUPPORT verdicts for every
  printed part touched; segments < 220 mm asserted (the existing bed gate).
- **Fusion:** interference sweep ≈ contact films only; flange-hole coax
  probe ≤ 0.1 mm against `STAND_ANCHORS`.
- **Physical — `blocked-verify`:** panel-in-stand fit, anchor bolt-down,
  drop-over clearance, post rear margin against the real body. None of this
  is provable in CI; the issue's `autonomy:plan-gate` ceiling plus these
  checks means a human closes the loop on hardware.

## Acceptance criteria

- Every PROVISIONAL constant in the 15.6 path is replaced by a measured value
  or explicitly confirmed; no `PROVISIONAL` flag remains in the S16/BIG_BEZEL
  block or the post rear-margin note.
- All gates green after the batch; anchors truth-checked; Fusion docs saved
  and consistent with the DXFs.
- Stands printed and physically fitted; drop-over confirmed.
- The sheet-metal package released to the fabricator and frozen immutably.
- #762 closes only when the package is *sent*, not when it is ready.

## Non-goals

- No return to bonded screens; no sheet-metal brackets (deleted in #760).
- No 7in changes — that path is measured, fit-tested, and closed.
- No #767 refactors riding in the caliper batch (slice 1 of that plan lands
  *before* it precisely so the batch stays small).
- No one-piece 15.6 bridge — the 353 mm span cannot print on this bed; the
  modular constraint is permanent until the printer changes.
