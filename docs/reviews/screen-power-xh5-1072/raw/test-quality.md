# Revision O test-quality review

## Scope and identity

Reviewed the validator and deliberate-fault test delta from
`add2748edce2c274e931e7fc3c524d1695d1ea2c`, primarily
`hardware/kicad/screen_power/check.py`.
The reviewed checker SHA-256 is
`710d3338539c5adaa29772745c4defb32a55c9169fad2e22f971f0f2190f794b`.
The final native board SHA-256 is
`bf870faa7c5e1be2dd9843d1587c76888508ece7549b27b5013d0eb7a77c9fc2`.

This is a Python/KiCad hardware-validation change. Dart, Flutter, state-management
and UI-test coverage requirements do not apply. No percentage coverage claim is
made. The review retains the prior Revision N evidence for unchanged circuitry;
it does not independently repeat the historical full-board electrical review.

## Coverage summary

- Circuit contract requires pin 5 on all four USB headers to be GND while
  preserving the pin 1–4 assignments and source isolation boundaries.
- Component records, purchase BOM, netlist and native board must use the exact
  five-pin XH interface. The four obsolete separate shield-pad references are
  rejected rather than accepted as a compatibility option.
- Native checks cover exactly five unique plated terminals, pin 4 and pin 5
  GND assignment, one straight row at 2.50 mm pitch, exact footprint item name,
  and one instance of each required connector.
- New circuit mutations exercise missing and wrongly connected shield pins on
  all four connectors and reintroduction of each obsolete pad.
- Native mutations exercise missing shield terminal, duplicate terminal number,
  wrong shield net, wrong pitch, obsolete footprint identity and obsolete pad.
- Existing power, ground reference, USB connectivity/length, current-path,
  mechanical, hand-soldering, rule and source-parity gates remain present.
- Required self-test names include the newly added circuit/native cases. Part
  selection cases are included through the existing power-source test inventory.
- After removal of the bare shield pads, every remaining component record must
  represent one fitted instance and have a corresponding BOM entry. The obsolete
  zero-quantity compatibility branch is removed.

## Findings repaired during review

### Exact part-selection mutations were masked by parity checks

The initial `four_pin_xh_purchase_detected` and
`four_pin_xh_record_detected` cases changed only the component record. Generic
record/BOM/netlist disagreement therefore rejected those fixtures even when
the new exact five-pin part-selection rules were removed in memory.

The author changed the MPN fault to update record and BOM together, and the
footprint fault to update record, BOM and parsed component identity together.
Independent re-execution confirms all 34 power-source/BOM cases pass with the
real checker. Removing only the exact XH selection constraints makes exactly
these two cases fail. They now protect the intended selection contract instead
of merely exercising existing parity checks.

### Removed-pad wrapper lifetime could crash native mutation tests

The initial missing-shield case used `header.Remove(shield)`. On a fixture derived
from the complete board, subsequent mutation iterations produced invalid SWIG
footprint wrappers; one probe also terminated with a segmentation fault. The
KiCad Python wrapper transfers native-item ownership to Python in `Remove`.

The author switched this temporary mutation to `RemoveNative`, matching the
existing mutation patterns. Independent re-execution of the seven native
header cases passed three successive times, with garbage collection and
successful iteration of all retained board footprint wrappers after each run.

### Bounded follow-up: fitted component quantities

Reviewed the architecture follow-up that requires quantity one for every
remaining component record and includes all records plus the input fuse holder
in the required BOM inventory. The new `unpopulated_component_detected` case
changes the header quantity to zero consistently in the record and BOM, so
record/BOM disagreement cannot mask a missing quantity constraint.

Independent execution against the generated Revision O netlist and component
records passed all 35 power-source/BOM cases. Removing only the new quantity
constraint in memory made exactly `unpopulated_component_detected` fail.

### Bounded follow-up: customized native footprint identity

