# Simplification analysis

## Scope and status

Completed source role pass over the intended change against `a0a54e57ed371c316b9eabcc64379c2c431150cc`, including new sources. Native v3 source review is complete. Final Dart product deltas are reviewed through repository `71f74c3891220c86c54c682f67c4eb4f567076a6f1ebfbc7ab4e9c132acae3bc`; aggregate/readiness gates remain separate. Exact reviewed hashes are recorded privately. Five roles use two reviewers with different implementation ownership, not five fresh independent reviewers.

## Core purpose

Preserve original takes while applying per-part and whole-track Pre processing, independent live track gain, Post tails, All-tracks processing and effect channel choices. Publish each structural chain atomically, retain hosted-instance identity where valid, and persist the same confirmed facts across capture, restart and session load.

## Unnecessary complexity found

No actionable simplicity finding in the reviewed source. No document or unrelated existing abstraction is proposed for removal.

The main added mechanisms have concrete present consumers:

- `packages/segno_engine/src/core/engine_fx_recipe.c` owns prepared recipes and plugin lifetime off the callback. A small queued pointer replaces a large payload repeated through command, event and MIDI rings. This is justified by current capture and hosted-plugin ownership, not hypothetical extensibility.
- `packages/looper_repository/lib/src/looper_repository.dart` centralizes structural recipe preparation across lanes, monitors, tracks and outputs. It removes repeated type/parameter/count publication loops and avoids loading a replacement into an audible slot before admission.
- `packages/segno_engine/lib/src/fx_recipe.dart` is a bounded immutable DTO with validation at the FFI seam. `RecordImage` owns its recipe collection; no extra service framework is needed.
- `trackLevels` is a separate fact throughout mix/settings/session. It removes the lane-zero fallback and keeps unequal part levels intact. Combining it back into part levels would simplify storage only by losing the accepted behaviour.
- Per-target recipe revisions allow distinct startup chains to queue together while refusing an overlapping replacement on one target. Session replay sends one final recipe per target. Live parameter/power controls remain separate because rebuilding the entire chain on each drag would reset DSP state and tails.

## Recommendations

Keep acknowledgement and persistence fixes at their current repository/Bloc boundaries. The known late-ack and explicit-resync notification problems do not justify a new global transaction framework. Preserve the separate concerns of recipe admission, callback publication, lifecycle cancellation and durable writes. Final deltas retain those boundaries: target-keyed save tokens serialize only pending edits; replay retries only registered targets, and quiescent history folding uses the existing remembered chain maps.

No added abstraction was found that can be removed without duplicating resource ownership or dropping a current contract. Small sealed-type conversion helpers centralize actual repeated transformations; deleting them merely to meet a line quota would reduce clarity. Existing repository size and retained public primitive controls are not independently actionable without an obsolete caller path.

## Test and implementation complexity

Tests use the established `AudioEngine` seam and repository ticker for Dart ordering, and real production native processing with a deterministic host fixture for plugin lifetime. The independent probes keep simple scalar expectations and partition-invariance comparisons. They do not introduce production test switches or derive expected samples from candidate output.

## Assessment

Identified safe line reduction:0. No YAGNI violation or compatibility layer identified. Complexity is substantial because real-time ownership and playback-cache transitions are substantial requirements; the mechanisms remain bounded and serve those requirements. No simplicity changes requested. Source role complete with no actionable simplicity finding. Mechanical gates are complete; exact committed-path binding remains separate.

## Final source and gate reconciliation

Local review is complete with zero unresolved actionable findings. All 64 changed Dart paths and all 84 native freeze inputs were rechecked against the reviewed fingerprints. The last Bloc test-only amendment is `eb14048224f1bbb3e08dffbe0902803309da82ff71afb24fd1adae70c57dbedf`; it uses the standard error matcher and retains exactly one error and one write. The private combined final review manifest SHA-256 is `d26c60e74a655fb0ea43eb940afd7c76798e356e3b2c9b3e418cafc9e9f53fa4`.

App v4 passed 2401 tests with six unchanged skips; Looper v5 passed its complete suite. The final affected Bloc test file passed all 128 tests. Reused package inputs match, with the reviewed constant-only engine test amendment and Bloc-only amendment recorded separately; no whole-app rerun is claimed for them. Format checked 640 files with zero changes, strict analysis reports no issues, Bloc reports zero issues across 640 actual files, whitespace is clean, and the observed seven-document spelling check is clean. All configured coverage floors pass. Native v3 evidence remains valid with no changed inputs. Exact committed blob binding and remote CI remain later gates.
