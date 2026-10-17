# Verification — External controls

All results apply to the frozen source.json contents. No source changed during
the six aggregate runs. Tests used the working Flutter CLI, existing resolved
dependencies, and the unchanged native test library from the verified FX stack.
No native audio or FFI source changed in this slice.

| Suite | Passed | Existing skips | Line coverage | Required floor |
| --- | ---: | ---: | --- | --- |
| app | 2467 | 6 | 22355/24430 (91.506%) | 90% |
| controller_repository | 69 | 0 | 283/330 (85.758%) | 82% |
| pedal_repository | 199 | 0 | 504/517 (97.485%) | 96% |
| settings_repository | 144 | 0 | 665/739 (89.986%) | No workflow floor |
| fx_catalogue | 21 | 0 | 89/89 (100.000%) | 100% |
| looper_repository | 656 | 0 | 3877/4044 (95.870%) | 95% |

App coverage uses the CI exclusions for bootstrap, window services, application
entrypoints, session directory and the system appliance adapter. Package rates
use their complete reported libraries. No threshold was reduced.

Explicit formatting, strict analysis, Bloc lint across 694 actual Dart files
and whitespace checks all pass with unchanged inputs. The Bloc run used a
visible checkout path; its positive file count prevents an ignored-path no-op
from being reported as clean.

The firmware runner passed its 48 protocol fixtures and actual console-sketch,
pill and ring checks. The new detach test fails against the unchanged parent
sketch. Firmware has not changed since that proof. The independent adversary
also fed actual sketch output bytes through the Dart parser and dispatch path.

Eleven External and nine parent setup screenshot tests passed separately.
Changed renders were inspected, and the native app was checked after a full
restart. These are author-machine visual checks, separate from CI and hardware.
The saved Pen section holds native render references, not a claim that every
historical design page has been reconciled.

Unchanged engine, session, performance, DAW, dependency and workflow gates reuse
the exact predecessor proof (CI 36911357982). The new published head still must
pass its own CI before readiness. Six pre-existing app skips remain explicit.