The final identity rule compares the exact native footprint item name using
`GetLibItemName()`. Customized native copies may omit the library nickname;
they are not claimed to match an unchanged stock-library footprint after the
documented drill, silkscreen and model adjustments. Component records and BOM
still require the fully qualified selected footprint, and the independent
native terminal count, numbering, geometry, net and drill checks remain intact.

Ran the seven native header cases successfully against a snapshot of the actual
Revision O placed board, SHA-256
`a6a4f871acf34b25a3bf85ab12ff10a6c7399d63dcb9478af451652d375a26f7`.
For each of the four headers, independently verified that qualified and
unqualified B5 item names pass, while qualified and unqualified B4 item names
fail despite retaining five-pad geometry: 16/16 expectations passed. Garbage
collection and subsequent footprint access also passed. This verifies the
identity check does not silently rely only on pad count.

## Independent execution

Fixtures use converted Revision N component records or a native board with the
standard five-pin KiCad footprints. They are isolated test inputs, not production
CAD or a substitute for validating the finished Revision O board. The later
quantity follow-up additionally used the generated Revision O circuit records.

| Check | Observed result |
|---|---|
| Power-source and coherent BOM fault suite, including quantity follow-up | 35/35 pass |
| Exact-selection constraints deliberately removed | Only the two corresponding XH faults fail |
| Fitted-quantity constraint deliberately removed | Only the corresponding unpopulated-component fault fails |
| USB circuit/supply fault suite | 24/24 pass |
| Additional native faults across all four headers | 24/24 rejected |
| Native header baseline/fault suite, after lifetime fix | 7/7 pass on each of three runs |
| Header suite on actual Revision O placed-board snapshot | 7/7 pass |
| Qualified/unqualified B5 acceptance and B4 rejection across four headers | 16/16 pass |
| Post-run garbage collection and footprint access | Pass on all three runs |
| Checker diff whitespace validation | Pass |

The additional native checks independently exercised absent pin 5, incorrect
pin 4 GND, incorrect pin 5 GND, duplicate numbering, distorted pitch and a
missing expected header reference for each connector.

## Final native validation closeout

Reviewed the completed [native validation report](../screen-native-validation.json)
generated on 2026-09-28 at 21:05:28 UTC with KiCad 10.0.4. The complete
`check.py hand --self-test` run reports 123/123 true results, no validator errors,
and `cad_ready: true`. Fresh DRC and ERC each report zero errors, warnings,
exclusions and unconnected items.

Independently verified every one of the report's 64 source hashes against the
isolated release stage, including the final board and unchanged reviewed checker
identities above. The corresponding working files also match, except for the
deliberately preserved pre-existing local project settings. The release project
matches the tracked Git version, SHA-256
`7c1d7d080c6be1d59b356208051249e8192af8b31a7946a435ef9cd95a7b2727`.
It retains minimum silkscreen clearance 0.15 mm, text height 1.0 mm and stroke
0.15 mm. The local weakened settings were not used as release evidence.

The initial isolated-config ERC attempt did not establish a pass because stock
footprint library tables were unavailable. The completed rerun resolves those
libraries and reports zero ERC findings; the failed attempt is not counted as
approval. The stable, complete report was inspected rather than repeating the
unchanged full native suite.

The final refresh follows a visibility adjustment to the `CTRL` label and `Q5`
reference. An independent native-file comparison against the previously checked
board found only those two silkscreen text changes; copper, pads and filled zones
are unchanged. The refreshed report again matches all 64 release inputs and the
unchanged checker. The [USB preservation report](../usb-preservation.json) is
also bound to this final board and records all 292 USB copper items unchanged
from Revision N, with no changes to the pre-existing connector/relay pad anchors.

## Verdict and limits

No unresolved validator or test-quality findings remain at the checker identity
above. Both actionable findings were verified and repaired, and the final native
test-quality scope is complete for the recorded board/source identities.

The native report explicitly records hardware qualification as not performed.
This review does not establish physical USB compliance, assembled operation,
fabrication-package identity, CI status or approval of later source edits;
those remain distinct from the completed validator and native-test review.
