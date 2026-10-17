# MIDI controls adversarial review

Date: 2026-10-01. Base: `1ef7fb30abd328b86ac481ec71e72c9bbc59e83c`.

**Result:** 48 independent pure-package probes and 18 independent runtime probes
passed on their bound candidates. A deliberately broken timestamp adapter made
the prepared freshness probe fail as expected. No candidate defect remained in
the exercised scope. These results are bounded behavioral evidence, not a
complete MIDI review or an exact-final-head clean gate.

## Independence and revision boundary

Expected behavior was recorded before execution from the accepted behavior
handoff, September 7 MIDI controls design, September 8 mapping parity correction,
and September 9 optional-controls design. Literal vectors and later scenario
addenda were preserved. Author test results did not establish expectations.
Source-review findings supplied additional scenarios to challenge; the accepted
contract supplied their expected outcomes.

The pure suite used the second pure-model freeze. The runtime suite used the
first runtime freeze and the 130-path candidate manifest. All 138 bound pure-run
files and all 1,292 bound runtime-run files remained unchanged during their
respective executions. The runtime candidate manifest still matched at the end
of that run. Native acceptance used the frozen pumped engine library without
rebuilding it.

The later R11 close-drain repair is outside these execution bindings. The
coordinator reported separate regression evidence that fails on the old path and
passes on the repaired path, with independent source review. This report does
not attribute that proof to these 18 probes or claim they were rerun after R11.

## Pure-package coverage

The 48 probes exercised the actual decoder, immutable models and two-phase
mapping engine. The harness supplied explicit accepted/rejected row decisions
through the public settlement API; this part does not prove native admission.

- Standard Note, CC and repeated Program input; CC14 value 8193; NRPN parameter
  259/value 8199; Bank 260/Program 8; relative values
  `0, 1, 63, 64, 65, 127` yielding `0, +1, +63, -64, -63, -1`.
- Reversed CC14 halves, 99/100/101 ms freshness boundaries, separation by device,
  channel and controller, and reset of partial data. NRPN null/RPN cancellation
  and completed-bank retention followed by incomplete replacement selection.
- Disabled and Omni source conflicts, ten cross-format footprint pairs, and
  permitted distinct NRPN/bank identities. Malformed whole-payload rejection,
  constructor validation and detached, immutable caller collections.
- Refused and partially accepted rows, independent pickup, toggle refusal,
  authored Released values, Omni last-contact release, retained cleanup,
  accepted repress superseding old cleanup, rejected repress retaining the old
  obligation, and mapping-generation replacement.

## Runtime and persistence coverage

The 18 probes used real `ControlCubit`, `LooperRepository`, mix coordination,
settings and pumped native receipts. MIDI port delivery was simulated. A
refusal-only engine override rejected selected requests; it never simulated
successful native acceptance. Delayed storage used a controlled in-memory store.

The principal values deliberately differed: prior `.47`, Held `.8`, Released
`.2`, and competing writer `.6`.

| Scenario | Observed result |
| --- | --- |
| Save while momentary FX is held | Audio remains `.8`; boot settings and session projection contain `.2`. |
| Actual named-session save | `SessionCubit` and `SessionRepository` write and read a session file containing `.2` for held FX and track level. |
| Refused press / refused release | Refused press preserves `.47`; refused release preserves audible `.8` and durable `.2`. |
| External overlap, FX and track level | External `.6` wins; its release restores MIDI audible `.8` with durable `.2`. |
| Ordinary `LooperBloc` edits | Unrelated edits preserve the hold projection; same-valued explicit `.8` becomes durable; newer `.6` survives older MIDI release. |
| Admitted FX awaiting callback | Save waits for the real receipt, then stores `.2`. |
| Accepted Mixer Reset | Unity survives older MIDI release in live and durable state. |
| Queued volume across session replacement | An old MIDI write does not alter replacement-session `.6`. |
| Toggle retirement and reconnect | Last audible `.8` remains; older External `.6` is not restored and reconnect does not replay input. |
| Delayed monitor metadata save | Release settles `.2` while storage waits; resumed save writes `.2`, not a retained Held snapshot. |
| Built-in momentary B1 | Captured `true` is restored over intervening UI `false`; later MIDI cleanup cannot erase that fresh ordinary restore. |
| Disconnect | Momentary value returns to authored `.2`; reconnect waits for fresh input. |
| Shutdown completion | Public asynchronous track saves join the storage barrier. Actual `PowerOffCubit`, with the application-shaped Monitor/Control/Looper flush chain, waits for pending mapping and FX writes before goodbye and the observed halt callback. |

