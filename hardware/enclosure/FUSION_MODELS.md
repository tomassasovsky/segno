# The Fusion 360 models — how to change anything without wrecking them

The console lives in TWO cloud documents (Fusion Team, Default Project), edited
through the Fusion MCP (`localhost:27182`, `fusion_mcp_execute` with a script
defining `def run(_context: str)`). This file is the contract for changing them.
It was earned the hard way on 2026-08-18 (#753); every rule here broke something
once.

## The two documents

| doc | role | frame (world) |
|---|---|---|
| **VAMP sheet metal** | source parts: base, faceplate, brackets, rear_panel | x = 84.8 − u/10 (MIRRORED), y = height, z = depth |
| **VAMP console (populated)** | the full machine, the one that gets reviewed | x = u/10 (DIRECT), y = depth = v/10, z = height |

`u`, `v` are the enclosure generator's mm coordinates (`segno_enclosure.py`:
u along the 850 width from the left wall, v along the 423 depth from the front).

**The populated frame is proven by the mounts**: `base_foot_xy()` equals the
foot occurrences' translations exactly, and the platforms, Pi/N07 stack and
board mount holes all agree. If a placement disagrees with a generator mount
table, the placement is wrong, not the table.

### Canonical occurrence transforms (4×4 row-major, cm)

| component | populated | VAMP sheet metal |
|---|---|---|
| base | `[1,0,0,0 \| 0,1,0,0 \| 0,0,1,0.2]` | `[-1,0,0,84.8 \| 0,0,1,0.2 \| 0,1,0,0]` |
| faceplate (lid) | `[1,0,0,-0.19 \| 0,c,-s,-1.13191 \| 0,s,c,1.19625]` | `[-1,0,0,84.99 \| 0,s,c,1.19625 \| 0,c,-s,-1.13191]` |
| rear_panel (inside mount) | `[1,0,0,62.5286 \| 0,0,-1,41.691 \| 0,1,0,4.5]` | `[-1,0,0,22.2714 \| 0,1,0,4.5 \| 0,0,-1,41.691]` |
| console_board_v4 (KiCad STEP) | `[1,0,0,36.225 \| 0,1,0,38.575 \| 0,0,1,1.7]` | — |

`c`/`s` = cos/sin of `SLOPE_ANGLE` (12.498241812070852°) at full precision —
rounded values fail `transform2` validation (the rotation must be exactly orthogonal).

- The base's `+0.2` z puts the floor's bottom face at world z=0 (the feet plane).
  There is **no y/depth offset** — an earlier `+0.2` there put the whole shell
  2 mm rearward of every mount.
