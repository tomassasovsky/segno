# Independent H1 ground cleanup review

Reviewed 2026-09-28. No actionable findings in the bounded copper/source repair.

## Scope and identity

Base: published hardware commit `bd6456f8efa12418d267a5108e6c70362c746882` (Rev O).
Reviewed working changes: `hardware/kicad/screen_power/pcb.py`, `hand/screen_power_hand.kicad_pcb`, and `hand/screen_power_hand.placed.kicad_pcb` only. The unrelated local `.kicad_pro` override is excluded and preserved.

- Finished native PCB: `585a1a97a0243bd4a06fac55af35f7acca64c4c690f57c16f86b29a91e960424`.
- Placed native PCB: `d5f1910381bad2ceb8659ec27e02f183abdd305417605d0510c11d1101aee5aa`.
- Preserved local project: `a4dd9cb99056c18c946e577eb2a40fc5d4fae3674e2eecef2c06de78f2f3140d`.

This is independent review of the current H1 repair, not a fresh full-circuit review, approval of the pending Rev P exports, or review of a future commit. The coordinator is advancing the revision and regenerating publication artifacts; those identities require closeout binding.

## Independent verification

I read AGENTS.md, PROGRESS build/test instructions, TRACKING.md, the code-review and pcb-layout skills, the architecture/conventions/simplicity/test-quality role definitions, the full generator and changed function/caller, and the native diffs. I inspected native copper before/after and the populated corner render.

An independently written S-expression comparison (`independent-native-review.py` and `.json`) read each board directly from the base commit and working files. In both boards every non-zone item is identical, including footprint and pad definitions, track/arc/via geometry and widths, edge cuts, drills, layers, nets, text and models. Every surviving zone definition is identical. Exactly two named `GROUND_TIP_CLEARANCE` rule areas were deleted; there are no new rule areas. This corroborates the separate 1,313 track/via and 46 footprint/pad comparison without relying on that comparison's limited field list.

Independent polygon analysis (`independent-ground-review.json`) confirms:

- Front ground adds 1.805565 mm² near H1. Apparent removed area is 0.000000626 mm² from polygon arithmetic; difference outside the H1 region is below 0.000001 mm².
- Rear ground is geometrically unchanged.
- Each layer remains one filled ground component; no new isolated ground islands.
- The minimum front-ground distance from H1's center is 4.548130 mm, unchanged within numeric precision. This is the polygonal approximation of the existing nominal 4.55 mm circular boundary and retains margin beyond the unchanged 4.25 mm hardware keepout. An initial overly tight 4.549 mm review assertion was corrected after comparing the unchanged baseline contour; it did not indicate a design regression.

The two strict DRC reports contain zero violations, zero unconnected items and zero schematic-parity entries. I verified their input boards hash-match the reviewed finished PCB, and the strict project hash matches the project's tracked HEAD (`7c1d7d080c6be1d59b356208051249e8192af8b31a7946a435ef9cd95a7b2727`), not the local override. Refill output is byte-identical. The existing ignored-check list is disclosed in each DRC JSON and was not changed by this repair. The generator parses successfully as Python.

## Bug-focused assessment

The underlying cause was stale front-fill exclusions for an older control-route location. Deleting those exclusions restores the generator's existing smooth washer clearance. The true mounting keepouts remain intact on both copper layers. No electrical isolation rule was deleted: the removed zones prohibited only ground fill and explicitly allowed tracks, vias, pads and footprints. The source helper and its sole caller were both removed, so regeneration does not reintroduce the defect.

All USB traces, return-plane geometry in their region, connector pinouts, fuse/power routes, relay geometry, current-carrying widths, mounting holes and hole clearances remain unchanged. The only added copper is connected ground next to H1, and strict clearance checks remain clean. This bounded change introduces no observed USB, power or mechanical regression.

## Architecture, conventions and simplicity

All three roles are clean for this scope. This is native KiCad geometry plus its Python generator, with no application/firmware layer changes. The repair deletes obsolete special-case geometry instead of adding another trim layer, preserving the AGENTS.md direction to remove obsolete paths and choose the simplest complete implementation. Existing reusable `ground_outline()` and `protect_mounting_hardware()` remain the only responsible mechanisms. No new dependency, abstraction, compatibility path or package is introduced. No actionable style issue is introduced.

## Test quality

The evidence checks resulting native objects, actual filled copper, connectivity/clearance and populated appearance rather than merely matching the removed source text. Exact-object comparison, strict tracked-project DRC, refill identity, and local polygon delta are appropriate for the repair. There is no new behavior requiring a tautological source-text unit test. Fresh full native/circuit/CAM/ground-budget checks after the revision bump remain the coordinator's release task; this report does not treat those pending outputs as passed. Dart/engine/firmware suites are not applicable to these files.

## Verdict and limits

The bounded repair is clean, with all assigned review angles completed and no unresolved findings. Authoring was performed by Claude; this independent review was performed separately and does not relabel Claude's authoring run as independent adversarial approval.

Final Rev P manufacturing ZIPs, manifest/source hashes, shopping/cart state, delivery-folder consistency, final commit, and remote CI are not covered by this working-copy report. Console/ring circuit review is inherited only where their identities remain verified unchanged. No assembled hardware, USB eye/compliance, cable quality or thermal qualification is asserted. Current-head publication review and green CI are still separate merge gates. No files in the repository were modified by this reviewer.
