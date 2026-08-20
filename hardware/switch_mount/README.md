# Cherub WTB-006 silent switch platform

The printed platform that carries a silent switch inside a Cherub WTB-006
footswitch shell, replacing the pedal's own clicky switch (#729).

| | |
|---|---|
| Source of truth | Fusion document **"Cherub WTB-006 silent switch platform"** (Default Project) |
| Exports here | `switch_platform.step` (CAD interchange), `switch_platform.stl` (print) |
| Envelope | 66.85 x 57.38 x 10.60 mm, 8.06 cm3 |
| Print | PLA is fine — the part takes compression from the stem, not impact |

## Provenance

Authored **by hand in Fusion**, not generated. An earlier CadQuery attempt
(`generate_stl.py`, box-and-pins parametric) was abandoned: its default
`PIN_CLEARANCE` produced a 12.1 mm box whose stem overshot the pedal interior
by ~3 mm, so the lid could not close, and the fix was never settled. The Fusion
part solves the same problem at 10.60 mm. Do not resurrect the generator —
edit the Fusion document and re-export.

## Re-exporting after a Fusion edit

Open the document, then export the root component to both formats, replacing
the files here (STL: binary, high refinement). Keep the two exports in the same
commit so the STEP and the STL never describe different revisions.

## Still open on #729

The physical fit check. #729 is `blocked-verify`: it closes when a printed
platform is confirmed in the pedal shell with the lid closing and the switch
actuating at the intended pre-travel.
