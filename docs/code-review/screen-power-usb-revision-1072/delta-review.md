# Revision M final layout/source delta review

Reviewed 2026-09-26. PR base: `5fd9f8bf6856673d07b27054d0b98dd7ba719561`.
Delta baseline: `00060494b9af330cb2fbe7834fe9bae04bac65c0`, plus the working
files identified below. **No actionable findings in this bounded delta.**

Scope: changed placement, critical routes and finishing source; the new
shield-drain construction assessment; corresponding README/cable-assessment
links. Reviewed removed behavior, retained guards, cross-file connections,
unnecessary complexity and native correspondence. Final publication/status
editing and CAM export belong to the release review, not this report.

## Findings and verification

- The coil return changes from the lower driver's drain to the new upper
  driver's drain; the added lower-drain/upper-source connection implements
  the already-reviewed series-switch topology. Explicit routes retain their
  net-equality assertions and locked status. USB, power-width, reference-plane
  and component-validation guards were not removed or relaxed.
- The USB target changes from 0.85/0.16 mm to 0.78/0.23 mm while preserving
  1.01 mm center pitch. Existing pair construction and protection remain.
  New placement constants and local routes add no alternate circuit path,
  compatibility layer or helper framework.
- Independently loaded the final native board. TP101/TP201 are at
  (13.5,31.5)/(13.5,56.5); TP102/TP202 at (51.47,32)/(51.47,57) mm. Each
  retains a 2 mm GND pad, 1 mm drill and hidden reference. The four unwanted
  front-silkscreen circles are absent.
- Executed the placement cleanup on a disposable in-memory board with four
  injected TP front circles and comparison circles on other layers and a
  different footprint. Exactly those four front circles were removed.
  Other graphic identities and every pad/track/zone identity were preserved.
  No file-backed native board was modified.
- Verified the final board contains the rear name/revision, front revision,
  input/control labels, both screen power/touch labels, both Pi labels and
  all four USB pin-map columns. Rear pin-map labels are mirrored correctly;
  their positions follow the unchanged connector pin ordering. The removed
  duplicate front board name is identification, not a missing functional
  connector legend.
- Recalculated the documented drain polylines: host **7.0583 mm**, touch
  **9.1097 mm**, agreeing with the stated allowances. The construction text
  preserves independent pin-4 ground, insulation and strain relief, bounds
  jacket/drain diameters, and distinguishes local paths from full harness,
  enclosure or USB qualification. Its recorded earlier placement hash is a
  historical assessment snapshot; the four coordinates also match this final
  native board.
- Inspected the full native validation report: **75/75 controls true**, no
  errors, and **zero DRC, ERC or unconnected findings**. Independently hashed
  every input named by that report and found no mismatch. `check.py` and
  `switch_circuit.py` are byte-identical to `00060494`; this review did not
  rerun the expensive full suite or treat changed thresholds as a pass.
  Python AST parsing and scoped whitespace checks passed.

## Exact reviewed files

| File | SHA-256 |
| --- | --- |
| `hardware/kicad/screen_power/layout.py` | `a8cd83e901fbb763c6444726edbf2c2843e8eda4d50d9eab9d24146f84117ae7` |
| `hardware/kicad/screen_power/route_critical.py` | `e029f27cd59704fa86d86eef495f7ee16d6489ce1911215f8b9bba2cf9f0e7b2` |
| `hardware/kicad/screen_power/finish.py` | `bd04338e036e2b884da255e937ec48afb6f636a4770ffdac64084d4eeeaf12d0` |
| `hardware/kicad/screen_power/README.md` | `94f0279d565ac2b1c15b18b045a978ad97b7467c346a9796150e93f2dee1a23a` |
| `docs/reviews/screen-power-usb-revision-1072/cable-assessment.md` | `0065490eb9b1491c8edf0d072e65b2a9c109da72fcd6ff888a9876b2af5feafb` |
| `docs/reviews/screen-power-usb-revision-1072/shield-drain-fit.md` | `c1d74af503614e06a772fbb3d0f482f31b2c2d2e0ab4af466b892098f5038d8f` |
| `hardware/kicad/screen_power/hand/screen_power_hand.kicad_pcb` | `8a467b1c6a881cbf7dd117d38366cfda466f1a51c64553296cc374b4ca52cb27` |
| `hardware/kicad/screen_power/validation.json` | `c7aa4a3c55ad94fce63e3c1b2651afad39f84f883576b77e062f49b023c5654b` |

No failed checks or unresolved findings in this scope. This report supplements
the earlier circuit and shared-helper reviews; it does not declare the whole
PR merge-ready, certify assembled USB behavior or cover a later package export.
