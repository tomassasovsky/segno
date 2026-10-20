<!-- cspell:words FPID fanout SHLD -->
# VGV code review — Revision O USB connectors

## Summary

Completed source and native-boundary review of the working delta from
`add2748edce2c274e931e7fc3c524d1695d1ea2c`, against the September 28 Revision O
plan. The electrical and purchasing changes agree, and the removed solder-pad
behavior is replaced throughout the source and regenerated schematic. The
verified generator/validator mismatch is resolved by correcting the new native
identity assertion to the project's established customized-footprint convention.
There are no unresolved findings for the final board and source snapshot below.
The final label correction is verified in the populated render, and current
native, fabrication and copper-loss reports refer to the same board hash.
This role covers the Revision O delta; the final PR state and delivery manifest
remain the coordinator's publication scope.

The reviewed implementation is a Python/SKiDL/KiCad generation and validation
pipeline. Flutter state management, presentation layering and UI tests do not
apply to this delta. `AGENTS.md`, `docs/PROGRESS.md` build/test guidance,
`docs/TRACKING.md`, the VGV role and the review reporting contract were read.
`docs/CODEX_WORKFLOWS.md` is absent from this checkout; the assigned role files
were available. The local `.kicad_pro` override was preserved, excluded from
reviewed changes, and replaced with the tracked project settings only in a
temporary verification stage.

## Critical — must fix before merge

None unresolved.

## Important — should fix

None unresolved.

## Suggestions

None. This review omits cosmetic changes and pre-existing cleanup opportunities.

## Resolved identity finding

The initial validator required a full qualified native footprint identifier,
where the generator and Revision N use bare native item names. The initial
failure was real, but this review's proposed remedy of qualifying all native
instances did not account for their deliberate modification after loading.
That recommendation is withdrawn.

The corrected assertion compares `GetLibItemName()` exactly with the selected
five-contact footprint name. This is the appropriate native invariant: source
records and the BOM retain the exact qualified B5B-XH-A identity, while the
board contains customized local copies. Direct inspection confirms five
1.10 mm native drills versus the installed stock footprint's 0.95 mm drills,
plus project-relative model links instead of the stock library links.
Silkscreen normalization is likewise an established generation step. The
temporary `SetFPID` addition has been removed from `pcb.py`; its new comment
explains this convention.

The CAD author reported 32 stock-library mismatch warnings after the temporary
qualification. This reviewer did not independently rerun that full DRC count;
the verified geometry and model differences substantiate why stock equality
is the wrong requirement. No DRC severity, exclusion or suppression was added
by this resolution. It introduces no fallback to the old connector.

With the current validator, the placement-board header check has no errors.
A temporary native board with explicitly unqualified header identifiers also
passes the baseline and all six native header mutations: wrong pitch, missing
shield, duplicate terminal, wrong shield net, four-pin identity and obsolete
shield pad. All 35 current power-source/BOM controls pass. The changed check
retains five numbered terminals, exact row pitch/order, plated holes, grounded
pins 4/5 and complete header inventory, alongside the existing netlist parity,
assembly and model checks. This closes the source-level mismatch; it does not
substitute for final-board regeneration and full validation, which are now
verified below.

## Final native and evidence closeout

Final board SHA-256:
`bf870faa7c5e1be2dd9843d1587c76888508ece7549b27b5013d0eb7a77c9fc2`.

- `screen-native-validation.json` records `cad_ready: true`, all 123 self-tests
  true, and zero errors, warnings, exclusions, unconnected items or findings
  in both native ERC and DRC. Its input hashes match the current reviewed
  sources. The sole working-tree mismatch is the excluded local project
  override; the release-stage project is byte-identical to the tracked
  baseline project and matches the validation hash. No new ignored rule was
  introduced by the Revision O changes.
- Independently loaded the final native board and reran pad/netlist parity,
  the circuit contract, USB header checks and model coverage. There were no
  errors, 42 populated model references, four exact five-contact header
  names, GND on each pin 4/5, and no obsolete shield footprints.
- `screen-fabrication-verification.json` passes 415 checks and binds the final
  board hash. The unchanged console/ring fabrication report passes 175 checks
  with zero failures. These observed reports support their stated comparison
  scope; they do not constitute assembled hardware qualification.
- The final USB track lengths remain 23.526702/23.526703 mm upstream and
  26.178136/26.178136 mm downstream per channel. The native filled-ground
  check covers 6,264 center/edge samples. The independent preservation result
  records 292 unchanged USB copper items and unchanged original terminal
  anchors against Revision N before the final silk correction.
- Independently parsed the pre-correction and final native boards. All 1,292
  track segments, 21 vias, 316 zones, footprint positions and complete pad
  definitions are identical. This confirms the final two-label correction
  cannot invalidate the preceding copper-preservation result.
- Both ground-return reports bind the final hash. Their stated material
  sensitivities give approximately 13.15–13.65 mV total modeled copper drop
  for nominal copper and 15.93 mV for thinner copper, below the retained
  20 mV modeled budget. Their mesh, terminal and material assumptions remain
  explicit; no measured voltage or thermal guarantee is inferred.

