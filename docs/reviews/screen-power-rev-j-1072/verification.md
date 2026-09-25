> Superseded by [Revision K](../screen-power-rev-k-1072/verification.md). This record describes the earlier checked package.

<!-- cspell:words centerlines heatsinks -->
# Screen-power Revision J verification — 25 September 2026

**Revision I screen-power Gerbers are withdrawn.** Revision J corrects a relay
contact error and strengthens the existing shared-power copper. It retains the
68 × 76 mm, two-layer, 1 oz, 1.6 mm hand-soldered board, purple mask, white
silkscreen, ENIG finish, 37 populated parts, four mounting holes and all component
positions. Console and ring designs and their full-white exports are unchanged.

Issue: [#1072](https://github.com/tomassasovsky/segno/issues/1072).
PR: [#1080](https://github.com/tomassasovsky/segno/pull/1080), stacked on #1066.
Correction baseline: `e98256a5a36f5341b9a521d63b6b951ca2b67f70`.

## Relay fault and correction

The manufacturer’s IM-series terminal diagram gives coil 1+/8−, commons 3/6,
normally closed contacts 2/7, and normally open contacts 4/5. Revision I put the
host data on 2/7 and the screen data on 4/5, leaving both commons floating. No
relay state could pass USB data. The generated schematic and board agreed with
each other, so clean ERC/DRC and a checker repeating the same wrong pin map did
not detect the electrical error. The [original failure record](../screen-power-claude-1072/relay-failure-baseline.json)
reproduces it. Source: [TE IM-series manufacturer datasheet, terminal diagram](https://www.farnell.com/datasheets/477186.pdf).

Revision J connects host D−/D+ to 3/6 and screen D−/D+ to 4/5, leaving 2/7 unused.
An independent contact-mechanism graph now tests all four combinations of the
two coils and all 16 upstream reachability cases from the actual netlist. It
checks correct polarity and channel isolation, including the state with only
one host supply present. Regressions restore the original error, select the
wrong throw, swap polarity and join channels. No-connect terminals remain
separate graph vertices. Native schematic/netlist/board parity remains required.

## Power layout and heatsinks

- The short MOSFET power necks are 1.9 mm, up from 1.5 mm; the existing shared
  trunk remains 4.5 mm, with 3 mm intermediate connections and 2 mm main branches.
- C2 has an explicit 1.5 mm input branch in place of its signal-width feed.
- Three dedicated 0.45 mm drilled through vias provide another path between
  the rear feeder and front distribution copper. The original fuse plated
  barrel remains a parallel connection. Validation removes that barrel and
  narrow tracks from a disposable board to prove the via path still connects.
- Both USB pairs remain on the rear layer with no data vias, equal lengths
  within each pair and filled front-ground reference. Rounded keepout ends
  allow the narrow relay-drive return between the corrected contact columns.
  The actual front-ground coverage is checked along both data-trace edges
  and centerlines; this is not a USB compliance measurement.

Q3/Q4 stay upright. No specific optional heatsink is mechanically validated;
this is designed for the expected screen load without one. At a conservative
3.25–4.25 A combined-load estimate, using an assumed 60 °C local ambient,
75 °C/W junction-to-ambient resistance and temperature-adjusted on-resistance,
the estimate is roughly 0.20–0.36 W and 75–87 °C junction temperature per FET.
At the 6 A shared design ceiling, the same model gives about 0.81 W and 121 °C
per FET. These are engineering estimates, not measured assembled temperatures
or a qualified current rating. Source parameters and assumptions are recorded
in the [screen-board notes](../../../hardware/kicad/screen_power/README.md) and
[Vishay datasheet](https://www.vishay.com/docs/77632/sup70101el.pdf).

The 6 A shared allowance includes both main outputs, both touch outputs and
the approximately 0.05 A bleeder. Individual 3 A main and 0.5 A touch ceilings
are not additive simultaneous guarantees. The 40-pixel ring takes a separate
power path and does not heat Q3/Q4. The two exposed FET tabs carry different
live drain nets: do not join them with an uninsulated shared heatsink.

## Review provenance and scope

The requested independent review was performed by the installed Claude Code
agent, recorded as `claude-opus-5`. Its [original report](../screen-power-claude-1072/original-rev-i-review.md)
is preserved with a separate [assessment](../screen-power-claude-1072/assessment.md)
and [provenance](../screen-power-claude-1072/provenance.json). Claude completed
that review and initial circuit/routing edits, then hit its session usage
limit. Codex completed the routing and validation changes. **Claude did not
approve the final Revision J files.** Unsupported unconditional heatsink-fit,
startup/SOA and fuse-clearing claims from its advisory report were not adopted.

Independent Codex architecture, project-convention, test-quality, simplicity
and publication-readiness reviews cover this focused correction. Their raw
reports and resolved findings are linked in [review.md](review.md). The
[bug-focused review](../../code-review/screen-power-rev-j-1072/review.md) covers
the correction from the stated baseline. This is not represented as a fresh
complete review of every earlier change in the large stacked PR.

## Recorded checks

- KiCad 10.0.4 ERC and DRC: zero reported errors, warnings, exclusions or
  unconnected items under the committed project rules. The raw report also
  lists intentionally disabled checks; no new rule suppression was added.
- Final validator: **36/36 regression controls passed**, including the original
  relay pinout and the independently discovered redundant-via-island fault.
  See [validation.json](../../../hardware/kicad/screen_power/validation.json).
- Actual USB copper: all four differential pairs have zero nominal length
  mismatch; each upstream route is 23.357803 mm and each downstream route is
  26.351514 mm. Ground-reference sampling covered 5,452 points.
- Native schematic, generated netlist and final board agree. All 37 populated
  components have models. Component positions, pad geometry, board outline and
  two-layer construction are unchanged from the baseline.
- The final board is revision J and all six schematic sheets identify
  `J prototype`. This also fixes the stale G title in the exported schematic.

## Manufacturing scope

No additional owner measurements are prerequisites for ordering the corrected
bare prototype PCBs. First-assembly checks still include cable continuity,
actual USB operation, mounting and harness fit, supply drop and heating, and
GPIO cutoff before HDMI disappears. Startup safe operating area, fuse
coordination, thermal performance and USB signal integrity are not established
by clean CAD checks. The five-second software discharge wait remains provisional.
No order, device flash, deployment or merge was performed for this correction.

The PR retains `autonomy:blocked-verify`, `ci:pending` and `review:pending`.
The feature-branch base does not trigger the full repository CI; absent checks
are not green. Do not infer merge approval or guaranteed assembled operation
from this first-fabrication package.

## Replacement upload package

Upload [segno_screen_power_rev_j_gerbers.zip](https://github.com/tomassasovsky/segno/blob/9a5798be6c4ea9b0aae2a88fe7168b6751cab441/hardware/kicad/fab/segno_screen_power_rev_j_gerbers.zip).
The archive contains seven Gerber layers, separate plated/non-plated drill files,
two drill-map PDFs and the Gerber job file. Use ENIG, purple mask and white
silkscreen; the board remains two-layer FR4, 1.6 mm, 1 oz. No assembly service
or stencil is required. The old Revision I archive is removed from the current
tracked fabrication folder and quarantined in the owner's local delivery.

- Native board SHA-256: `037d462c64196cca1d697975325be9b979a5360783949ed89c62c441ebef3032`.
- Revision J ZIP SHA-256: `9905da38f648b6d1726805055df89a5082520ff9954127e79b8a4b4746b63c98`.

The independent export audit passed all 358 assertions: 59 source hashes,
64 artifact hashes, all 12 archive members and the stack/layer inventory. A
separate native-board export matched all seven Gerbers, both drill files and
the job JSON after removing creation timestamps only. Drill-map PDFs received
exact archive/manifest identity checks, not independent content/render checks.
Other non-CAM files received manifest checks. The final top render was also
inspected for revision, population and appearance. These checks establish
source-to-manufacturing correspondence, not physical operation.

Exact current upload hashes for all three boards are in
[manufacturing-zips.json](manufacturing-zips.json); compact independent evidence
is in [fabrication-verification.json](fabrication-verification.json). The console
and ring archives retain their previously verified hashes and are unchanged.
