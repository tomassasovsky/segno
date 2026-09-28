<!-- cspell:words Littelfuse FHAC GPIO MOSFETs Rds PXCN overcurrent -->
# Claude findings: implemented corrections

25 September 2026. Issue [#1072](https://github.com/tomassasovsky/segno/issues/1072),
PR [#1080](https://github.com/tomassasovsky/segno/pull/1080).
Scope: the owner's request to fix the completed Claude cloud review, against
baseline `ffaa9552c8f2a07bcc67f53ee6568d5dc6e2a83a`.

The accepted work is to specify the missing upstream protection, correct the
assembly preview and carry the resulting voltage drop into the documented
operating assumptions. Keep the through-hole circuit and proven copper
unchanged unless a verified defect requires a change. Do not apply findings
that Claude withdrew or convert unmeasured hardware behaviour into a pass.

## Changes and disposition

| Claude item | Implemented result |
| --- | --- |
| F1 — input protection | External BOM and wiring now specify a Littelfuse 028707.5PXCN fuse and FHAC0001ZXJ inline holder on the dedicated screen branch, immediately after the AUX positive split. The return is direct; console/ring remain on their separate branch. This covers the formerly unspecified shared-input fault path. It is supplementary harness protection, not a guaranteed MOSFET fault-clearing or survival design. |
| F2 — remove relays | No change: this was an optional experiment, not a demonstrated defect. Preserve deliberate USB data isolation. |
| F3 — gate margin | Validator and assembly instructions distinguish loaded J1 voltage from the nominal buck label and expose the fuse's effect. At 4.25 A, the assumed model needs 4.874 V at J1; at 6 A, 4.918 V. An ideal 5 V source with only the typical cold fuse loss leaves about 80/16 mV for every other loss. This is a conditional calculation, not proof that the real source meets it. |
| F4 — startup | The correct 0.153 A²·s touch-fuse melting figure is retained. Claude withdrew the unsupported 100 nF gate-capacitor recommendation. No guessed capacitor or faster gate driver was added; neither would establish startup/SOA qualification. |
| F5 — job metadata | Already corrected in the baseline: the impedance-control field is absent, rather than explicitly false. |
| F6 — R8 preview | Replaced the generic resistor preview with a source-generated PR01 maximum-envelope model, assigned in both the board generator and finished native PCB. The existing footprint, lead pitch and placement are retained. |
| F7 — courtyard gaps | No change: independent physical envelopes disproved the claimed body collisions, and Claude withdrew that claim. |
| F8 — USB neighbours | Informational observation; no routing correction recommended or justified. |

The retained buck advertises overcurrent, short-circuit and thermal protection,
but supplies no coordination curves. The selected fuse does not promise prompt
clearing on its nominal 10 A source. These limits are stated in the assembly
instructions rather than hidden behind the fuse's nominal rating.

R8's new model is a conservative assembly envelope, not manufacturer CAD.
Its body/coating distinction and simplified formed leads are documented in
[model notes](../../../hardware/kicad/screen_power/models/README.md).
This changes only one model assignment in the native PCB: pads, copper, zones,
outline, component values and connector orientation remain identical.

The [completed independent review](review.md) covers architecture, conventions,
test quality, simplicity and readiness.

## Validation and publication

- Native KiCad ERC/DRC: zero findings; all 36 fault controls pass. Independent
  tests also reject an absent, disabled or unassigned R8 model specifically.
- Independent import finds seven valid R8 solids with the documented envelope
  and exact lead-to-pad alignment. Clearance to F202 is 2.350 mm and to the
  board edge 1.75 mm. No footprint change is needed.
- Numerical thresholds were independently reproduced and checked on either
  side of the modeled 4.5 V gate boundary. The validator does not claim an
  actual source floor or measured hot resistance.
- Fresh assembly STEP and top/bottom/perspective renders were exported. Top
  and perspective renders were visually inspected; all 37 parts have models.
- The independent fabrication audit passes **379 assertions**: 60 source
  hashes, 65 artifact hashes and both package/published ZIP identities. Fresh
  seven Gerbers, two drills and job match apart from creation timestamps;
  both drill-map PDFs match in decoded drawing/page/resource content. The
  original ZIP bytes were retained after this comparison.
- Python syntax, authored-source whitespace, CSV structure and document
  spelling checks pass. No application or firmware code changed.

[Independent source/artifact hash record](../screen-power-rev-k-1072/fabrication-verification.json).
Manufacturing artwork remains Revision K; no new bare-board revision is needed
for external harness parts and assembly models.

Native board: `f5d86257daeb4ca4a534eade7fb7163ddc2a30684de504a2670f663bb7e724fa`.
Unchanged screen ZIP: `171034c87f3d371db9f7017a196960bdb7e01c249c1178eba90abb3ab2f05e3c`.
The console and ring archives are also unchanged.

This completes the verified design/package corrections. Loaded gate voltage,
startup, assembled temperature, USB operation and shutdown timing still need
the actual assembly. No complete production-unit sign-off, order, firmware
flash or merge is claimed.
