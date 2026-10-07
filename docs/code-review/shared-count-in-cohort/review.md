# Shared Count-in review (#1117)

Base: `6646086a5be2e7c9135b4f01fd0464e316154082`.
Scope: 27 source and test files, the Part 2 plan and this review. Independent
review covered the complete diff, removed behavior, caller and FFI boundaries,
real-time constraints, reuse, simplicity and failure handling. Exact unchanged
native files retain prior source-bound adversarial evidence; the adapted
repository and session ownership integration was reviewed independently.

The review found one additional race. If the callback applied a sibling launch
between a snapshot and the subsequent command-completion read, the repository
could discard that track's pending effect metadata. A real-native reproduction
failed with the correct committed native image but an empty repository chain;
the same case without the interleaving passed. The repair acquires the completion
fence before the snapshot and uses that pair for settlement. It adds no persistent
state or extra snapshot walk. The unchanged independent reproduction now passes,
and the regression extends the existing capture-image test.

Final repository SHA-256:
`02f4b7d27d1fcc619c1583adb57cdedd16c681a5d53f85b9ba9603bec65cfc3e`.
Final capture-image test SHA-256:
`58ea9d292565837da0c1c0644029f4046561ff2af4744a6c21351e004b21926d`.
All 27 final paths match the independent repair review's source binding. No
unresolved actionable finding remains in that review.

Standard, AddressSanitizer and telemetry-disabled native suites and the C++
shim pass. Both new APIs are exported by the immutable device-free test library;
its 11 known device-MIDI omissions remain explicit, so this is not proof of
shipping-library symbol parity. Generated bindings match the changed header.
Final repository verification passes 724 actual-native tests with 95.74%
coverage. The full app run passes 2948 tests with 46 skips and 92.22% filtered
coverage. The engine package passes 356 tests. Strict analyzer, formatter and Bloc lint (790 files) are clean. The final
test-only cascade formatting correction preserves the executed test order.

The requested additional Claude review remains outstanding following its session
limit. Keep review pending until that review completes; current-head CI is also
a separate gate. No physical-device or deferred controller-mapping claim is made.
