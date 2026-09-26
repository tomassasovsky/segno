<!-- cspell:words findall SKiDL pcbnew VBUS MOSFET MOSFETs TN0702 BS170 IM02TS pulldown -->

# Test Quality Review: Revision M source checks

## Scope and result

Reviewed the uncommitted circuit/checker change against `355882d8`, principally
`hardware/kicad/screen_power/switch_circuit.py` and `check.py`, with the existing
`circuit.py`, `build.sh`, netlist parser and validation entrypoint as context.
The separately authored cable assessment was excluded. No production source,
board, schematic or fabrication output was modified for this review.

**Unresolved: Critical 0, Important 0, Suggestion 0.** The nominal source
checks and new fault controls pass. The malformed-tolerance acceptance
finding below was reproduced, corrected and independently verified.
This review does not approve the final native layout or fabrication package.

Final reviewed source SHA-256 after the tolerance correction:

| File under `hardware/kicad/screen_power/` | SHA-256 |
| --- | --- |
| `check.py` | `c7f09c4dc5df279cbf89780729f0cec15987fda8109aa0d770b8c3a7cb32f747` |
| `switch_circuit.py` | `652502f1006b5019752c874b08ff431b5e8bc24cea1dcbf52d50cc513fd23a7e` |
| `build.sh` | `58c506aaf72675b578f0ad8d7f533877cd2e77b72d9adecd32742643637a6424` |

The source hashes were unchanged before and after the independent check run.

## Runner and coverage

This is Python/SKiDL circuit generation followed by KiCad's native Python and
CLI checks. The repository's `build.sh` runs circuit generation, placement,
critical routing, remaining routing, finishing and `check.py --self-test`
before export. The validator checks native pad/netlist parity, independent
pin contracts, numerical limits and fresh ERC/DRC results; failures prevent
`cad_ready`. Its mandatory self-test list now includes the 13 new USB power
results, the new legacy-tolerance regression and 61 retained controls: 75
mandatory results after the native board is regenerated.

For this source review, copies of the two circuit source files were generated
in a disposable directory using the configured SKiDL environment. The fresh
netlist then passed the production contract, numerical and state functions
under KiCad Python. SKiDL ERC reported zero errors and zero warnings. Netlist
generation separately printed six environment/tag warnings; those are not
being represented as a warning-free full build.

Observed results:

- Fresh nominal netlist: no contract, numerical or state errors.
- New mandatory USB controls after correction: **13/13 pass**, including the clean baseline.
- State model: **48 combinations / 96 coil paths**, including each host
  independently, AUX, GPIO high/low/floating and suspend.
- Additional independent mutations: **26/26 rejected** at the expected gate,
  repeating faults on both channels and adding the host-only gate bypass,
  reversed flyback diode and wrong upper-driver model.
- Original tolerance probes: `10k 11%` and `10k 91%` were incorrectly accepted.
  After correction, both fail `usb_sense_components`; `10k 1%` still passes.
- Independent legacy-gate probes: R3 with `11%`, `91%` or conflicting `1% 11%`
  fails `resistor_model`; the original `4.7k 1%` baseline still passes.

The project does not configure line/branch coverage for this CAD gate.
Mutation results are reported directly rather than inventing a coverage
percentage or imposing unrelated Dart/Flutter coverage rules. Full native
75-control validation has not been run here because the revised board has
not yet been generated; the old native board is not a meaningful baseline
for these new components.

## What the tests establish

The new model is materially stronger than a copied Boolean AND expression.
It builds directed paths from the actual MOSFET S/G/D pin nets and includes
source-to-drain body diodes. Both reversed upper and lower FETs fail the
state gate independently of the fixed pin table. Crossed host sensing and
GPIO-only bypass also fail that behavior model. Mutation results require a
clean baseline and a named intended error category, preventing unrelated
contract errors from substituting for those behavioral detections.

The numerical gate separately checks host-current bounds, divider drive,
host-absent gate bias, initial coil pickup and component identity. The
existing relay-contact graph verifies normally open data contacts and
channel/polarity separation. Native parity and DRC remain separate gates;
source truth-table success does not stand in for them.

The model intentionally does not solve analog transient behavior. It assigns
DATA_ENABLE according to the separately checked buffer contract and uses
the bounded gate-drive calculation for conduction. Suspend duplicates the
static retained-VBUS state by design: the relay is allowed to remain powered
from AUX, while host current is constrained numerically. The 5 Ω hot-driver
and 1 µA leakage allowances are labeled estimates. Warm restart, actual
cable construction, USB signal integrity and assembled operation are not
proved by these source tests.

## Resolved finding and regression evidence

- Original severity: **Important**; status: **resolved**
- Rule: **exact-tolerance-validation**
- Title: **Match the complete resistor tolerance token**
- Location: `hardware/kicad/screen_power/check.py:587–589`; the same existing
  substring pattern appeared in the control-resistor gate at lines 688–690.
- Why: The expression `"1%" in value` accepts `11%` and `91%`, while every
  resulting margin still assumes ±1%. In the original reviewed revision, with only R101's value changed to
  `10k 91%`, the complete source-level contract/numerical/state inspection
  returned no errors. At that stated tolerance the series resistor can be
  900 Ω, so the grounded-sense-node bound at 5.5 V is 6.11 mA instead of the
  reported 0.556 mA, exceeding the gate's 2.5 mA criterion. The selected
  production 1% parts are correct; this is false acceptance of a changed
  specification, not a finding that those parts are wrong. The existing
  `20%` mutation does not exercise the substring collision.
- Fix: Parse or match `1%` as an exact tolerance token for both gates, and
  retain a suffix-collision regression such as `11%` alongside the passing
  `1%` baseline. Require the new USB tolerance mutation to fail
  `usb_sense_components` rather than merely producing any unrelated error.
- Resolution: both gates now require `re.findall(r"[\d.]+%", value) == ["1%"]`.
  `presence_tolerance_suffix_detected` mutates R101 to `10k 91%` and requires
  `usb_sense_components`; `wrong_tolerance_suffix_detected` mutates R3 to
  `4.7k 11%` and is required by the full suite. The independent rerun confirmed
  the original failing cases now fail their intended gates with a clean
  baseline, 13/13 USB controls and 26/26 other mutations still passing.
  Original discovery used checker SHA-256
  `fe34381a9c40925678e8442c03e7c2f7072cd3773eaa026fed49c02d9c8c4f83`.

## Verdict

The tolerance finding is resolved with focused positive/negative evidence.
The reviewed source tests meet the behavioral quality bar within
their explicit ideal-model limits. A fresh native build, the complete
mandatory-control run and refreshed manufacturing verification remain
required after placement/routing; this report makes no final hardware or
manufacturing-readiness claim.
