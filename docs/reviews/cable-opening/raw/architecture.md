# Architecture and simplicity review

Scope: only the cable-opening delta in `hardware/enclosure/segno_enclosure.py` against `/tmp/segno-cable-opening/before/hardware/enclosure/segno_enclosure.py`. Reviewed read-only as a separate first pass.

Findings: none.

The implementation stays in the existing CadQuery collar builder. It adds measured dimensions and one derived lower boundary, then selects the new width and start height only for the existing standalone collar with a removable sled. No signatures, imports, dependencies, layers, exports, or manufacturing workflows change. Traced both console callers and the integrated mini caller: the mini explicitly sets `standalone=False`, so it retains the prior 12 mm, full-height exit. The existing direct/no-sled caller likewise retains its exit.

The dimension arithmetic is explicit and proportionate to the approximate inputs. Retaining both vertical interpretations in the lower-bound expression records the actual measurement uncertainty without adding an abstraction or configuration framework. The top remains open for the documented pedal/sled drop-in assembly. No actionable simplification was identified.

This pass does not qualify print shrinkage, material strength, native-model synchronization, or final artifact publication; those are separate checks. Test changes are outside this source-only scope.
