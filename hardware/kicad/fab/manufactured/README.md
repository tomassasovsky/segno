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
| F_Mask, B_Mask | same openings — 239 front, 196 back, none extra or missing. The repo writes aperture flashes (D03); this set writes G36/G37 polygon regions. Centroids agree to a median of 0.024 mm. A KiCad export-option difference, not a design difference. |
| F_Silkscreen, B_Silkscreen | **differs** — this set carries the silkscreen artwork |

So the manufactured boards are **electrically and mechanically the repo's
design**. The only real difference is decorative silkscreen, which at the time
of the order lived on an unmerged branch (#758) that never produced gerbers.
That is why this archive exists: without it nothing in the repo could tell you
what is physically on the boards.

**Reordering.** Send this zip. Do not regenerate and send fresh output unless
you have first diffed it against this file — the silkscreen composer places its
artwork by a search, so a regeneration is not guaranteed to reproduce the same
art.
