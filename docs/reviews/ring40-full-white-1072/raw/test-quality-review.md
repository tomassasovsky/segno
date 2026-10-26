# Test Quality Review

## Scope and coverage summary

Review base: `f8d6f889ba51bf1a8cb5e29b6f00fd852465ee2d`. Reviewed the working-tree
PCB delta, including both new helpers, the width-preservation change, both route
scripts, generator integrations, final console implementation brief and actual
saved console/ring boards. This is a PCB review; firmware and application tests
were deliberately outside scope. No implementation or board was edited by this
reviewer.

- Test run: **Pass**.
- Test stack: Python embedded self-tests, KiCad 10.0.4 `pcbnew`, native KiCad DRC,
  routed-board fabrication/netlist guards and shell routing recipes. SKiDL is
  pinned at 2.3.0 for netlist generation.
- Coverage: no PCB coverage percentage or threshold is configured. Flutter
  coverage thresholds do not apply to these scripts. The PCB tests are local
  checks, not an existing GitHub CI job; this report does not claim CI executed
  them.
- New/changed critical helper units with behavioral checks: **3/3**
  (`ring_power.py`, `console_ring_power.py`, `widen_power.py`). These use embedded
  test entrypoints rather than separate test files.
- Missing test files: none required for the reviewed delta under the established
  embedded-test approach.

## Observed checks

| Check | Result |
| --- | --- |
| `python3 hardware/kicad/widen_power.py --selftest` | Pass, zero failed checks |
| Ring helper `--self-test` on the actual saved board | Pass, positive board plus seven rejected faults |
| Console helper `--self-test` on the final saved board | Pass, positive board plus seven rejected faults |
| Both route scripts, `bash -n` | Pass |
| Six changed/new Python sources, in-memory compilation | Pass |
| Ring native full-severity DRC | Zero violations, zero unconnected items |
| Final console native full-severity DRC | Zero violations, zero unconnected items |
| Console `--check-routed` | Pass, including fabrication floors and actual-pad/netlist parity |
| Reintroduced old width-shrinking logic in memory | New mixed-width regression correctly fails |
| Injected export DRC exit status 5 | Export raises before deleting or writing manufacturing output |

The final console helper, generator and board hashes below match the completed
console implementation brief. The subsequent ring track/via locks and stricter
all-severity DRC gate were also reviewed; the ring fault suite and DRC passed
again on that final board. Its fault suite and native DRC were repeated on
that revision, after the locked-route and export failure handling changes.

## Test quality

### Ring guard

The positive path inspects KiCad board objects: actual power-pad nets, a graph of
front-copper segments of at least 1.5 mm joining J1 to J2, and three qualifying
through-hole ground barrels inside the J2 wire pad. It also checks the recorded
outer-copper thickness. This is not a source-text assertion that the generator
contains a width constant.

Each fault starts with a fresh load of the real board. Removed, narrowed and
wrong-layer supply segments, a wrong supply pad net, a removed return barrel,
a wrong return-via net and thinner recorded copper all produce the expected
power/return rejection. Requiring the expected assertion prefix avoids accepting
an unrelated exception as a successful negative test.

### Console guard

The positive path checks actual endpoints, nets, layers and widths of the
critical route; the four parallel power vias and their drills; the filled
input copper bar at the route origin on both sides; and the ground thermal overrides.
Faults cover an open/narrowed/wrong-net supply, a missing/small-drill transition
via, a weak J6 return thermal and a moved J6 anchor. The shared route specification
is used to install and check intentional geometry, while the tests modify the
loaded copper independently; they do not merely compare the specification with
itself.

Native DRC and the existing netlist-parity guard complement these current-path
checks. Neither the helper nor DRC alone is treated as proof of every possible
return-plane bottleneck or of assembled temperature. Source geometry, actual
filled copper and the independent hardware review remain part of acceptance.

### Width helper and export failures