The moved R7 body initially hid `CTRL`, confirmed in the populated top render.
The final source places `CTRL` horizontally at (7.5, 18.4) mm and the Q5
reference at (8.5, 20.3) mm. Both are exposed and legible in the final populated
top render. The bottom render shows all four `5 SHLD` legends aligned with the
fifth contact and the retained pins 1–4 map. The top and bottom renders are
bound by the updated fabrication report. This closes the label finding.

## Removed behavior and cross-file evidence

- Parsed old and new netlists independently. The exact semantic difference is
  removal of `TP101`, `TP102`, `TP201` and `TP202`; replacement of the four USB
  header footprint/value records; and addition of pin 5 on each header to GND.
  Every other terminal-to-net association is unchanged. The power circuit,
  host-presence detectors, relay contacts and protection boundaries are retained.
- `switch_circuit.py` creates `Conn_01x05` with B5B-XH-A footprints and MPNs.
  The schematic no longer classifies or excludes removed test-point parts.
  The board generator and model coverage check no longer exempt their bodies.
  New native, netlist and purchasing checks reject the obsolete references.
- A clean temporary source generation matched the checked-in component JSON,
  purchasing BOM and all seven schematic files byte-for-byte. Its parsed
  netlist components/nets also matched. Fresh KiCad schematic netlist export
  matched the generated components and normalized electrical nets.
- Native ERC in a temporary stage with the tracked project settings and local
  footprint library reported zero violations. An initial incomplete temporary
  stage lacked the project's ERC configuration and footprint table; its
  configuration warnings were resolved by completing the stage, not by
  changing or weakening repository rules.
- The ignored `circuit_sklib.py` is SKiDL's generated backup library. Current
  and clean-generation copies contain `Conn_01x05`, with no `Conn_01x04` or
  `TestPoint`. Native symbols are regenerated from actual circuit parts. No
  active old-symbol consumer or compatibility path was found.
- The five-pin STEP file is byte-identical to the installed KiCad connector
  model, SHA-256
  `8af7ded5ecaefc019081b2092b15a5a7a5b727e110fed3328bc806903f5d1a63`.
  Its filename agrees with the selected footprint and relative model lookup.
- The active harness/BOM documents use four XHP-5 housings and twenty USB
  contacts, preserve pin 4 as the dedicated return, use pin 5 for shield, and
  retain the main-power VH paths. The [JST XH drawing](https://www.jst-mfg.com/product/pdf/eng/eXH.pdf)
  independently supports B5B-XH-A/XHP-5 at 2.50 mm pitch and the selected
  SXH-001T-P0.6 contact's 28–22 AWG, 0.9–1.9 mm insulation range. The documents
  keep donor suitability, wire fanout, enclosure fit and complete-channel USB
  qualification separate from this connector selection.

## Simplicity assessment

- Unnecessary abstractions: none introduced.
- YAGNI violations: none introduced.
- Removable lines: no necessary scope addition identified.
- Verdict: narrow changes reuse the established generator and validator
  boundaries. The new constants and focused mutation helper have clear roles.

## Testing assessment

Source contract and BOM identity checks pass. All USB power and power-source
fault controls pass, including every header's missing/wrong-net shield terminal,
obsolete pad reintroduction, and consistently wrong connector purchasing data.
Tests inspect independent circuit/part contracts instead of merely duplicating
the generated record values. Existing USB routing, power, ground-reference,
hole, silkscreen and circuit checks were not removed or relaxed by the reviewed
stable-source changes. The now-obsolete zero-quantity record/BOM path was also
removed, with a passing mutation that rejects a connector changed to zero
quantity consistently in both files. Native header baseline and focused fault
controls pass as described above; the final native routing, full fault suite,
fabrication comparison and render correction also pass for the recorded final
snapshot. No hardware qualification is claimed.

## Stable source snapshot

| File | SHA-256 |
| --- | --- |
| `check.py` | `710d3338539c5adaa29772745c4defb32a55c9169fad2e22f971f0f2190f794b` |
| `switch_circuit.py` | `5e57a93f50c19db41cf1f736c355b5eb2e2b066ceee0d23f38f9d76b11f10083` |
| `schematic.py` | `ea1bafa3f74fa7f62fe056744117a227fb3b0d599be30b72104afa27b9596aaa` |
| `pcb.py` | `8d5cd800d4897b65dfe6ba16f45a4f581ab09f4b7be6ccdb06dcc42a610d8d4f` |
| `models.py` | `3a49e950a8323db0a4fb9b73273ba7039b286eb79383243f4d95f9fa8dbf6db6` |
| `layout.py` | `db565369bdd15123f820ab8da278cc872dd4d1fe1cb247f67d4455addc84f9db` |
| `route_critical.py` | `122349034a52435cc863c7703c7cba790e9b39021e042fb9197b8b13f98805b1` |
| `finish.py` | `402676c0d4904665d2817cc0ea0fc1ebdbdb6a70ce6c77b01354cf1813905cb5` |

Paths in the snapshot table are relative to `hardware/kicad/screen_power/`.
