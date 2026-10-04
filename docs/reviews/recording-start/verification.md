# Recording-start pair: verification

Base: `505fbcad19303b78396035c807409ee5a706f132` (shared Hear click).
Scope: part one only, including new untracked source and tests. Shared stopped
launch scheduling and control mappings are separate planned parts.

## Native and independent evidence

The immutable native v2 library fingerprint is
`5ff334200a61b6591aae07ae7429757ca2be848a06566e6fd7da959a87547d86`.
Native source fingerprint is
`ba9094fe29110d3188e6600c5571821cd27d9af23b4867f9294e5f1767cbda2c`.
Full standard, AddressSanitizer, telemetry-disabled and C++ shim checks passed.
FFI bindings were regenerated and explicitly formatted. The complete macOS app also builds, and all 182 looked-up symbols are
exported by its bundled native framework, verified with the unmodified parity
gate and a Mach-O symbol-reader adapter. Linux shipping-library parity remains
an exact-head CI gate. The device-free library deliberately omits MIDI-host
symbols and cannot itself prove a complete shipped bundle.

Independent native probes covered 18 unique groups. The first version exposed
one countdown cancellation defect; the repaired version passed all six affected
groups, including the unchanged reproducer. Three isolated mutations each failed
the intended publication, capture or no-source assertion. These are source-bound
independent results, not a claim that an uninterrupted 18-case run used v2.

Independent Dart execution passed 27 owner cases, one actual Session file case,
and two actual App cases. The actual Session test covers a delayed paired write,
subsequent changed save and refusal to overwrite the old file during recovery.
The first App attempt retained duplicate fixture teardown errors after executing
the behavioral assertions; removing the duplicate ownership cleanup required no
behavioral expectation change. All bound inputs remained unchanged during proof.

## Integration and static checks

The initial isolated full app gate produced 2,669 passes, six skips and 112
failures. Of those, 110 were routing/FX mocks missing the new owner stream; two
were old assertions treating exact compensation as unhealthy owner state.
The latter tests now explicitly verify that Control still blocks shutdown while
it owes a refused pedal release and retains the Held value. Their expected
actual Released values remain unchanged.

The six-suite correction run produced 235 passes and two new Audio Settings
fixture failures. The missing capture-lock projection was supplied; the affected
Audio Settings suite then passed all 22 cases with controls in view and no tap
warnings. The other five suites passed unchanged in the earlier run. The final full app run passes 2,789 cases with six conditional skips and no
failures: 26,826/29,182 covered lines (91.92653%), above the 90% floor, using
only the existing CI coverage exclusions. Its bound inputs have no drift.

Full affected-package gates also pass, with no input drift:

| Package | Passed | Skipped | Covered / total lines | Coverage | Required |
| --- | ---: | ---: | ---: | ---: | ---: |
| Looper | 684 | 12 | 4,477 / 4,712 | 95.01273% | 95% |
| Settings | 188 | 0 | 805 / 886 | 90.85779% | No declared floor |
| Engine | 356 | 0 | 2,029 / 2,864 | 70.84497% | No declared floor |
| Session | 105 | 0 | 837 / 874 | 95.76659% | 89% |
| Performance | 129 | 0 | 593 / 597 | 99.32998% | 99% |

Engine uses immutable native v2. Looper skips its existing native-dependent
cases in the ordinary package run. Native-backed Session/timing integration
separately passes all 32 cases without conditional skips.

The complete formatter, fatal-info analyzer and Bloc checks passed across 763
Dart files. The final six changed test files separately pass formatting,
fatal-info analysis and an actual six-file Bloc scan with zero issues. No
coverage threshold or test exclusion was added to product configuration.

## Visual evidence and limits

Five native author captures are saved under
[`docs/design/native-record-start`](../../design/native-record-start/).
The Pen Recording start and Count-in section places those Recording and Tempo states in the current
native implementation group. Its saved composite was visually checked: aligned
screens, readable labels and no clipped or blank image. All 504 preceding
canvas nodes were structurally preserved. Saved design fingerprint:
`4ebc437bb584a1d16d76987f7a4027f41d102edd19571ec8a4973f1b447d1bb1`.

Author captures are separate from CI and native desktop interaction. The local
ordinary app gate excludes the author-only screenshots tag; Linux CI normally
self-skips those cases because author fonts are absent. This does not claim
that unrelated historic screenshot goldens are current. Actual appliance audio,
physical controls and power-loss behavior require their own device evidence.
A native desktop build bound to the tested source was opened and exercised.
Count-in 2 updates Recording to its two-bar explanation; Sound switches to its
waiting explanation and updates the hub; Count-in 4 returns to Pedal with the
four-bar explanation. Off returns to immediate Pedal start. No application
exception appeared during those interactions. This is UI/integration evidence,
not physical capture or appliance timing proof. Flutter automatically updates
the macOS development minimum to 12.0 while building; that generated host-only
change is kept outside this feature diff. Published-head CI and human merge
remain open.
