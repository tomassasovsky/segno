<!-- cspell:words silkscreen soldermask nonoverlapping SWIG -->
# Final manufacturing correction review

No unresolved actionable finding in this bounded final delta against baseline
`d32bca8b24c543b907ee1f104ebf8b04f6fa6947`. This covers the silkscreen/source
correction and current assembly/BOM documentation. It does not replace the
complete circuit reviews or independently certify assembled operation, whole-PR
CI, or the final manufacturing archives. Archive acceptance remains the fresh
export and independent CAM gates.

## Reviewed frozen inputs

| Input | SHA-256 |
| --- | --- |
| Screen native | `b1e5dbb5c4a9eef5137f5dd339a685fe2ce0eac174362ba4df1bfdb6f668a123` |
| Console native | `1c64edd2e49c9e40830d37f0e9b553fd5c57d28cba674f5d815e043c0f226199` |
| Ring native | `5ade14170d0280c922b7966e1f1d85d53a0e7ff9510e8342788400b7fe05d50b` |
| Shared silkscreen helper | `312eb503bb86f75695ec26589957e48499781108cf5498d7d03c146fee7e2719` |
| Screen checker | `fd84970aa612c4c92a54384b8e7374c17933cced167163bd6e7258f2e0f68856` |

`final-delta-source-hashes.json` records the individual generator, footprint,
project-rule and document snapshots and embeds the independent evidence below.

## Findings resolved before acceptance

The first clipping implementation retained live SWIG endpoint references while
mutating the same shape. Updating its start changed later endpoint calculations;
an actual relay stroke extended by approximately 0.150 mm. The final helper
copies both endpoints into independent `VECTOR2I` objects before mutation. The
author then replayed the correction from the original five native/placed
baselines; a second pass over already distorted ink was not accepted as repair.
The source/native Q3 reference-angle mismatch was also corrected during replay.
Neither correction altered electrical geometry.

## Independent preservation and source replay

- Parsed each of the three final native boards against the published baseline.
  Tracks, arcs, vias, exact zone outlines and filled polygons, nets, layers,
  pads, holes, footprint poses, models, courtyards and non-silk drawings are
  identical. Property names and values remain identical; only printed-field
  geometry and silk drawings are excluded from this comparison.
- All eight modified custom footprint files preserve every non-silk item.
  The artwork source changes only one existing back-face separator rectangle,
  moving it 0.20 mm; polygon count and other artwork remain unchanged.
- Fresh disposable screen placement and finishing replay uses the frozen
  `pcb.py`, `layout.py`, `finish.py` and shared helper. Source hashes remain
  unchanged during the replay. Printed labels agree, including Q3's angle.
  Only C2/C102/C202 retain 12–21 nm position/ink translations from serialization:
  this is below the explicitly accepted 0.0001 mm comparison tolerance. Hidden
  H1–H4 references differ in size (1.0 versus 0.85 mm) but produce no printed ink.
  No unrelated geometry was regenerated to chase those differences.
- The console author's clean source build and all 15 targeted negative controls
  pass; all 66 references match, with only a 2 nm unchanged PD-label coordinate
  rounding difference. The final source `ef4fa0ac661d9a22b2a06eeeea0ad09f1e89effa6fba9c332aa8aba8958e6084`
  runs the shared mask gate after all existing `_check` assertions. This preserves
  each deliberate faulty fixture's intended diagnostic without weakening any
  predicate. The routed native guard also passes. The shared mask gate runs
  before the ring export.

Evidence: `final-delta-invariants.json`, `screen-source-replay.json`
and the published silk/layout native and source records.

## Guard and helper assessment

The shared polygon guard checks rendered native text/outline ink on both faces
against every pad's resolved soldermask opening, including neighboring
footprints. This supplements project DRC, which missed real sub-0.15 mm gaps.
The clipping implementation and polygon checker use distinct geometric tests.
The screen source inventory now includes the shared helper and the actual board
project file; the export can therefore detect changes to these dependencies.

