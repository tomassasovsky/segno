# Shared geometry helper review — PR #1080

Reviewed 2026-09-26. Base: `5fd9f8bf6856673d07b27054d0b98dd7ba719561`.
Head: `00060494b9af330cb2fbe7834fe9bae04bac65c0`.

**Result: no actionable findings in this bounded review angle.** This is not a
complete PR review or manufacturing release approval. The final screen-board
placement/routing delta, rebuilt native output and release package remain a
separate review gate.

## Scope and method

Read the changed helper implementations and their callers across
`round_routes.py`, `widen_power.py`, `silkscreen.py`, `test_round_routes.py`, the
screen `cleanup.py`, `finish.py`, `router.py` and `build.sh`, and the console/ring
routing scripts. Inspected the generated `silk_art.py` difference structurally:
it moves one four-vertex back legend rectangle by 0.20 mm without changing its
dimensions, polygon count or holes. It is not copper geometry.

Reviewed endpoint and same-net contact preservation, width/layer/net identity,
clearance/keepout treatment, locked traces, USB bypasses, widening constraints,
silkscreen clipping, redundant-tail removal and final DRC failure paths. No
implementation or native-board files were changed by this review.

## Checks observed

- `test_round_routes.py --out <temporary-directory>` passed all **13 fixtures**
  using KiCad **10.0.4**. The suite executes the real CLI helper twice per fixture
  and checks native copper connectivity and clearances. It covers pad-edge
  contacts, board and footprint track keepouts, internal pads/vias,
  different-width and locked branches, a branch joining a segment interior,
  rotated/custom foreign pads, two newly rounded nets and all eight USB nets.
  Every fixture had no reported errors, preserved connectivity, and produced
  identical bytes and geometry on the second pass. The simple curve and both
  nets in the two-chain fixture actually changed; this was not a no-op run.
- `python3 hardware/kicad/widen_power.py --selftest` exited successfully with
  **zero failed checks**. These checks include preserving an existing 1.5 mm
  power branch, same/other-layer constraints, rectangular/rotated/rounded/oval/
  circular pads, board-edge clearance and the documented width arithmetic.
- A separate in-memory KiCad silkscreen fixture began with a 0.12 mm stroke
  crossing a pad mask opening. The independent mask checker rejected it. The
  finishing helper produced two 0.15 mm fragments that passed mask clearance,
  preserved the pad position/size/drill and stayed geometrically identical on
  a second pass. Adding another footprint's pad across a retained fragment
  was independently rejected by the board-wide mask checker.
- Six independent `covered_by_track` cases passed: a narrower contained
  diagonal tail was accepted; reverse containment, a diverging branch,
  another copper layer, a wider candidate and a candidate extending beyond
  the longer track were rejected.

The temporary fixture script and result files were kept outside the repository.
The earlier console/ring native and CAM audit is recorded in the sibling
`console-ring-review.md`; it was not repeated for this helper angle.

## Preservation assumptions verified in callers

- Rounding uses native effective copper shapes, keeps anchored junctions and
  verifies old same-net contacts. It excludes locked routes and the eight
  explicitly named screen USB nets. Newly generated copper is added to the
  obstacle index before subsequent chains are considered.
- The width helper only increases narrower segments, so it does not reduce
  the existing hand-routed high-current branches. Its approximate text-based
  geometry analysis is followed by native DRC and board-specific power-path
  checks in the supported build paths.
- Silkscreen normalization edits footprint legend graphics rather than pads,
  copper or placement. Straight-line clipping only considers the footprint's
  own mask openings; the separate board-wide mask checker catches neighboring
  footprint, text and non-line legend collisions before release.
- Screen route import restores the original precise USB geometry after the
  router session. Subsequent endpoint snapping and rounding explicitly skip
  those data nets. Cleanup is limited to DRC-reported dangling tracks and
  refuses remaining violations or unconnected items after a zone refill.
- Cleanup containment models straight track capsules. The routed paths in
  these generators use straight segments, including chord-based rounded
  routes; this review does not certify arbitrary future native-arc inputs.

## Exact reviewed helper identities

| File under `hardware/kicad/` | SHA-256 |
| --- | --- |
| `round_routes.py` | `0de2ded7f6c115f5465c98f6408e9514169ed63ffa6335a147ceea692bfd0a05` |
| `test_round_routes.py` | `b0a1b93c21248f40ff5f2125b799a83e9da2e1026d68f88fae2116d846b63746` |
| `widen_power.py` | `123a9a1099380560383a2e998982be635e508b6bd4642ab68096e675e35ba612` |
| `silkscreen.py` | `312eb503bb86f75695ec26589957e48499781108cf5498d7d03c146fee7e2719` |
| `screen_power/cleanup.py` | `250a4ca530796cded61d5d1b660b5d01d1ceff215e0ff44b1265c5a3e19ad93b` |
| `screen_power/finish.py` | `22a083c3e1447f7ff5eed84573363e83b716f84c0898ec5ba980a0eb3ce9c63c` |
| `screen_power/router.py` | `37f7cfeac163f80c62a940455b88ea82d4aaec6cb28ea7eea566330795d4cdf7` |

No failed or missing reviewer is being represented as passing here. This report
does not cover the concurrently changing screen `layout.py`, `route_critical.py`
or placed board, nor replace final native DRC, power-path/USB guards, CAM checks,
or practical USB/device validation.