B1 intentionally differs from External authored Held/Released arbitration:
accepted built-in release restores its captured prior activation even after an
intervening writer. Numeric MIDI momentary cleanup uses authored Released, not
borrowed prior `.47`.

## Failure sensitivity

The ordinary capture-time probes rejected halves physically 101 ms apart even
when queued delivery brought them together, and accepted a 99 ms pair despite a
200 ms processing delay.

The isolated negative control erased timestamps only in the private port
adapter. The same stale full-scale pair then changed the target from the
expected External `.6` to `.8`. The assertion failed with those exact values.
Product source, the oracle and the native library were unchanged. This proves
that the freshness probe detects the targeted loss of capture-time spacing.

## Preserved initial failures

| Attempt | Result and disposition |
| --- | --- |
| Pure 01 | 47 passed; one harness assertion wrongly required another bank pair before a repeated Program message. The original pre-run oracle explicitly retains a completed bank. The fixture was corrected to that unchanged oracle. |
| Pure 02 | 48 passed. |
| Runtime 01 | Compilation stopped at a missing `InteractionMode` import; no behavioral probe ran. The import was added. |
| Runtime 02 | 17 passed; the monitor fixture read an obsolete storage key. It was changed to the public `loadMonitorEffects` getter; expected `.2` was unchanged. |
| Runtime 03 | 18 passed. |
| Timestamp negative control | One expected failure: `.8` observed instead of `.6`. |

Original fixtures, logs, corrections and before/after manifests were retained in
the private evidence bundle. None of these fixture failures was reported as a
candidate defect. No product or author-test file was edited by this reviewer.

## Evidence identifiers

These SHA-256 identifiers locate the retained evidence without publishing local
machine paths.

| Artifact | SHA-256 |
| --- | --- |
| Acceptance oracle v1 | `6786535a0a226d9f18512c5a326f2b3f4ad5eb27a8bd9c52f045eab27ecd870c` |
| Pure execution report v2 | `486fa079c393ffde1d41191f6091b135de5bd093eee0b077e4b1a1f0d53a6100` |
| Runtime execution report v1 | `828a827d46f943d646c52155d966bf21dab49da5d397728c627356e092a5557b` |
| Runtime candidate manifest v1 | `7acc053716836b0ecb2682edd163e4319ed5be729f3aeda23583fdbab309f224` |
| Final runtime harness | `d60d2d6153a9506ff5ca5fb0eeee23d07a88b1bf0b4c56e661a1720b38e549c8` |
| Frozen native test library | `31ebe531d01e3eb85297b1785e0f3cdf05b9f04134f277dd2b5bb97ef2bb80a8` |

## Explicit limits

- No physical MIDI interoperability, native callback timestamp forwarding,
  callback disposal stress, electrical behavior, power-loss durability or actual
  operating-system shutdown was exercised. The halt callback was an observation.
- Shutdown covered the application-shaped completion chain, not the complete
  App widget composition or every flush-error branch. Existing halt-on-error
  policy was not changed.
- Refused Reset, captured-false/refused B1 restoration, and continuous retirement
  as a separate neighbor of toggle retirement were not exercised here.
- Refused release retention was exercised, but subsequent successful native
  retry after renewed eligibility was not repeated in this runtime suite.
- The queued-session case checked live/durable snapshots, not separate stored
  bytes after replacement. The named-session case independently checked an
  actual file; its track-level setup used the public coordinator MIDI seam.
- Native grouped writes to the same owner, all FX owner stages, complete Learn/editor
  and configuration-save fault matrices, and native queued-port epochs remain
  outside this runtime sample. Full NRPN/Bank timing permutations were omitted.
- Some malformed JSON null-field vectors also reused a mapping ID. They prove
  whole-payload rejection, not the isolated rejection reason for each field.
- Aggregate checks, native platform gates, UI review, the five-role source
  review, R11 delta verification and final-head CI are separate evidence.