- **Lid seat (the ONLY correct anchor, from the rear-seam solver #237)**: the
  lip's INNER face lies flush on the front wall's outer face at depth
  **−DEV90 = −0.19108 cm** (the folded walls land at −DEV90, not −T), and the
  underside plane contains the solver point (depth −0.3478, height 1.1652 cm)
  at slope `SLOPE_ANGLE`. Solve the translation from the REBUILT comp's actual
  lip-inner-face plane (measure it; don't assume the lip is square to the comp
  axes). With this seat: lip flush kiss, underside on the side-wall wedge
  edges, and the rear lap resting ON the transition — total faceplate∩base
  boolean ≈ 0.008 cm³ of contact films. Verify with TemporaryBRep intersection
  volumes per lump, never bboxes (all Fusion bboxes here are loose hulls).
- **The lid stack moves together**: faceplate, ring_disc, screen_bracket (both
  docs), plus in populated screen_16in/7in, encoder, led_strips, texts,
  segno_logo, the pill diffusers. If the faceplate moves, every one of these
  gets the same delta.
- **FRONT_WALL_KNUCKLE_TRIM**: both base comps carry a cut (sketch of that
  name, offset plane at local z=0.8094) matching the generator's shortened
  front flap — the wall's square top corner cannot clear the lip-fold roll
  (#760). A future base rebuild gets this from the DXF automatically; do not
  delete the feature without rebuilding from a current flat.
- The panel transforms press its outer face on the rear wall's INNER face
  (inside mount, user decision): panel spans depth 41.691..41.891. Its x-centre
  is the generator's `rear_panel_outline()` centre /10 (recompute after any
  station change — it moves).
- Board STEP mapping: world = (36.225 + kicad_x/10, 38.575 − kicad_y/10, ·) —
  note the **y flip**. Derived so the board's H1–H4 land exactly on the floor's
  `board_mounts()` drills.
- All transforms must have **det = +1** (no mirrors — Fusion rejects or mangles
  improper matrices silently).

## The lid (faceplate) rebuild recipe

Much simpler than the base — no wrap, two folds, one per call:

1. Delete the old `faceplate` occurrence (in populated it lives INSIDE the
   "VAMP sheet metal" subassembly — delete the child; create the new component
   at ROOT). Import `out/segno_faceplate.dxf` at identity → sketches CUT/BEND.
2. Extrude the CUT max-area profile **−0.2** (top face at z=0).
3. `body.convertToSheetMetal(top_face, rule)` + `activeSheetMetalRule` (same
   T2/R2/K0.33 rule). Note: the rules collection is `design.designSheetMetalRules`.
4. Fold the LIP: BEND line at y=0.9, `foldFeatures.createInput(stationaryFace)`
   then `fi.bendLines.add(line, ValueInput(−radians(90−SLOPE_ANGLE)),
   CenterFoldBendLinePositionType, True)` — NEGATIVE angle folds down.
5. Fold the LAP: line at y=ffl+FP_V (41.5636), angle −radians(SLOPE+TRANS)
   (−36.94°). Local bbox after both: (0, 0.5335, −1.7191)..(84.98, 43.685, 0).
6. Appearance "Plastic - Matte (Black)", then transform LAST (see the seat
   above), then guarded snapshot. Setting appearance after the transform
   RESETS the transform.

## The base rebuild recipe (the ONLY supported way to change the base)

The base is generated: **change `segno_enclosure.py`, regenerate, then rebuild
the Fusion component from the new DXF**. Never sculpt the Fusion body by hand —
it will be thrown away on the next rebuild.

One MCP call per numbered step; fold steps ONE PER CALL (multi-attempt loops in
a single call have crashed Fusion):

1. Delete the old `base` occurrence. Create a new component at **identity**
   (never import into a transformed occurrence — the import bakes the inverse
   transform into the sketch) and `importManager.createDXF2DImportOptions(
   out/segno_base.dxf, comp.xYConstructionPlane)` → sketches CUT/BEND/VENT/MASK.
2. Extrude the CUT sketch's max-area profile **−0.2 cm** (down; the flat's top
   face must end at z=0). Cut the VENT profiles −0.3.
   **Every cut extrude needs `ei.participantBodies = [body]`** or it throws
   "No target body found".
3. `body.convertToSheetMetal(top_face_at_z0, rule)` and set
   `comp.activeSheetMetalRule` — the rule must be **T=0.2, R=0.2, K=0.33 cm**
   ("Aluminio (mm) (Convert)"; both docs already carry it). Folding at any
   other radius mis-lands every flap: the flat is developed for exactly these
   numbers (`dev_deduct` in the generator).
4. One sketch `RELIEFS_AND_TRIMS`, one cut: Ø6.5 mm circles at the four bend
   intersections (0,0) (84.6,0) (0,41.9) (84.6,41.9); 0.5 mm slivers off both
   front-lip ends; the rear-block overhang trimmed back to the side bend lines
   +0.6 mm (rects x∈[−0.21,0.06] and [84.54,84.81], y∈[41.85,53.1]).
   These are MODEL-ONLY clearances: Fusion's fold checker rejects the design's
   kiss-fits and cannot fold the rear wrap in ANY order (the wrap is a
   zero-clearance slide fit at the brake; boolean dry-runs prove the final pose
   has zero interference — the rejection is internal unfold bookkeeping).
5. Folds, all `CenterFoldBendLinePositionType`, all POSITIVE angles, in this
   order: **left (x=0, 90°), right (x=84.6, 90°), lap (y=50.405,
   +1.1441680444374027 rad), rear (y=41.9, 90°), front (y=0, 90°) LAST**.
   Stationary face = the big planar z=0 face whose XY bbox contains the bend
   line's midpoint. Verify the bbox after every fold.
6. **Check the front fold's result bbox.** Its moving-side heuristic is
   unstable: sometimes the floor rotates instead of the lip and the body ends
   +90° about x (bbox ≈ (−0.19,−9.75,−0.2)..(84.79,0.19,42.08) instead of
   (−0.19,−0.19,−0.2)..(84.79,42.09,9.74)). The shape is still correct — apply
   the compensated occurrence transform instead (populated:
   `[1,0,0,0 | 0,0,1,0 | 0,−1,0,0.2]`) or delete/retry; fresh components have
   folded upright. Nothing you pass (face, line direction, trims) controls it.
