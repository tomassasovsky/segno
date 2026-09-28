# Console screen-control label

Issue: #1072. The owner requested removal of `SCREEN 1=GPIO17 2=GND` from the
bottom and a proper connector label on top.

The board now carries `SCREEN` above and left of J25. J25, R16 and R20 reference
text moves to keep the new label readable. Component positions, pad nets,
tracks and vias are preserved, including the PI PWR placement beside the ribbon
and the aligned PD/RING/SCREEN/PI PWR connector row.

The source generator and saved PCB both pass placement and silkscreen checks.
Native KiCad DRC reports zero violations and zero unconnected items. The
fresh package includes the native board, portable models, Gerbers, drill files,
STEP, assembly drawing, BOM and both-side previews.

[Validation](validation.json) records before/after hashes and preserved copper.
[DRC](drc.json) records the native check. GPIO17 and GND pin assignments remain
in the [wiring guide](../../../hardware/kicad/README.md).
