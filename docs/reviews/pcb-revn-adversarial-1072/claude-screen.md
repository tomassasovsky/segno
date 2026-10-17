<!-- cspell:words Omron Schurter IRLZ NPBF AgSnIn pcbnew midpoints -->
# Claude — current screen Revision N adversarial review

**Completed 28 September 2026: no unresolved actionable board defect found.**
This is a fresh review of the relay-based Revision N circuit and native board,
followed by a targeted primary-source and evidence-correction pass. It is not
an extension of the old Revision M approval by assumption.

## Execution and identities

The existing screen review session resumed serially with Claude Opus 5,
safe mode, a strict empty MCP configuration and Read/Glob/Grep/Bash tools.
Both runs finished with actual findings-and-coverage verdicts: the full pass
returned success after 27 turns; the closeout returned success after 12 turns.
Both process exits were zero and both result records had `is_error: false`.
No service failure or retry occurred. The reviewer changed no production file;
its fresh DRC and baseline extraction used private scratch storage.

| Reviewed artifact | Identity |
|---|---|
| Hardware HEAD | `44edd9483518768506533a3b6fe30e85d6d530c4` |
| Screen native PCB | `e72850b26ae9076011bc368b69d3f1f1edce758be878bf5fb0decc4f415c5a2f` |
| Revision N Gerber ZIP | `abf39dbf1b7569a1ad25640c081f3e4fb126c94cd8d36d63fb1e559c7c2f8808` |

The closeout also reviewed the uncommitted corrections to
`hardware/MANUFACTURING.md` and `hardware/segno_wiring.md`: Revision N order
selection, onboard removable F1, removal of the obsolete negative gate supply,
and the 4.46 A input / 4.31 A contact / 7.818 A AUX budget. Source, netlist,
footprints, native board and current Gerber package were unchanged. The
initial report's claim of a clean worktree was corrected by that closeout.

## Actual coverage

| Domain | Independent inspection and result |
|---|---|
| Circuit, pinout and polarity | Read actual switch circuit and native pad nets for the power relay, driver, TVS, all five fuses, power connectors, default-off buffer, bleeder and bulk capacitor. Compared the G6C bottom-view dimension drawing and terminal numbering directly to the custom footprint. |
| Default-off and back-power | Traced GPIO17 → Q1 → Q2 → DATA_ENABLE → Q5 → K1 and the R7 gate discharge. Confirmed open-contact isolation and the documented reverse-feed path while K1 is closed. Powered software halt still requires GPIO17 low or released. |
| New component primary data | Read manufacturer files for G6C, IRLZ44N, P6KE6.8CA, Bel 0697H, Schurter OGN and SPT; checked ratings, pinout, body/lead dimensions and the actual corresponding footprints. |
| Power, fuse and thermal reasoning | Reproduced the stated 100 mV input-fuse allowance, 45.5 mV hot pickup and 2.4 mV loaded pickup-comparison figures. Assessed contact loss, clamp stress, supply/harness losses, fuse protection limits and the disclosed capacitive-inrush uncertainty. |
| Copper and placement | Read actual native track widths and power-net topology, confirming small signal/bypass branches are not in the high-current path. Checked courtyards and washer clearance; withdrew a false overlap from a rectangular bounding-box approximation after calculating radial clearance. |
| USB | Independently compared the prior native board against current copper, including net, type, endpoints, arc midpoint, width and layer, plus 18 fixed anchors and their pad geometry. All 292 items and anchors match. Both boards contain no USB PCB_ARC objects; curves are represented by chords. |
| Native design rules | Ran fresh all-severity KiCad DRC: zero violations, zero unconnected items, zero reported schematic-parity items. This is not a substitute for the separate netlist/source parity guard. |
| BOM, models and CAM | Inspected BOM/native values and model resolution; independently verified the ZIP hash, all 12 member hashes and the two-layer fabrication stackup. |
| Assembly contract | Read current connector/harness tables and the corrected active assembly/wiring documents. Confirmed the short incoming harness and J1-to-F1 copper remain upstream of F1 protection. |

The unchanged USB circuit's previous full-review evidence was reused only
after the geometry/anchor comparison. Fresh package comparison and the
separate 103-control native guard remain recorded in the
[Revision N evidence](../screen-power-stock-cost-1072/review.md).

## Findings and disposition

