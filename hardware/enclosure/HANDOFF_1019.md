# Handoff: issue #1019, the console enclosure under a stomp

Written 2026-09-14 for the next agent picking up the Segno/VAMP console
enclosure. It records one working session (2026-09-09 to 2026-09-10) and where
its results live. It is a point-in-time note: where it disagrees with the
generator, the tests or the documents it points to, those win.

## State in one paragraph

The question was whether the 850 × 423 × 100 mm folded aluminium floor console
survives being stomped on. As drawn at the start, it did not: the bottom plate
yielded at a few hundred newtons and the faceplate dented at 7–11 kg between
supports. That is now fixed in the generator, the tests, the shop documents and
both Fusion documents. The floor sits on three printed PETG rails with a solid
neoprene strip; the seven steel lid posts became one full-width folded steel
beam; the bottom plate lost its vent field; the corner brackets got wider legs;
every printed part is black PETG. 98 enclosure tests pass. **No pull request is
open, nothing is merged, and the package has not been sent to the shop.**

## Where everything lives

| What | Where |
|---|---|
| Git branch | `claude/sheet-metal-enclosure-analysis-6c2aa4`, on origin (`tomassasovsky/segno`). **Not master.** Master's `segno_enclosure.py` is an older revision; diff before touching anything. |
| Tracking issue | #1019, labels `stage:build`, `autonomy:plan-gate`, `priority:P1`, `area:enclosure`, no comments |
| Generator (the design source) | `hardware/enclosure/segno_enclosure.py` |
| Tests | `hardware/enclosure/tests/`: `test_lid_prop.py` (beam + printed prop), `test_floor_rails.py`, `test_floor_supports.py`, `test_manufacturing_fit.py` (assembly, rivets, bracket seats), `test_manufacturing_pipeline.py` (packages, native flats) |
| Generated shop files | `hardware/enclosure/out/` (tracked); quote zips are generated there but untracked |
| Native Fusion exports | `hardware/enclosure/formed/` + `manifest.json`. Commit as a set: the manifest checksums every file. |
| Design rationale | `hardware/segno_enclosure_design.md` (lid support, floor rails, material) |
| Shop / parts / fasteners | `hardware/MANUFACTURING.md` |
| Fusion editing contract | `hardware/enclosure/FUSION_MODELS.md` (placements, feature names, traps) |
| Load analysis write-up | `docs/research/2026-09-09-enclosure-stomp-load-analysis.md` |
| Nonlinear FE model | `hardware/enclosure/_stomp_fea_nl.py`, `_stomp_fea_cases.py`, `_stomp_fea_beam.py`, `_stomp_fea_slip.py` (moved out of a temp scratch dir on 2026-09-14) |
| Old linear FE model | `hardware/enclosure/_stomp_fea.py`. **Its absolute numbers are superseded**; see the research doc. |
| Fusion documents | Default Project → folder `Loopy`: **`VAMP sheet metal`** (VSM, the sheet-metal source) and **`VAMP console (populated)`** (full assembly; it EMBEDS its own copy of the sheet metal, edits do not propagate) |
| Python environment | The MAIN checkout's `hardware/enclosure/.venv` (Python 3.14, cadquery, ezdxf, openseespy). Worktrees have no venv. |
| Published page | Artifact "Segno Console Load Rating" (`claude.ai/code/artifact/1a81ee5c-…`). **Stale**: linear-model era (353 MPa, 40 feet, seven posts). Do not quote it. |

## What changed, in order

Commits on the branch past master. The first seven (2026-09-04 drawing-guard
fixes, `dc2e2929`..`1d14d701`) predate this session; `c95be92b` is the snapshot it
started from.

| Commit | Change |
|---|---|
| `c95be92b` | Snapshot of in-flight sheet-metal work (short-screw CLEAR/BANK pedestal, mid sled, baffles) |
| `ad3c2d53` | Rated-load analysis: the base plate cannot take a stomp |
| `28f33bd7` | First fix: carry the stomp to the floor, prop the lid band (later superseded) |
| `9c850f31` | `segno_lid_prop`, a printed column in the one clear lane beside BANK |
| `5534b7e4`, `009abd73` | Fusion sync and regenerated package |
| `b91bad93` | Printed floor rails replace the rubber feet (first five-rail version) |
| `ddb7706a` | Rear rail anchor screws had landed inside the buck converter bodies |
| `d804712d` | Real rail segments in Fusion, not envelope bars |
| `ae342b17` | **Three rail rows**, square ends, butted segments, **no bottom vents** |
| `fe56a624` | **One full-width support beam replaces the seven posts** |
| `8f44962d` | Gates and tests for the corner rivets (registration, hand symmetry, staggering) |
| `80740d10` | **Corner bracket leg 12 → 15 mm** so rivets clear 2× diameter to the free edge |
| `ad2e1b46` | Why the beam's steel grade is left open (section check) |
| `bcc21e97` | **Black PETG for every printed part**; rails and prop added to the print package |
| this commit | FE model moved into the repo; bracket transforms in `FUSION_MODELS.md` corrected; this file |