7. Regrow the rear wrap and lip with **OffsetFacesFeatures** (same body, no
   patch bodies): the 6 planar end faces from the overhang trim
   (|normal.x|=1, face-centre x in 0.04..0.1 / 84.5..84.58, bbox.y > 35 when
   upright) offset **+0.251**; the 2 lip-end slivers (x-centre 0.03..0.07 /
   84.53..84.57, bbox.y < 0.5, bbox.z < 1.2) offset **+0.035**.
   `createInput` takes a **Python list**, not an ObjectCollection.
8. Set the occurrence transform (step 6's table), apply appearance
   "Plastic - Matte (Black)" to the body, `design.snapshots.add()` **guarded by
   `hasPendingSnapshot`** (an unguarded call throws and rolls back the call).
9. Verify the world bbox against the table's expectations, then `doc.save(msg)`.

The rear panel is the same recipe minus folds: import `out/segno_rear_panel.dxf`
at identity, extrude the max-area CUT profile −0.2, `convertToSheetMetal`, set
the transform (its x-centre = panel outline centre — recompute!), appearance,
snapshot, save.

## Hard-won API rules (each one cost a debugging session)

- **A script exception rolls back the ENTIRE call's transaction**, including
  earlier successful mutations in the same call. Keep calls small; a clean
  `return` commits.
- **Occurrence transforms silently reset** when features are added to the
  component afterwards, and sometimes on fold delete/rollback. Build at
  identity, set the final transform LAST in its own call, then snapshot.
  Verify placement by reading `occ.bRepBodies` proxy bboxes (root space) —
  if the proxy bbox equals the component-local bbox, the transform is gone.
- `design.snapshots.add()` with nothing pending **throws** — always guard.
- Cross-doc body copies: `TemporaryBRepManager.get().copy(body)` →
  `baseFeatures.add()` + `startEdit`/`bodies.add`/`finishEdit` in the target.
  These are frozen BReps — fine for scaffolding, **not acceptable as the final
  state** (user rule: parts must be real sheet metal).
- `Combine` on bodies created in the same call's baseFeature fails with
  ALL_TOOL_BODY_REFERENCE_LOST.
- `addExistingComponent(comp, matrix)` drops the rotation part of the matrix —
  set `occ.transform2` explicitly afterwards.
- SheetMetalRule values are **read-only via the API** (`addByCopy` only). To
  get a rule with new values, create it in the UI (Sheet Metal → Modify →
  Sheet Metal Rules → right-click → New Rule).
- The viewport often doesn't repaint from scripts; trust measured bboxes and
  point-containment probes over screenshots, and never trust a screenshot
  taken without `vp.refresh()`.
- One heavy operation per call. Fusion has crashed on long fold-retry loops;
  crash recovery reopens docs as "(~recovered)".
- The populated doc is HEAVY (800+ features). Features added to a fresh
  component compute incrementally — full-document parametric edits can freeze
  Fusion for minutes.

## Change playbooks

- **Anything on the base flat** (vents, punches, window, stations): edit the
  generator → `python segno_enclosure.py` (gates run) → base rebuild recipe in
  BOTH docs; if the window/outline moved, panel rebuild too (its centre moves).
- **Rear-panel connectors**: `REAR_IO_STATIONS` / `rear_io_cutouts()` in the
  generator; screw patterns are sourced per part (see `REAR_IO_PROVENANCE`).
  Regenerate, rebuild both panels; the wall window follows the keep-outs
  automatically (`REAR_WIN_SIDE_CLR`).
- **Moving a component in the populated doc**: compute the target from the
  generator's mount tables (`board_mounts`, `pi_mount`, `buck_mounts`,
  `base_foot_xy`, `platform_foot_holes`), world = table/10 in the populated
  frame. Set transform + snapshot + verify proxy bbox.
- **The board model**: re-export the STEP from KiCad
  (`out_console/segno_console_board.step`), delete `console_board_v4`, import
  via `importManager.createSTEPImportOptions` + `importToTarget(root)`, rename,
  set the transform from the table.
- **Screens/decals**: the 16" screen carries a decal on its display slab —
  fragile; see the memory notes referenced in `docs/PROGRESS.md` before
  touching appearances (VSM saves can reset local appearances).

## What is deliberately NOT in Fusion

The DXFs/STEPs under `out/` are manufacturing truth; Fusion is the assembly
model. The model deviates from the fab flat only by: the four Ø6.5 corner
reliefs, the 0.5 mm lip-end + 0.06-level clearances above, all invisible and
standard press-brake practice. If a change matters for fabrication it goes in
`segno_enclosure.py`, never only in Fusion.
