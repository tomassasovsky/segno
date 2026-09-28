# Removable USB shield connections — Revision O

Issue #1072; PR #1080. The owner approved this change on September 28, 2026.
Baseline: `add2748edce2c274e931e7fc3c524d1695d1ea2c` (Revision N).

The current four-pin USB plugs leave each cable's shield soldered to a separate
PCB pad. Replace J101/J102/J201/J202 with five-pin JST XH headers and mating
XHP-5 housings so one plug disconnects every conductor, including the shield.
Pins 1–4 retain VBUS, D−, D+ and GND. Pin 5 terminates the shield to PCB GND.
Remove the four obsolete drain pads. Suitable donor USB cables retain their
factory USB ends, shield and twisted data pair; select crimp contacts to match
the actual conductors and insulation. Main-power VH plugs remain unchanged.

## Work and acceptance

1. Use Claude when available for placement/routing changes and synchronized circuit,
   schematic, footprint, model and generator changes. Resolve the longer
   headers' nearby clearances while retaining the 68 × 76 mm two-layer board,
   rounded copper, hand-soldered assembly and existing power circuit.
2. Update native validation and fault controls for five numbered contacts,
   explicit grounded shield contacts and removal of the separate solder pads.
   Retain USB pair width/gap, length, layer, clearance and filled-plane checks;
   do not substitute stale Revision N geometry assertions for new validation.
3. Update the active wiring/BOM/shopping instructions. Remove the superseded
   four-pin donor requirement and independently verify the new JST parts.
4. Run native ERC/DRC, circuit/assembly/source checks, applicable fault tests,
   regenerated fabrication comparisons and copper-loss checks where changed
   geometry affects their result. Inspect populated top/bottom renders.
5. Independently review the change, fix verified findings, and regenerate the
   manufacturing ZIP, manifest and dated delivery folder from final sources.
   Bind unchanged console/ring evidence to exact hashes. Mark previous screen
   archives superseded, without claiming their earlier reviews approve Rev O.
6. Commit, push and update the existing PR and issue within established
   authority. No order, merge, flashing or device deployment is authorized.

Bare-board design review remains separate from assembled USB compliance,
shutdown timing, donor-cable suitability and enclosed-system qualification.

Claude authored the connector conversion and initial placement/routing repairs,
then reached its usage limit. Finish the remaining measured repairs with KiCad
within the owner’s existing “if available” preference; record independent review
coverage separately from authorship.
