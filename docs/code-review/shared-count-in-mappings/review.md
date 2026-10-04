# Shared Count-in mappings review (#1121)

Base: `659792cafed98f341b208f42353a12b0f2b29e4c` (PR #1120).
This slice connects the existing recording-start owner to external buttons,
expression and MIDI. It adds no native API or second command interpreter.
Count-in and Sound remain one accepted pair. Temporary Held values affect the
live engine; Released values are saved in preferences and session files and used
after restart. An accepted ordinary edit supersedes older holders, including a
Sound edit that leaves the numeric Count-in unchanged.

The named endpoint editor replaces the former click-only editor. The same
component serves Hear click and Count-in; the obsolete component is removed.
Five identical claim-retirement methods are replaced by their shared operation.
Presentation continues to use the existing owners and control catalogue.

Focused author checks passed 279 tests, 208 runtime and neighboring control
tests, and 728 repository tests. Four author screenshot cases rendered and
passed against reviewed baselines: three Count-in states and the unchanged
Hear click state. The initial attempt without fonts skipped its screenshots and is
not visual evidence. Native code and bindings match the verified base; native
results are reused rather than rerun against unchanged inputs.

The first aggregate run exposed seven failures in three older presentation
fixtures. Their repository mocks omitted the new Released-pair argument and
therefore rejected valid Sound and Count-in calls. The repair updates the
matchers, including negative-call checks, without changing any expectations.
The failed run is retained. All 109 cases in those three files pass after the
repair. The final app suite passes 3000 tests with 49 conditional skips and
92.29% filtered coverage. The repository passes 728 tests with no skips and
95.74% coverage. Strict analysis, formatting (62 files) and Bloc lint (793 files)
pass. Author screenshot results above are separate from conditional app skips.

Independent review covered all 18 production paths, 46 test and helper paths,
three image baselines and the plan. It inspected the full diff, removed behavior,
cross-file calls, live versus saved ownership, lifetime and receipt guards,
session capture and shutdown, test expectations, simplicity and UI artifacts.
The prior literal behavior matrix supplies the expected values; implementation
helpers do not define their own expected outcomes. No unresolved actionable
finding remains in this source review. Final source hashes are bound to the
review and verification records before publication.

The requested additional Claude review is also outstanding after its session
limit. Keep the review gate pending until it completes. Physical controller,
audio-interface and appliance behavior still require device validation.