1. **Alternative relay contact material — advisory, not a defect.** Claude
   suggested the pin-compatible G6C-1117P-FD-US DC5. Omron describes FD's AgSnIn
   contacts for high-inrush **DC inductive** loads; neither variant has a
   published capacitive-make endurance guarantee for these screens. The
   closeout withdrew its initial “pure upgrade” wording. The procurement
   check found no result for that exact 5 V part in the
   [Mouser US search](https://www.mouser.com/en/c/?q=G6C-1117P-FD-US%20DC5).
   This is not proof that special ordering is impossible, but there is no
   verified available one-shipment alternative. Retain the selected stocked
   G6C-1117P-US DC5. No footprint or board change is required.
2. **Optimistic pickup-margin extrapolation — withdrawn.** Claude initially
   scaled the fuse's rated-current drop linearly to the low pickup current.
   The closeout recognized that hot restart can retain prior-load heat and
   that no guaranteed hot resistance curve supports that improvement.
   Retain the original conservative 100 mV allowance and published margins.
3. **Inherited IM02TS availability concern — closed as stale.** The closeout
   read the current combined stock evidence and separated transient stock
   availability from the existing USB-coil engineering bounds. The current
   loaded model's margin is 110.2 mV; older 110.8 mV text describes the
   superseded 4.4 A allocation.
4. **Overstated copper identity wording — corrected.** The reviewer withdrew
   “byte-identical copper” in favor of the exact compared geometry fields
   above, and independently included arc-midpoint and anchor checks.

## Independent adjudication of explanatory shortcuts

Two numeric explanations in the raw closeout were looser than the accepted
source bounds. They are corrected here rather than repeated as guarantees:

- At the actual minimum gate drive, use the IRLZ44N's **35 mΩ maximum at
  VGS = 4 V**, not its 25 mΩ figure at 5 V and not threshold voltage as proof
  of full enhancement. At a 50 mA illustrative coil current, the 4 V value
  gives 1.75 mV and 87.5 µW at its stated datasheet conditions. The design
  retains a larger 5 mV driver-loss allowance. No heatsink requirement follows
  from this coil-only dissipation.
- Bound the turn-off drain stress with the TVS's **10.5 V clamp**, not its
  7.14 V breakdown maximum: 5.25 + 10.5 = **15.75 V**, below Q5's 55 V rating.
  Its 5.8 V standoff and doubled bidirectional low-voltage leakage allowance
  remain included. This corrects the illustration without changing the
  component's suitability.

The raw reports also quoted end-to-end voltage figures from superseded fuse
candidates. For the selected Revision N parts, retaining the same deliberately
stacked allowances gives the following **engineering sensitivity, not a
manufacturer guarantee**. Use 4.75 V at J1, 4.46 A shared input, 4.31 A at K1,
and assess a 3 A main path or a 0.5 A touch path individually within the total:

| Loss after J1 | Main | Touch |
|---|---:|---:|
| SPT input fuse allowance | 100 mV | 100 mV |
| OGN holder, 4.46 A × 10 mΩ | 44.6 mV | 44.6 mV |
| Shared input/return copper allowance | 20 mV | 20 mV |
| K1 initial contact, 4.31 A × 30 mΩ | 129.3 mV | 129.3 mV |
| Shared switched copper allowance | 20 mV | 20 mV |
| Selected Bel branch-fuse allowance | 80 mV | 150 mV |
| Branch PCB/return allowance | 20 mV | 20 mV |
| VH/XH positive and return contact allowance | 60 mV | 10 mV |
| 30 cm one-way 20/28 AWG pair at 60 °C | 69.4 mV | 74.0 mV |
| **Total** | **543.3 mV** | **567.9 mV** |
| **Voltage before final screen termination** | **4.2067 V** | **4.1821 V** |

There are **no output holders** in this selected design. The last connector's
loss is not characterized; fuse/holder/contact losses are not guaranteed
hot/aged bounds. At nominal 5.00 V at J1, these same stacked assumptions add
0.25 V to the two results. They neither establish a screen failure nor prove
its unknown minimum operating voltage. The input requirement remains at J1,
not at the buck label or downstream of F1.

## Verdict and limits

Claude's completed final verdict is that **no unresolved actionable board
defect blocks the one-time bare-PCB order** for the exact native and archive
identities above. The supplemental primary checks preserve that verdict.

The review does not qualify actual capacitive contact endurance, real screen
inrush, screen-terminal minimum voltage, assembled enclosure temperature,
hand-solder execution or USB high-speed signaling. The 60 °C local-air /
100 °C winding envelope is an engineering condition. The optional FD part
does not remove those limits. No order, merge, flash or deployment occurred.