### The design as it stands

**Floor rails.** Three rows at v = 18.0, 114.883 and 343.25 mm, full width,
12 printed segments of two part types (8 × `segno_floor_rail_front`,
4 × `segno_floor_rail_rear`), 201.79 mm each, 21 mm wide, 6 mm PETG body with a
19.05 × 3.2 mm self-adhesive **solid** neoprene strip in a channel; ride height
7.7 mm. Front rows ride the pedestals' existing chassis screws; the rear row adds
8 floor bores. Result: 96 MPa, 3.28 mm at a 1 kN stomp.

**Bottom plate.** No vents. Free area is side and rear walls only, 11,529 mm²
against a 4,000 floor.

**Support beam** (`segno_beam`, replaces `segno_post` ×7). One folded C section,
1.6 mm cold-rolled steel, powder coated separately and bolted in after coating.

| | |
|---|---|
| overall | 844.8 mm between ear outer faces, 0.511 mm clear of each side wall |
| section | foot 20, web `BEAM_H` 42.799, pad `BEAM_PAD` **14.3**, tilted 12.5° to bed on the faceplate |
| blank | 877.9 × 75.5 mm, four folds, **ears first** |
| floor fixings | 14 × M4 at the old post stations, v = 148.997, **slotted 2.0 mm in depth** |
| wall ties | one M4 per end through the side wall into a rearward ear, slotted 1.5 mm vertically; hole at 21.0 mm above the floor top, depth 169.597 |
| cable windows | 10 × 24 × 12 mm r3 in the web: 8 on the front-pedal centrelines, 2 LED feeds at u 30 and 816 |
| LED shoulder clearance | 1.47 mm real air (`BEAM_LEAN` correction; measured 1.477 in Fusion) |
| mass | 779 g |

Floor stress at 1 kN: 96 MPa with no beam, **135 slotted**, 147 plain, all under
the RC-600 calibration point of util 2.00. A torqued M4 carries ~500 N of
friction against 1.0–1.4 kN of in-plane demand at the loaded bolts, so they slip
and 135 applies. The beam's own worst case (1 kN on the tip of the 108.9 mm
overhang) is 78 MPa, so any cold-rolled mild steel works and no grade is called
out. Faceplate: weakest point on the band went from 47 kg to 475 kg.

**Corner brackets.** Leg 15 mm, `CORNER_RO` 8: rivets 7.0 mm from the free edge
(2.19 D) and 8.0 from the bend. Base holes did not move. All ten rivets are
coaxial to 0.011 mm in Fusion.

**Printed parts.** All black PETG, ≥40 % infill. Exceptions, all optical: the ten
pedal-LED diffusers and the ring diffuser (white, translucent) and the ten pedal
tiles (black body, white lettering). `segno_3dprint.zip` now has 64 members and a
gate refuses to build it while any emitted printed STL is missing.

## Owner decisions — do not re-propose

- Rails, not rubber feet ("more feet here than surface"). Solid smooth neoprene,
  not grip tape (mineral grit scores floors).
- **Three rows only.** Four is "still too many". Square ends, segments butted,
  identical segments within a row.
