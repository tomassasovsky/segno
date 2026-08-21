# Manufactured fabrication records

**What this folder is.** The exact files sent to a board house, archived unchanged.
When a physical board exists, this is the only ground truth for what it is —
the generators can be re-run, but a re-run is a *claim* about the board, not a
record of it. Keep the zip byte-for-byte as sent; never regenerate in place.

## segno_console_board_gerbers_v2art.zip

| | |
|---|---|
| Sent to fab | 2026-08-18 (console board v2) |
| Exported | 2026-08-18 17:24, KiCad 10.0.4 |
| MD5 | `6cdc396eb4935da1697c3c0e71a23171` |
| Contents | F/B copper, F/B mask, F/B paste, F/B silkscreen, Edge_Cuts, PTH + NPTH drill, job file |

**How it relates to the repo** (verified 2026-08-21, headers/timestamps stripped
before comparing):

| Layer | vs `out_console/` in the repo |
|---|---|
| F_Cu, B_Cu | geometrically **identical** |
| PTH.drl, NPTH.drl | **identical** |
| Edge_Cuts | **identical** |
| F_Paste, B_Paste | **identical** |
| F_Mask, B_Mask | **identical** (see note below) |
| F_Silkscreen, B_Silkscreen | **identical** since #784 regenerated the art into the repo |

> **Correction (2026-08-21).** The row above originally read that the mask
> differed and blamed a KiCad export option. That was wrong. Re-exporting the
> repo's own unmodified board reproduces the manufactured G36/G37 region form
> byte-for-byte — master's *committed* mask gerbers were simply **stale**, left
> in the older aperture-flash form. The opening count and positions never
> differed (239 front, 196 back). #784 re-exported them, so every one of the
> eleven fab layers now matches this archive exactly.

So the manufactured boards are **electrically and mechanically the repo's
design**. The only real difference is decorative silkscreen, which at the time
of the order lived on an unmerged branch (#758) that never produced gerbers.
That is why this archive exists: without it nothing in the repo could tell you
what is physically on the boards.

**Reordering.** Either send this zip, or regenerate — since #784 the two are
byte-identical across all eleven fab layers, verified twice (exporting the
committed board, and re-applying `_silk_art()` to master's routed board). The
composer's least-obstruction search is not a source of drift: its result is
frozen in `silk_art.py` and re-emitting it is deterministic. Still diff against
this file before sending anything; this archive remains the record of what the
existing boards physically are.
