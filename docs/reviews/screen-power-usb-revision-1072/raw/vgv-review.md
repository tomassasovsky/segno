<!-- cspell:words scikit -->

# VGV conventions review — Revision M source

Reviewed 26 September 2026. Range: `355882d848477537cb491b8ab9180123eb7f8971..d4fde1951cdfd384eced740d9f599c255ebe2b95`, plus the subsequent working-tree removal of duplicated relay pickup calculations in `check.py` (reviewed file SHA-256 `ccbd1f5a71d7f74f687b110e080c0f5e6ad9db3b7c9613d5007fd2d1206006a3`).

## Summary

No actionable convention, generator-consistency or regression finding was established in the assigned source change. This is a bounded source review, not approval to merge or manufacture the board. The Revision M native layout and its full validation/publication are deliberately pending and must pass separately on the completed revision.

## Scope and detected stack

Read the worktree instructions, build/test guidance, tracking contract and review reporting instructions. The affected stack is Python with SKiDL 2.3.0, KiCad 10/pcbnew, project-local schematic serialization, and separate PCB placement/routing/export stages. The additional impedance study is a standalone NumPy/SciPy/scikit-fem analysis utility. Flutter presentation/state-management conventions do not apply to these files.

Reviewed `switch_circuit.py`, `check.py`, `pcb.py`, `models.py`, `schematic.py`, `finish.py`, the three new source/impedance review utilities, their callers, generated BOM/component records/netlist/schematics, and the assessment explanations of model limitations. Existing hardware requirements files, build entrypoint, native footprint/pad validator and export boundary were inspected. No application dependency or runtime API changed.

## Critical — must fix before merge

None within this source-review scope.

## Important — should fix

None within this source-review scope.

## Suggestions

None. The compact formatting follows the surrounding hardware scripts; broad formatting or architecture work would obscure this electrical change without improving its correctness.

## Regression and generator assessment

- The resistor helper's optional group argument preserves existing callers and correctly groups the four new channel resistors. This is an extension of the existing circuit generator, not a new compatibility layer.
- Host VBUS, coil, stack and sense-net pin contracts changed together with the generated circuit. USB contact terminals remain unchanged.
- The four shield pads remain physical schematic/netlist components while being omitted from the purchase BOM. The selected stock footprint already excludes them from position and BOM output. Its intentional lack of a solid 3D body is handled narrowly by reference and footprint name in both generation and validation; the populated-component model checks remain intact.
- Native schematic export independently reproduced all 58 component definitions and semantic net memberships in the committed generated netlist.
- A disposable SKiDL rebuild reproduced the committed component records, purchase BOM, parsed raw netlist components/nets, and all generated schematic files. There are 54 purchase-BOM rows: 50 populated electrical components plus four mechanical holes; the four bare shield pads are absent as intended.
- The disposable generator reported zero circuit ERC errors and warnings. Environment/library-search and SKiDL generation warnings were visible; they were not presented as circuit ERC failures. No source or generated deliverable was changed by the review.

## Testing assessment

Independent execution with KiCad's Python passed the pin-level contract and numerical checks, the 48-case ideal state sweep covering 96 coil paths, and all 13 mandatory new USB fault controls. The controls exercise the previous host-powered coil, bypassed host qualification, crossed host sensing, missing or unsuitable divider parts, reversed upper/lower driver terminals, a wrongly connected shield, a restored host reservoir, and misleading tolerance spelling. In particular, bypass/cross-channel/reversed-driver mutations are required to fail the state-path model rather than merely a reference pin table.

All six scoped production Python modules parsed successfully, and the committed change passed `git diff --check`. The circuit generator and native schematic parity checks were run independently rather than relying only on the author's stored evidence.

The final `check.py` delta removes a duplicated coil pickup calculation and top-level result fields while retaining the per-channel calculation, numerical guard and corresponding results in `usb_power_margins`. A caller search found no production consumer of the removed fields. The source contracts, numerical checks, state sweep and all 13 controls were rerun successfully after that change.

The ideal switch sweep is explicitly not an analog or timing simulation. Its Boolean GPIO/AUX boundary and separate numerical gate-margin analysis are appropriate only inside the documented fixed circuit contract. The hot-resistance, leakage and restart values retain their stated engineering-estimate status. The utility's FEM convergence and cross-section claims were inspected for software structure and scope but the numerical field solver was not independently executed in this review.

## Simplicity assessment

The electrical change adds two channel-local switches and their resistor dividers to the established generator and extends the existing validation pipeline. No unnecessary interface, configuration framework or alternate implementation was introduced. The new analysis utilities remain isolated from manufacturing generation and do not add a dependency to the PCB build. No removal or abstraction change is recommended in this bounded pass.

## Material limits

This review does not establish routed copper parity, final DRC, final model/clearance checks, USB signal integrity, thermal operation, transient behavior, cable construction, final fabrication-archive identity, CI status or full-PR bug-review completeness. The native PCB is intentionally still the prior revision; that known intermediate state was not counted as a newly introduced defect. The review boundary is the commit and the explicitly identified subsequent `check.py` delta above. Final layout changes require fresh scoped review and validation before release.
