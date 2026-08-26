# Enclosure `out/`: tracked artifacts vs the written policy — the call (#236)

Status: **the conflict the issue describes is real, bigger than described, and
one of its factual premises has flipped.** The repo tracks 181 files (~79 MB)
under `hardware/enclosure/out/` while `hardware/enclosure/.gitignore` declares
most of them untracked-by-policy — and since the rebrand the ignore rules
themselves reference filenames that no longer exist. Meanwhile the issue's
strongest argument for keeping the zips tracked ("no producer script exists
in-repo") is dead: `build_quote_packages()` now regenerates every vendor zip
with a freshness gate. This document defines the policy and recommends one.

## Current state (verified on master, 2026-08-25)

Inventory of the 181 tracked files:

- **88 are `out/_*` scratch renders** (PNGs, `_test_*.glb`, `_hero.svg`, …) —
  explicitly ignored by the `out/_*` rule, tracked anyway, so the rule is
  inert for them and the tips ship whatever session last committed one.
- **`out/quote_pkg/` (8 DXFs)** — tracked, ignored by rule, and now **orphaned**:
  `grep quote_pkg segno_enclosure.py _fold_from_dxf.py` finds no producer. It
  is a dead per-quote scratch directory whose DXFs duplicate the canonical
  `out/segno_*.dxf` at some past geometry.
- **5 zips** (`segno_sheetmetal.zip`, `segno_sheetmetal_step.zip`,
  `segno_overlay.zip`, `segno_pintura.zip` — plus whatever a given run packs)
  — ignored by `out/*.zip`, tracked anyway. Binary, churn on every regen.
- **Viewer artifacts** — `out/index.html`, `out/viewer.html`,
  `out/segno.glb/.gltf/.bin`, `out/segno_fromdxf.glb`, `out/raspberry_pi4.glb`
  etc.: mostly ignore-listed, all tracked.
- **The canonical manufacturing outputs** — per-part DXF + PDF + STEP/STL
  emitted by `segno_enclosure.py` (`segno_base.dxf`, `segno_faceplate.pdf`,
  `segno_screen7_tower.stl`, the pedal tiles, …). These match the gitignore's
  written intent ("the manufacturing package IS the deliverable — track it").
- **Dead rules:** seven `out/vamp_*.step` per-part rules match nothing since
  the #497 rebrand; the current per-part STEPs (`segno_platform_front_ring.step`,
  `segno_post.step`, …) have no written policy at all.

What changed since the issue was filed:

- `build_quote_packages()` (`segno_enclosure.py` l.4824+) produces all vendor
  zips **with a freshness gate** — a pack refuses to ship any file this run
  did not write. Inside a zip, staleness is now structurally impossible.
  In the *git tip*, there is no such gate: any tracked binary a partial regen
  does not overwrite ships stale. That is precisely the failure the issue
  caught (#235's zips carrying pre-bend-relief platforms), and it is a class,
  not an instance.
- `hardware/MANUFACTURING.md` instructs vendors-facing humans to send
  `out/segno_sheetmetal.zip` etc. and to **run the generator before quoting**.
  The workflow already assumes regeneration; tracking the zips adds nothing
  to it but churn and a stale-copy hazard.

## The decision for the owner

**Option A — track everything, delete the ignore rules.** The repo tip is a
complete artifact mirror. Costs: ~79 MB and growing in every clone, binary
churn on every geometry PR, review noise, and the stale-tip hazard with no
gate to catch it. The freshness discipline the generator fought for (l.4826's
comment: a hand-built zip once shipped three-week-old flats) is surrendered at
the git layer.

**Option B (recommended) — make the repo match the written policy, refreshed
for the segno era.** Track the canonical per-part outputs (DXF/PDF/STEP/STL —
the reviewable, diffable fab truth); untrack scratch, viewers, zips, and
`quote_pkg/`; rewrite the ignore rules to current names. Quotes are produced
by running the generator, exactly as MANUFACTURING.md already says.

**Option C — untrack all of `out/`, ship only release artifacts.** Purest git
hygiene, but it removes the one thing tracked outputs genuinely buy: a
diffable history of the fab geometry alongside the code that produced it, and
a working checkout where MANUFACTURING.md's file references resolve.

**Recommendation: B, plus a release ritual that neither A nor C provides on
its own.** The metal order is once-only; what that demands is an *immutable
record of exactly what was sent*, and a mutable working tree — tracked or not
— is the wrong tool for that. On each real vendor order: regenerate, let the
freshness gate pass, and attach the exact zips sent to a git tag / GitHub
Release. One sentence in MANUFACTURING.md makes it the standing rule. (This
also gives #762's release step a defined landing pad.)

Sub-decisions, with proposed answers:

- `out/rear_io_stations.json`, `out/segno_encoder_knob.step` (reference model,
  deliberately excluded from vendor packs): generator outputs, keep tracked.
- History rewrite: **no.** The ~79 MB stays in pack history; a filter-repo
  pass is a separate, riskier decision with no urgency. Same for LFS.

## Implementation outline

One PR:

1. Rewrite `hardware/enclosure/.gitignore`: drop the seven dead `vamp_*`
   rules; keep/normalize `out/_*`, `out/*.svg`, `out/quote_pkg/`, `out/*.zip`;
   add `out/*.glb`, `out/*.gltf`, `out/*.bin`, `out/index.html`,
   `out/viewer.html` (replacing the ad-hoc name list at the bottom); state the
   policy in one comment block: *canonical generator outputs tracked; scratch,
   viewers, and per-quote bundles regenerated.*
2. `git rm --cached -r` the 88 `out/_*` files, `out/quote_pkg/`, the zips, and
   the viewer artifacts (~100 files). `git rm` (not `--cached`) for
   `out/quote_pkg/` entirely — it has no producer and its content is stale
   duplication.
3. Run the full generator once; commit the refreshed canonical outputs so the
   tracked tip is coherent with the code that claims to produce it (the #235
   staleness, fixed at the root).
4. Add the release-ritual sentence to `hardware/MANUFACTURING.md` §1.

## Verification plan

- After the PR: `git ls-files hardware/enclosure/out/` contains only canonical
  outputs — audited by name against `DXF_PARTS`, the STEP/STL builder list,
  and the two reference files; zero matches for `_*`, `*.zip`, `quote_pkg`,
  `*.glb`.
- `git status` is clean immediately after a full generator run *and* shows
  every regenerated canonical file as modified-or-identical, never untracked —
  proving the ignore rules and the tracked set partition `out/` exactly.
- The freshness gate still passes (`build_quote_packages` runs in the full
  regen), proving the untracked zips remain producible on demand.
- Repo hygiene: `du` of the tracked `out/` set drops from ~79 MB to the
  canonical set's size; record both numbers in the PR.
- No physical or geometry verification needed — no `blocked-verify`; this
  touches no fab dimension (the canonical refresh in step 3 must be reviewed
  as a regen, with any geometry diff explained by intervening merged PRs, not
  by this one).

## Acceptance criteria

- The written policy, the ignore rules, and `git ls-files` agree with each
  other, in segno-era names.
- No tracked file under `out/` can go stale silently: everything tracked is
  written by every full generator run.
- The per-quote workflow is documented end-to-end: regenerate → gate → send →
  freeze on a tag/release.
- #236 closes with the PR; the release ritual's first execution belongs to
  #762's release step, not to this issue.

## Non-goals

- No history rewrite, no LFS migration, no repo-size archaeology.
- No changes to the generator or any output geometry.
- No new CI job; the partition property is cheap to re-audit by hand and the
  freshness gate already guards the vendor-facing surface.
