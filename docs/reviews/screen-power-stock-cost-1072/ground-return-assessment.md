# Screen power copper-return assessment

28 September 2026. **Final native copper assessment.** This supports the 20 mV working copper allowance for the selected OGN/SPT input and Bel output design. It is not manufacturing release or a measured voltage/temperature guarantee. Later silkscreen text edits alone do not change this model; any change to copper, filled zones, pads, vias, or load assumptions requires a fresh run.

Analyzed board: `hardware/kicad/screen_power/hand/screen_power_hand.kicad_pcb`, SHA-256 `e72850b26ae9076011bc368b69d3f1f1edce758be878bf5fb0decc4f415c5a2f`. Model SHA-256: `cf609b252a0139638f99be15fe1b1e82e3e51e2a9051c8c49a869c60ee509528`. The report must not be presented as a check of another board hash without establishing that the only changes are non-electrical, or rerunning it.

## Result

The modeled shared feed, coil supply, coil return and ground-return losses remain below the **20 mV** allowance used in [the holder/coil budget](holder-coil-budget.md).

| Copper / barrel plating | Mesh | Total copper drop | Ground-return portion |
|---|---:|---:|---:|
| 35 µm / 20 µm, 60 °C | 0.15 mm | 13.158 mV | 3.382 mV |
| 35 µm / 20 µm, 60 °C | 0.10 mm | 12.760 mV | 2.984 mV |
| 30 µm / 15 µm sensitivity, 60 °C | 0.15 mm | 15.366 mV | 3.961 mV |

The thinner-material sensitivity retains approximately 4.63 mV of the allowance. Retain the full 20 mV budget rather than treating the calculated drop as a guaranteed maximum. The 0.15-to-0.10 mm refinement changes total nominal loss by 0.398 mV. Every terminal is represented at both resolutions; maximum nodal current residual is below 1 nA.

The input remains **4.75 V at J1, before F1**. This report covers PCB copper only. Fuse, holder, driver, connector, cable and relay-contact allowances remain separate. In particular, it does not claim USB minimum-voltage compliance at the worst supply corner.

## Geometry and current allocation

The raw input has 11.336 mm of 4 mm track. At 4.46 A and the nominal material assumptions, it contributes 7.204 mV. The coil supply branches at F1.2; the downstream 5 mm screen contact feed is therefore excluded from the coil's shared path. To avoid optimistic branch-current division, the complete 26.284 mm sum of all 1 mm AUX branch tracks is charged at 150 mA, including capacitor and clamp stubs. This contributes 2.247 mV. The coil-low return is also included at 50 mA, contributing 0.324 mV.

The GND calculation uses the actual filled copper, GND tracks, pad annuli, and plated vias on both layers. It does not assume an uninterrupted rectangular plane. A grid cell is admitted only when its entire square is covered by copper; the union of drilled voids is subtracted after all copper unions. Thus a thin clearance slit cannot disappear merely because the cell center lies in copper.

The resistor network applies sheet conductance between adjacent admitted cells. Through-hole and via barrels use their actual drill diameter, 1.6 mm board thickness, and the stated plating thickness. Terminal annuli are approximated as equipotential boundaries with finite numerical ties. A one-ampere reciprocal solve at Q5's ground returns the transfer resistance from each load return to the driver. The allocation maximizes that drop under **4.25 A total screen load**, **3 A per main output**, and **0.5 A per touch output**. It does not assume equally loaded screens. The worst allocation on this snapshot is 3 A at J203, 0.25 A at J103, and 0.5 A at each touch header.

The calculation adds the full **150 mA coil/control allowance** at the most adverse observed control return and **60 mA at R8.2** for the approximately 53 mA maximum bleeder. The resulting input allowance is **4.46 A**. The contact allocation is 4.31 A including the rounded bleeder. Published foil and plating thicknesses are not inferred from a product name: 35/20 µm are model assumptions, with the explicit 30/15 µm sensitivity above.

## Limits and independent controls

This is a DC geometric estimate using resistivity 1.724 × 10⁻⁸ Ω·m at 20 °C and temperature coefficient 0.00393/K. It does not model startup capacitor pulses, relay bounce, changing fuse/holder resistance, external ground loops, temperature rise, or exact current spreading inside soldered terminals. The mesh deliberately discards partial edge cells; refinement and material sensitivities show the size of this numerical approximation, not a laboratory certification.

An independent reviewer exercised the solver with a separate synthetic two-layer fixture. The connected case solved with less than 2.5 pA current residual, doubling both copper and plating halved the calculated loss within 0.005%, and a complete **10 µm slit was rejected with a 0.25 mm mesh**. That last control directly tests that the model cannot bridge a subcell clearance. [Independent results](ground-return-independent-controls.json).

Source and results: [model](ground-return-model.py), [nominal meshes](ground-return-nominal.json), [thinner-material sensitivity](ground-return-stress.json).

## Reproduction

The analysis was run with NumPy 2.3.5, SciPy 1.18.1 and Shapely 2.1.2. Use an isolated Python environment with those dependencies. Set `KICAD_PYTHON` if the KiCad Python executable differs from the standard macOS application path; only that subprocess imports `pcbnew`. The script reads the board without saving or refilling it. First use the normal board workflow to produce current filled copper.

From the repository root, these are the complete rerun commands. They intentionally bind fresh output to the board hash present when run:

```sh
python docs/reviews/screen-power-stock-cost-1072/ground-return-model.py --board hardware/kicad/screen_power/hand/screen_power_hand.kicad_pcb --mesh 0.15 0.10 --output docs/reviews/screen-power-stock-cost-1072/ground-return-nominal.json
python docs/reviews/screen-power-stock-cost-1072/ground-return-model.py --board hardware/kicad/screen_power/hand/screen_power_hand.kicad_pcb --mesh 0.15 --copper-um 30 --plating-um 15 --output docs/reviews/screen-power-stock-cost-1072/ground-return-stress.json
```
