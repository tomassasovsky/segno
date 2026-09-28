<!-- cspell:words DeepSeek opencode AHCT RP2350 H11L1 Neutrik GPIO -->
# DeepSeek adversarial review: console board

**Verdict: clean with the documented operating bounds. No confirmed console
circuit, netlist, BOM, pin-map or critical route defect remains.**

This is a completed external, read-only adversarial review using
`opencode-go/deepseek-v4-flash`. The reviewer had file read/search and web-fetch
access, with shell execution and writes denied. It inspected the actual circuit,
netlist, BOM, native-derived geometry and evidence rather than only a component
proposal. Initial claims were checked against the design and primary sources;
incorrect findings were returned to the reviewer for correction.

The circuit/native baseline is commit
`44edd9483518768506533a3b6fe30e85d6d530c4`. Manufacturing and programming prose
was corrected during the review; the native board bytes remained unchanged.
The conclusion is a bounded paper review, not measured thermal behavior, USB
certification, assembled-device qualification or a guarantee against all faults.

Board SHA-256:
`c23df586f211bb439081ca951dd23dc54ba21f6d89eb3d373bd6f196749f326d`.

## Observed coverage

- Complete console generator, native pad map, BOM, placement/routing generator
  and netlist. The initially unread netlist tail was read in the final pass;
  all 54 nets were reconciled against source and native pads.
- All 1,514 targeted native track/arc/via records covering power rails,
  GPIO17, pill data, MIDI, Pi/ring UART links and the PD interface. Remaining
  low-rate control geometry is covered by the full pad map, routing summary,
  source and DRC; it was not individually reviewed segment by segment.
- Actual filled-zone extraction at J3/J24, the measurement script and its
  results; the reviewer read the extraction source as well as its summary.
- Current manufacturing, wiring and programming instructions; fabrication
  parity records and the unchanged console release hash.
- Primary text for the exact AHCT125, H11L1 family, relevant RP2350 electrical
  limits and E9 erratum, Pico 2 and JST XH/VH. The final pass completed the
  truncated RP2350 extract. It read the available Neutrik drawing and
  SparkFun schematic text, but text alone does not reveal their wiring diagrams.

## Findings and adjudication

| Initial claim | Verified outcome |
| --- | --- |
| Thermal spokes support only about 4.2 A at a 10 C rise | Retracted: the reviewer had omitted a factor in its own IPC-2221 arithmetic. Its stated 0.336 square-mm area gives 12.33 A under that equation, not 4.2 A. Actual native filled copper was checked before withdrawing the claim. |
| The screen relay's 2.4 mV pickup comparison proves unreliable hold | Retracted. The later claim of unambiguous hot holding was also withdrawn. No guaranteed hot holding threshold follows from the minimum-release specification. |
| A long pill data route or an incorrectly wired GPIO17 cable necessarily demonstrates a PCB defect | Neither failure was established. EMI and incorrect-wiring fault tolerance remain limits, not fabricated test failures. |

At the thermal annulus, native copper gives about 4.80–4.96 mm aggregate
+5 V spoke width per layer and about 3.69–3.72 mm at J24 ground. This rejects
the original undersized-spoke allegation. Circumferential slice lengths and
IPC-2221 arithmetic are **not** a temperature solver or proof that current
shares equally between every spoke. No enclosed-temperature measurement is
claimed.

The selected ring's 2.44 A LED branch bypasses the console and ring carrier
power route. Ring J1 supplies only the separately allocated controller load;
the reviewer's final shorthand about XH supporting a combined 2.64 A does not
change the selected direct-AUX harness.

The final relay conclusion remains the screen report's bounded conclusion:
45.5 mV estimated pickup margin before contact make; 2.4 mV loaded comparison
to the modeled hot pickup line; no manufacturer-guaranteed hot holding limit.
An inferred likely behavior is not substituted for that missing guarantee.

## Limits and distributed coverage

DeepSeek did not visually establish the Neutrik terminal-view mapping or the
SparkFun PD module's internal pull-up topology. Those diagrams are explicitly
assigned to separate Claude/Codex visual-primary review. No native KiCad GUI,
raster inspection, laboratory protocol test or actual assembly was used here.

The standing MIDI break with Pi off/AUX on and the Pico USB programming
back-feed precaution are documented behaviors, not newly discovered normal
operation faults. The runtime is the separately published v3 integration
work; the hardware branch's firmware snapshot is not treated as its deployment.
The bare-board review does not establish relay endurance, actual shutdown
latency, full-system temperature, EMC, cable assembly correctness or USB
compliance.
