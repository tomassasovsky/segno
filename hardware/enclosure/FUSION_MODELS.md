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

Populated-doc browser hygiene: root holds only the chassis (`VAMP sheet
metal`, `base`, `faceplate`, `rear_panel`, `vent_foam`) plus identity-placed
grouping components — `pedals` (10), `platforms` (20), `feet` (4),
`fasteners` (18 native ISO 7380-1 screws), `lid_stack` (screens, the
switched-off legacy `encoder`, texts (switched off), logo, support posts, and
`diffusers` = the ten `led_diffuser_*` pills; the old `led_strips` bar
component was deleted 2026-09-04), `electronics`
(Pi, NVMe, console board, bucks, standoffs). Groups are at identity, so
members keep world = local of the old root placement (`moveToComponent`
preserves world transforms; verified delta 0). The canonical-transforms
table below still applies per occurrence; only `fullPathName` gained a
prefix.

**The populated frame is proven by the mounts**: `base_foot_xy()` equals the
foot occurrences' translations exactly, and the platforms, Pi/N07 stack and
board mount holes all agree. If a placement disagrees with a generator mount
table, the placement is wrong, not the table.

### Canonical occurrence transforms (4×4 row-major, cm)

| component | populated | VAMP sheet metal |
|---|---|---|
| base | `[1,0,0,0 \| 0,1,0,0 \| 0,0,1,0.2]` | `[-1,0,0,84.8 \| 0,0,1,0.2 \| 0,1,0,0]` |
| faceplate (lid) | `[1,0,0,-0.19 \| 0,c,-s,-1.44377 \| 0,s,c,1.12715]` | `[-1,0,0,84.99 \| 0,s,c,1.12715 \| 0,c,-s,-1.44377]` |
| rear_panel (inside mount) | `[1,0,0,62.5286 \| 0,0,-1,41.691 \| 0,1,0,4.69]` | `[-1,0,0,22.2714 \| 0,1,0,4.69 \| 0,0,-1,41.691]` |
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
- **The lid stack moves together**: faceplate, ring_disc (both docs), plus in
  populated screen_16in/7in, the legacy `encoder`, texts, segno_logo, the ten
  pill diffusers, and the ROOT-level ring family (`ring_board_asm`,
  `neopixel_ring24`, `ring_holder24`, `encoder_knob_50x18_alu`,
  `ring_disc_51_5`, `ring_comet`). If the faceplate moves, every one of these
  gets the same delta. The ring family ALSO follows `ENC_V` on its own: it
  moved +7.5 mm along the plate on 2026-09-04 (219.66 -> 227.16, #930) and a
  further +2.0 mm for the LED_GAP 16 trial (-> 229.16); a plate move of d is a
  world delta of (0, c*d, s*d) in populated and (0, s*d, c*d) in VSM.
- **Support posts** (`support_post_gen`, `support_post_gen2`, root): imported
  `out/segno_post.step`, whose origin is the part's MIN corner (foot front,
  outer x edge), placed at `[1,0,0,POST_U/10 - POST_PW/20 | 0,1,0,
  (_POST_VP - POST_FOOTL)/10 | 0,0,1,0.2]` = x 60.993 / 71.093, y 14.109. The
  foot's two Ø4.3 holes then sit on the floor's anchors at v = _POST_FOOT_VP
  (151.09); the doc had them at y 13.8997, 2.1 mm forward, until the #992 audit. POST_PW is derived (30.14 since 2026-09-04, was a
  literal 40), so a flange or pitch change means a post re-import, not a move.
  The felt caps (`post_felt`, `post_felt2`) are native base-feature slabs
  trimmed to the post width.
  (screen_bracket is GONE — screens bond to the shell, part deleted in #760.)
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
3. `body.convertToSheetMetal(top_face, rule)` with the T2/R2/K0.33 rule. The
   collection is `design.designSheetMetalRules` and it holds ~23 entries all
   named `Aluminio (mm) (Convert)` at three different gauges — **pick by
   values, not by name** (`thickness`, `bendRadius`, `kFactor` are
   `SheetMetalRuleValue`s; read `.value`). There is no
   `design.activeSheetMetalRule` in this API build.
4. Fold the LIP: BEND line at y=ffl (1.21938 since the full-drop lip, #760),
   `foldFeatures.createInput(stationaryFace)` then `fi.bendLines.add(line,
   ValueInput(−radians(90−SLOPE_ANGLE)),
   adsk.fusion.FoldBendLinePositionTypes.CenterFoldBendLinePositionType, True)`
   — NEGATIVE angle folds down. Expected bbox after this fold:
   (0, 0.7838, −1.3716)..(84.98, 44.4295, 0).
5. Fold the LAP: line at y=ffl+FP_V (41.88296), angle −radians(SLOPE+TRANS)
   (−36.94°). Local bbox after both: (0, 0.7838, −1.7191)..(84.98, 44.0043, 0).
   The seat translation is SOLVED from the rebuilt comp's measured lip-inner
   plane (k = c·y − s·z of the higher-k big lip face): t_depth = −0.19108 − k,
   t_height = (1.212889 + s·(t_depth + 0.2s))/c + 0.2c. The lid's lip tip
   renders ~0.42 mm below z=0 — Fusion's fold development, not the flat's
   (ideal development puts the tip exactly at the base bottom); don't fudge
   the DXF for it.
6. Appearance "Plastic - Matte (Black)", then transform LAST (see the seat
   above), then guarded snapshot. Setting appearance after the transform
   RESETS the transform.

Run end to end in BOTH docs on 2026-09-04 (ten pills + row 2 on the 16"
line): nine calls, no retries; the seat solved from the rebuilt lip plane came
out at the canonical −1.44377 / 1.12715 to five decimals, and the proxy bbox
matched the previous lid's exactly.

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
   (A front-wall hem was tried and REVERTED, #760: its bend zone would have
   swallowed the screw holes — the 10.1 wall minus two bend zones leaves ~2mm
   of straight band. The wall is plain single-thickness; the front screws are
   M3 hand-tapped into Ø2.5 pilots, Ø3.4 clearance in the lip. The REAR lap
   seam uses the IDENTICAL joint — Ø2.5 tap pilots in the transition flange,
   Ø3.4 clearance in the lap, same 9 stations: PEM nuts were dropped so the
   whole lid fixes with ONE M3 tap and ONE screw SKU, M3×8 ×18.)
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

### Corner brackets (both docs)

The bracket is `out/segno_corner_bracket_rear.dxf` built with the lid recipe
(import, extrude −0.2, convert, ONE 90° Center fold at x = 1.2, positive angle).
Its local frame after the fold: leg A (3 rivets) in the plane x ≈ 1.109, leg B
(2 rivets) in the plane z ≈ −0.1, holes along local y; the L's inside faces
+x/+z, so the wall-touching OUTER faces are at local x = 1.009 and z = −0.2.
Leg A goes on the REAR wall, leg B on the SIDE wall (the base drills 3 rivets
in the rear wall and 2 in each side wall, staggered). The hole pattern is
symmetric about mid-height, which is what lets one part serve both corners:

| corner (populated) | transform2 |
|---|---|
| left (x≈0), **turned over** | `[0,0,1,0.21 \| -1,0,0,42.899 \| 0,-1,0,8.20]` |
| right (x≈84.8), upright | `[0,0,-1,84.39 \| -1,0,0,42.899 \| 0,1,0,0.20]` |

Rivet holes land at (1.00, 41.79, 1.00/4.20/7.40) and (0.11, 40.90,
2.60/5.80) on the left, mirrored on the right — coaxial with the base's
Ø3.2 pilots once the base is built from a DXF at or after 2026-09-04 (the
#992 audit found the base drilled every rivet 2.0 mm too close to the corner
and 1.9 mm low; `dxf_base` now develops the fold). The bracket bottom rests
on the floor top (z = 0.2), which is what the hole heights are measured from.

**Rear panel height.** Its z (populated) / y (VSM) is the rear-wall WINDOW
centre, `(2.54 + 6.84)/2 = 4.69` off the window's corner-radius centres, and
the four Ø2.5 pilots sit on the same line. The table carried 4.5 until the
#992 audit, which put the panel's mounting holes 2.0 mm under the pilots.
Nine root-level `M4 x 6` screws (the pre-#760 rear seam) were deleted in the
same pass: the seam is M3 x 8, all 18 in the `fasteners` group.

### Populated → VAMP sheet metal: one rotation for every transform

`T_vsm = F · T_pop` with `F = [-1,0,0,84.8 | 0,0,1,0 | 0,1,0,0]` (det +1: a
180° turn about the (0,1,1) axis, NOT a mirror — the x flip comes with the
y/z swap). Check: F applied to the populated faceplate row gives the VSM
canonical row in the table above. Use it instead of re-deriving VSM
placements by hand; the corner brackets, posts and mid collars in VSM were
placed this way on 2026-09-04.

## Hard-won API rules (each one cost a debugging session)

- **A script exception rolls back the ENTIRE call's transaction**, including
  earlier successful mutations in the same call. Keep calls small; a clean
  `return` commits.
- **Never `startEdit()` an EXISTING base feature from a script.** A body
  delete inside the edit threw "refers to a deleted Object" at `finishEdit`,
  and the rollback left the populated doc as a DIRECT design (`designType`
  0, every component's feature list empty); undo did not bring the history
  back. Recovery was close-without-save + reopen (2026-09-04). To change a
  base-feature body, build a NEW component with `baseFeatures.add()`,
  `startEdit` / `bodies.add(copy)` / `finishEdit`, and delete the old
  occurrence -- the pattern the felt caps use.
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

## Pedal name tiles (populated doc only)

Ten root-level `tile_*` components (`tile_REC_PLAY` ... `tile_BANK`), one per
pedal, each an **imported STEP** from `out/segno_pedal_tile_<LABEL>.step` — not
modelled here. The STEP carries two solids so the colours are per-body:

| solid | appearance |
|---|---|
| body (1.8 thick) | `Plastic - Matte (Black)` |
| glyphs (0.4 proud) | `Plastic - Matte (White)` |

**Placement.** x is the pedal's own `u/10` from `PEDALS`; the rotation is the
faceplate slope; and the tile centre sits **1.8444 cm forward of the pedal's
back edge** — note the Cherub component's origin IS its back edge, not its
centre, so compare against `occ.boundingBox.maxPoint.y`, never against
`PEDAL_ROW*_V`. Both rows agree on that offset. Row 1 lands at
`y = 10.2695, z = 4.1129`; row 2 (CLEAR, BANK) at `y = 26.4611, z = 7.7020`
(#796: row 2 is the row-1 transform plus the slope delta, see "Row 2" below).

```
[1,0,0,u/10 | 0,c,-s,y | 0,s,c,z]      c,s = cos,sin(1.4614 deg)
```

**Orientation is load-bearing (#922).** The tile is a TRAPEZOID — wide edge to
the pedal's cable end, which is +y in the populated frame, and which also
carries the top of the glyphs. Import at identity and the STEP's own +Y already
points that way; do not rotate it about z.

**The window it drops into lives in the OTHER doc.** `Top Pad` in "Cherub
WTB-006 Footswitch" carries sketch `PAD_WINDOW` + feature `PAD_WINDOW_CUT`, and
that sketch holds the pad's own side edges — so the pad's plan taper is measured
there, not inferred from the case. The window is a trapezoid keeping a 5 mm wall
at every station (54.459 back / 53.855 toe); the generator's `TILE_PAD_W_BACK` /
`TILE_PAD_W_TOE` are those pad widths, and the tiles follow. **Change one and you
must change both.** Three traps, all of which produce a confident wrong answer:

1. The sketch has **zero constraints and zero dimensions**, so points move freely
   and nothing warns you that the window no longer relates to the pad edges.
2. Editing it does **not** recompute the body — call `design.computeAll()` or you
   read the old geometry back and conclude the edit failed.
3. The populated doc **keeps serving the stale pad** after the pedal doc is
   saved. `canAdvanceToLatest` is False; the call that works is
   `app.activeDocument.updateAllReferences()`, and the doc must be saved first.
   Until you make it, tile-vs-window checks in the console verify green against a
   window that no longer exists in the source.

**Re-import recipe** (same shape as the board's, above): regenerate with the
generator, delete the ten `tile_*` occurrences, `importManager.createSTEPImportOptions`
+ `importToTarget(root)` per file, rename to `tile_<LABEL>`, re-apply the two
appearances, then set the transform and snapshot. Do it one tile per call — this
doc is heavy, and batching per-body operations is what froze it in #753.

## Row 2 (CLEAR/BANK) placement (#796)

Row 2 sits on the 16" aperture's front edge (generator `PEDAL_ROW2_V`, 233.65).
Every row-2 member is placed as **its row-1 counterpart's transform plus the
slope delta** `(0, c*dv, s*dv)` with `dv = (PEDAL_ROW2_V - PEDAL_ROW1_V)/10 =
16.584607` cm, i.e. world `(0, 16.191596, 3.589069)`:

| row-2 member | row-1 source |
|---|---|
| `pedals:1+Cherub WTB-006 Footswitch:9` / `:10` | `Footswitch:3` / `:4` |
| `platforms:1+platform_sled_v375:2` / `:10` | `platform_sled_v375:4` / `:5` |
| `tile_CLEAR:1` / `tile_BANK:1` | `tile_UNDO:1` / `tile_MODE:1` |
| `led_diffuser_CLEAR` / `_BANK` | see the diffuser origins below |

The mid pedestal collars are the exception: their HEIGHT follows the row's v,
so they are **re-imported, not moved**. `platform_mid_ring_CLEAR:1` and
`_BANK:1` under `platforms` are `out/segno_platform_mid_ring.step` placed at
`[0,-1,0,u/10 | 1,0,0,22.811 | 0,0,1,0.2]` — the row-2 foot-hole centre
(`platform_foot_holes`, v 228.11) over the floor top, with the same 90 deg turn
as the front collars (whose `y = 6.62` is the row-1 hole centre). Done
2026-09-04; the doc's row 2 had sat 3.96 mm too far back until then.

## LED pill diffusers (populated doc only)

Ten `led_diffuser_*` components under `lid_stack:1+diffusers:1` (current as of
2026-09-04: the 68 x 14 x 6.33 strip-channel part, one per pedal), each an
imported STEP of `out/segno_led_diffuser.step`. They replaced a `led_strips`
component that held six bars as BODIES and had gone stale by a whole revision;
that component is deleted, the strip now lives inside the diffuser channel.

**Placement.** x is the pedal's `u/10`; the rotation is `SLOPE_ANGLE`
(12.498241812070852 deg), not the pedal tilt the tiles use. Row 1 sits at
`ty = 13.619711, tz = 4.240818`; row 2 (CLEAR, BANK) at
`ty = 29.811307, tz = 7.829888` (LED_GAP = 16, the 2026-09-04 trial; at the
old LED_GAP = 12 they were 13.22919 / 4.154255 and 29.420786 / 7.743324).
These are the generator's numbers: the part
origin is on the plate's local z = -0.22 (underside minus a 0.2 mm glue line)
at the pill centre `v = PEDAL_ROW*_V + FSW_SLOT_D/2 + LED_GAP`, DXF
`y = v/10 + 1.21938` (the lip fold line), through the faceplate transform.

```
[1,0,0,u/10 | 0,c,-s,ty | 0,s,c,tz]
```

Those are ORIGIN values, not lens centres. To re-derive them from an existing
body, the lens is centred in x/y and spans z 0..0.24 cm, so
`ty = centre_y + sin(slope)*0.12` and `tz = centre_z - cos(slope)*0.12`.

**Appearance is state, not material.** TRACK1 and TRACK2 carry `LED pill - green`
(shown lit); the rest are `Plastic - Matte (White)`. Preserve that split across a
re-import or the render silently loses its meaning. **Set the appearance BEFORE
the transform**, in its own pass: a loop that set `transform2` and then
`body.appearance` left all ten at identity (2026-09-04) — the same reset the
faceplate recipe warns about.

**The first import into an empty component cannot be transformed.** Setting
`transform2` on it silently does nothing — no exception, the matrix just reads
back as identity, and retrying does not help. Every LATER import into the same
component accepts it normally. Work around it by importing the odd one out last,
or by importing a throwaway first. Related: transform overrides only apply to a
proxy obtained from the ROOT context, so use
`occ.createForAssemblyContext(<root-context parent>)` — setting it on the
occurrence straight out of `component.occurrences` throws
"transform overrides can only be set on Occurrence proxy from root component".

**A failed call can roll back further than that call.** The script error that
tripped the transform rule above restored a `led_strips` occurrence deleted by
the PREVIOUS, successful call — and moved it to a different parent — while
leaving that call's imports in place. Re-read the tree after any failure instead of assuming only
your own changes were undone.

## Vent blackout foam (populated doc only)

`vent_foam` component: four 3 mm black pads glued to the INSIDE of every
vented region so components aren't visible through the slots. World extents
(cm): left wall (0.01, 24.5, 0.7)–(0.31, 37.7, 7.7), right wall mirrored at
x 84.29–84.59 (both with a wedge-sloped top edge kept ≥3 mm under the wall
top), rear wall (2.5, 41.59, 1.7)–(39.9, 41.89, 7.7) — clear of the rear
panel, which starts at x ≈ 42.5 — and floor (25.6, 14.5, 0.2)–(57.6, 19.1,
0.5) between the pedal rows. Interference-checked against every other body
(0 collisions). Physical part: black speaker grille cloth or
open-cell air-filter foam, cut ~5 mm oversize per field and glued at the
PERIMETER only — the vents are the Pi 5's convection path, so no closed-cell
foam and no full-coverage adhesive backing (self-adhesive felt's continuous
glue film is near-airtight even though the felt itself breathes). Not in the
DXFs: it's a soft good cut with scissors, not a fab feature.

## What is deliberately NOT in Fusion

The DXFs/STEPs under `out/` are manufacturing truth; Fusion is the assembly
model. The model deviates from the fab flat only by: the four Ø6.5 corner
reliefs, the 0.5 mm lip-end + 0.06-level clearances above, all invisible and
standard press-brake practice. If a change matters for fabrication it goes in
`segno_enclosure.py`, never only in Fusion.
