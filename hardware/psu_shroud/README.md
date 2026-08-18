# PSU terminal-end shroud

Printed end cap for the console's external 5 V supply. Issues #754 (one 5 V
supply for the whole console) and #755 (this part).

## Why a cap and not a box

The supply is an open-frame **metal-cased** 100 W unit (S-100 / LRS-100 class,
5 V 20 A). Its steel case is already an enclosure and already vented — a plastic
box around it would duplicate that and trap the ~15 W it dissipates at full
load. The one genuinely exposed hazard is the screw terminal block, and on this
class of supply that block sits on **one end face** (AC L/N/E, then V−/V+).

So this part shrouds that face, carries the fused IEC C14 inlet and the GX20-4
output, and leaves every vent clear.

## Safety — read before wiring

- **Bond the supply's metal chassis to the IEC earth pin.** A printed box earths
  nothing. Green/yellow from the inlet's earth tab to the supply's earth screw is
  the first wire in and the last out.
- Mains and DC do not share a channel. The internal divider rib enforces that and
  `MAINS_DC_GAP` gates it.
- **PETG is not flame-retardant.** It is acceptable here *only* because this is a
  secondary shroud over a steel case. Do not reuse this part as the primary
  enclosure for anything mains-powered.
- The console's rear-panel fuse station cannot be sensibly rated for 12 A at 5 V
  (5×20 holders stop at 6.3–10 A). The fuse belongs **here**, on the mains side,
  where the same protection is ~0.5 A and entirely ordinary — which is what the
  fused IEC inlet gives you.

## Before you print

Every fit dimension is tagged `# MEASURE` and is set against a supply that has
not been bought yet. Clone case sizes and screw positions vary. Measure the real
unit, set `CASE_W` / `CASE_H` / `SCREW_*` / `TERM_*`, re-run, then print.

## Print

- PETG, 0.4 nozzle, 3 mm walls.
- Orientation is baked into the export: the connector face lies on the bed and
  the cavity opens upward. `_print_check` reports 100 % first-layer contact, no
  islands, and **no support required**.
- ~17 g.

```
../enclosure/.venv/bin/python psu_shroud.py
../enclosure/.venv/bin/python ../enclosure/_print_check.py out/segno_psu_shroud.stl
```

## Gates

Five, each with a negative control that fires: wire-bend room, mains-to-DC
separation, both cutouts fitting the end face, the side screws landing inside the
case overlap, and the wall over live terminals staying a barrier.
