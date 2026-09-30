# Board generators

SKiDL scripts that emit KiCad netlists. One per board:

| script | board |
|---|---|
| `main_board.py` | standalone pedal — Pro Micro (ATmega32U4) |
| `ring_board.py` | encoder + LED ring + XIAO RP2350, behind the faceplate (4-way link, #987) |
| `console_board.py` | console v3 — Pico 2 on the Pi's GPIO (#747); v3 adds the 4-way ring link (#987) and the CTRL ring sense |

## Running them

```bash
python3.12 -m venv .venv && ./.venv/bin/pip install -r requirements.txt
cd hardware/kicad && ./.venv/bin/python console_board.py
```

**Run from `hardware/kicad/`.** `generate_netlist()` writes `<script>.net` into the
current working directory, so running from the repo root silently drops the netlist
in the wrong place while reporting success.

## Two things that will mislead you

**A netlist diff is not a design change.** SKiDL assigns a *random* `SKiDL Tag` to
every `Part` without an explicit `tag=`, and component `tstamps` derive from it. Two
runs of the **same** version on unchanged source differ by ~190 lines — all tags,
timestamps and the tool version string, with **zero** net changes. Pinning skidl does
not fix this. Judge a run by `0 errors found while running ERC` and the `(net ...)`
blocks, not by `git diff`.

**Prefer upstream footprints.** `segno.pretty/` exists for parts KiCad does not ship
(the NeoPixel Ring 24, the EC11 on its ring board, the module mount-pad and wire-pad
helpers). It is not a place to re-draw something that already exists. The Pico 2, for instance, is KiCad's own
`Module:RaspberryPi_Pico_Common_THT` — its description explicitly says it supports
Pico 2, and it is maintained upstream.