The mixed-width fixture passes a real temporary KiCad text board through
`widen()`, reads the written result, and checks that its narrower branch grows
to 0.65 mm while its existing 1.5 mm branch stays intact. Restoring the previous
`set_width` condition in memory makes this fixture fail with only `[0.65]` left.
The regression therefore detects the actual safety-relevant failure.

Existing cases retain meaningful same/opposite-layer clearance, insufficient
headroom, target capping, pad shape/orientation, edge-clearance and current-capacity
coverage. The export failure probe used the real `export()` entrypoint and
routed-board check; only the external DRC result and destructive output deletion
were intercepted. A failed DRC prevented all output deletion/export calls.

## Current-budget and manufacturing boundaries

The reviewed design reserves 2.4 A for 40 unrestricted RGB-white LED channels,
40 mA for pixel idle and 0.2 A for the ring controller/buffer. Its 2.64 A console
feed model is independent of the firmware brightness cap. Independently
re-evaluating the repository's IPC-2221 formula gives:

- Carrier 1.5 mm nominal, 1.2 mm after 20% width loss: **2.7296 A** at the modeled
  10 degree C rise on 1 oz external copper.
- Console 1.7 mm nominal, 1.36 mm after 20% width loss: **2.9889 A** under the same
  model.

These are design-model values, not measurements or universal guarantees. Both
physical return routing and the selected via/plating, connector, harness and
copper specifications must remain in the manufacturing verification. DRC verifies
geometric rules/connectivity; it does not calculate current capacity.

Both routing flows run the applicable critical-path guard before fabrication
export. The final archive/source hashes and Gerber/drill correspondence belong to
the parent publication verification; they were not inferred from the presence of
an existing ZIP. No assembled-board temperature, voltage drop, screen startup or
buck transient measurement was performed by this review. This does not remove
the established physical-validation gate or authorize unrestricted full-white
operation of all 80 pill LEDs plus the ring and screens on the 10 A supply.

## Anti-patterns and findings

No actionable test-quality findings. Tests exercise actual saved copper and
observable output; deliberate faults verify that the safeguards reject relevant
failures. No production fix was applied during review.

## Reviewed source hashes

SHA-256 snapshots allow the parent to identify later changes requiring review.

| Repository path | SHA-256 |
| --- | --- |
| `hardware/kicad/ring_power.py` | `4797431861cb60def77ed9776fc59f6d4551aa7a367500363535a9f23e255ac8` |
| `hardware/kicad/console_ring_power.py` | `374c784bf025ccd26b604b6d63040cb4eed4e93da85ed32576b51f84259993b2` |
| `hardware/kicad/widen_power.py` | `123a9a1099380560383a2e998982be635e508b6bd4642ab68096e675e35ba612` |
| `hardware/kicad/console_board_pcb.py` | `f70d3b4154fdc88ab89f68a2a0c3ea13b88af1e67d0b19e3c9d7a05d8f1bc94c` |
| `hardware/kicad/console_board.py` | `6d5a60e679292bb18959cee76e5d6e6a0da4b1c722737e3351b92c08700a2176` |
| `hardware/kicad/ring_board.py` | `ccffc72aec110fffb18a20e2158b11a27a45e1d3ddceacc6b2e3c5cc30c30260` |
| `hardware/kicad/route_ring_board.sh` | `64ab902f3adf6d19ec1afbe0d81c47195054ec80ef5e24e71560184b8b06ffd3` |
| `hardware/kicad/route_console_board.sh` | `457e0b61f68f799625e6046a8f612c14db0d9174749a03ef4f78a196d614d8e2` |
| `hardware/kicad/segno_pedal_ring.kicad_pcb` | `c14247f8c6ecf4498af8158de2b28fd5a9f19a3dc75e795a232f1a032a9c7be1` |
| `hardware/kicad/out_console/segno_console_board.kicad_pcb` | `9b9854170d005b1721c22a0b0e70114da0d0ab5ff08946c4cbfc255fc76b46c0` |

## Verdict

The reviewed PCB delta passes the test-quality gate with zero unresolved
findings. Manufacturing archive matching and physical assembly validation remain
explicit separate gates, as described above.