An independent reviewer exercised seven native cases: valid 0.16 mm clearance;
invalid non-overlapping 0.10 mm clearance; another footprint's opening; expanded
and zero mask margins; a split stroke; and an original start inside the opening.
They confirmed the last case preserves the original far endpoint. In-memory
reapplication preserves graphical geometry on all three final boards, and the
native mask guard passes. Recorded minimum gaps are 0.158743 mm screen,
0.165 mm console and 0.158708 mm ring.

The refreshed canonical screen validation report has zero errors, zero DRC
findings/unconnected items and all 61 mandatory fault controls passing. Its
native, checker and shared-helper hashes match the frozen inputs above. Five
new controls exercise actual text height, text stroke, outline stroke, the
project clearance floor and a real non-overlapping short ink-to-mask gap; the
previous 56 controls remain mandatory. These changes and the shared extraction
received independent review. `git diff --check` passes.

The current guard covers the boards' native text, fields, shapes and pad-mask
openings. It is not a claim of support for arbitrary future bitmap/text-box
artwork or standalone mask cutouts. The current boards were also independently
inspected geometrically and visually.

## Documentation and assembly review

Reviewed manufacturing, wiring, purchasing, ring assembly, screen README and
new review prose against the actual sources/BOMs. The PCB J2 pin contract is
1 +5 V, 2 GND and 3 DIN. The final selected harness uses DIN only; the separate
star-feed follow-up below supersedes the earlier straight-through power lead.
DOUT and alternative module pads are unpopulated. The encoder selection and CSV field counts are consistent.
Console/ring USB service isolation and the separate runtime dependency are
explicit. Runtime revision `92af127d9a2d58c4ea9b810b38d06ca3ddc3c73d` actually
contains the presence-input E9 workaround and named runtime code. The prose
retains draft/runtime, enclosure and assembled-verification limits, and does
not turn calculated thermal margins or fuse ratings into measured guarantees.

No additional production source, circuit or CAD correction is requested by
this review. Final ZIP verification and publication are separate recorded gates.

## Final ring star-harness follow-up

No actionable topology or assembly-instruction finding in the revised wiring,
ring assembly guide, manufacturing guide, shopping list, combined BOM and final
review/system-review prose. Independently reread native and netlist J1/J2/J6/D1
contracts; all agree. The CSV retains twelve rows and seven fields per row.

- Console J6 cavities 1/2 remain empty; only pins 3/4 carry the UART link.
- Ring J1 pins 1/2 receive controller power/return from their own local-star
  branch; pins 3/4 retain the console link. The positive feed powers AHCT VCC
  directly and XIAO VBUS through D1, preserving the original circuit.
- Strip supply/return connect directly to the same local split. Ring J2 carries
  DIN on pin 3 only, with pins 1/2/4 and J3/J4 unconnected. No LED-current return
  is added through the carrier or the console link. Grounds remain common at AUX.
- The 600 mm one-way, 16 AWG trunk and separate 50 mm, 22 AWG branches are
  consistent across the assembly/purchasing instructions. The 16 AWG trunk is
  not forced into XH contacts. DIN is limited to 100 mm beside local ground leads.
- Ring USB service still requires removing all of J1 first, disconnecting AUX
  and both UART conductors. D1 blocks USB VBUS from feeding the external AUX
  supply. The only remaining J2 conductor terminates at strip DIN, not its
  supply or return. Console USB isolation instructions remain explicit.

The stated 4.632 V strip and 4.620 V AHCT figures are calculated lower bounds
conditional on 4.75 V at loaded AUX posts and the specified temperature, contact
and wire assumptions. Their numerical proof belongs to the separate voltage
review. The buck's regulation floor remains unspecified by its manufacturer;
these instructions make no measured-voltage or physical-qualification claim.
This harness correction needs no additional native copper/placement change.

### Final trunk-length correction

The selected documents now consistently specify a maximum 600 mm one-way
16 AWG copper trunk, retaining the separate maximum 50 mm 22 AWG branches.
This supersedes the initial 400 mm/18 AWG proposal and provides routing slack.
The connector cavities, branch topology, DIN length and USB service isolation
are unchanged. The shopping list and BOM agree with the assembly guide.
No actionable topology or assembly-instruction finding arises from this delta.
The exact recalculated voltage proof remains the independent thermal review's
responsibility; this follow-up introduces no new numerical margin or physical
qualification claim.