- **No pads** under the floor; rows only. **No bottom vents** ("there's already
  vents at the sides and back").
- A **single beam** replacing the posts, **attached to the side walls**, with a
  cable opening at each front-row pedal and openings at the sides for the LED
  strip feed.
- Corner bracket widening: the owner asked for a recommendation; 15 mm was
  recommended and implemented.
- **Every printed part is black PETG.** ASA is no longer an alternative.
- The two green LED pills in the populated model (TRACK1, TRACK2) are a lit-state
  illustration matching the on-screen armed tracks. Leave them.

## Verified at handoff, and what was not

Verified on 2026-09-14 in a fresh worktree at `bcc21e97`:

- 98 enclosure tests pass.
- The moved FE model reproduces the published floor table from its new location:
  `_stomp_fea_beam.py` prints no beam 96 MPa / 3.28 mm, slotted 135 / 2.95,
  plain 147 / 2.83, the same as on 2026-09-10.

**Not re-verified:** the Fusion documents. The Fusion MCP server was disconnected
at handoff, so their state is as last saved on 2026-09-10: base 945.1549 cm³ in
both, beam 99,284.0 mm³, each bracket 4,936.5621 mm³, no `faceplate_support_post`
occurrences in either document, and the four native flats matching the generator
within 0.0006 mm². Re-check before relying on them.

## Open items

1. **No PR.** Per `docs/TRACKING.md` the next step is a PR with `Closes #1019`,
   `stage:in-review`, `autonomy:plan-gate`, `ci:*`, `review:pending`. Plan-gate:
   a human merges.
2. **Owner taste call, unanswered:** the beam's wall ties put one M4 head on the
   outside of each side wall, low and near the front. The owner dislikes visible
   screws (earlier on the top face). Offer to remove them: the beam does not need
   them structurally.
3. **Shop release.** An earlier note put the package on structural hold ("do not
   send to Dinacut"). The fix is in, but clearing the hold is the owner's call.
4. Corner rivets: the ~4 mm grip and setting-tool access still need the shop.
5. Offered, not decided: blind threaded inserts instead of hand-tapping the 32 M3
   pilots after painting (the front wall is only 12 mm tall; needs its own check).
6. Documented residual: the faceplate ligament left of CLEAR still dents at
   11 kg; closing it means moving the 7 in tower or the CLEAR pedestal.
7. The RC-600 benchmark panel model was never saved as a script; only its result
   is in the research doc.
8. The stale artifact above could be republished or retired.

## Traps that bit during this work

- **A Fusion script that raises rolls back its whole call**, including earlier
  successful edits. A post deletion followed by a diagnostic that threw left all
  seven posts in VSM while the script had already printed "0 remaining". Keep
  mutations and diagnostics in separate calls and re-query after.
- `component.features.extrudeFeatures.add()` parents the feature to the **active**
  component. Activate the target occurrence and check `parentComponent`.
- `setSymmetricExtent(d, True)` makes `d` the **total** length; a 45 cm "each way"
  cut reached neither wall.
- Moving sketch points updates the profile, but the body does not rebuild until
  `design.computeAll()` (≈9 s populated, ≈3 s VSM).
- `importToTarget2` lands at identity; set `transform2` absolutely, then
  `snapshots.add()`. VSM's world is x = 848 − u, y = height, z = depth.
- Folded side walls' inner faces sit `BA90/2 − RI` = 0.0892 mm inboard of the
  flat's edge; the clear span is 845.8216, not 846.
- Holes cut after the folds (the wall ties) do not come from the flat `CUT`
  sketch but still reach the exported flat, which unfolds the body.
- **Plan-view clearance lies on tilted parts** (`BEAM_LEAN`): 1.39 in plan, 0.78
  in the assembly before the pad was shortened.
- **Cutters built facing the wrong way leave a valid, correctly sized solid.** The
  first beam had no cable windows and one ear slot missing. Count cylindrical
  faces by radius; `test_every_window_and_every_fixing_is_actually_cut` does.
- `hardware/enclosure/.gitignore` ignores `_*.py`. The scripts that are kept
  (`_stomp_fea*.py`, `_print_check.py`) were added with `git add -f`; a plain
  `git add -A` silently leaves a new one out.
- Regenerating rewrites all of `out/` with timestamp and GUID noise. Compare DXF
  geometry against HEAD and revert what did not really change.
- From a worktree, `unittest discover -s tests` fails ("not importable"); pass
  the module list explicitly (below).
- Local cspell flags long-standing words (Alcast, gyroid, deburring); diff its
  output before and after rather than reading it raw.

## How to run

From `hardware/enclosure/` in a checkout of the branch, with
`PY=/Users/Tomas/Documents/Work/opensource/loopy/hardware/enclosure/.venv/bin/python`:

```bash
$PY segno_enclosure.py --report
```

```bash
$PY segno_enclosure.py
```

```bash
$PY -m unittest $(cd tests && ls test_*.py | sed 's/\.py$//;s/^/tests./')
```

```bash
$PY _stomp_fea_beam.py
```

The full generator stops with "native formed export is stale" whenever a formed
part's flat changes. The order is then: `segno_enclosure.py --no-step`, edit both
Fusion documents, run `fusion_export_formed.py` inside Fusion with the populated
document active, then the full generator.
