# M3.3 independent bounded adversarial review

Verdict: complete for the assigned protocol boundary, with no unresolved actionable findings. Reviewed pending candidate against base `45ec78fb8b2b5e2e118b910677c172646ca4f761`, incoming `3fd9bf050c420df19d01023c390a8fd5d546ac7e`. This is Astra high independent review, not author certification or an exact committed-head/remote-CI gate.

## Binding and execution

`source-before.json` and `source-after.json` match on all 15 released source/test/fixture paths plus four unchanged implementation dependencies. The frozen oracle, literal vectors and both probe sources match `prepared-artifacts.json` without corrections. `final-adversarial-binding.json` records the source comparison and log hashes. All probe files and the C executable stayed outside the checkout; no temporary checkout test files, product edits or shared audio builds occurred.

The private C executable compiled with C99, warnings as errors and the production `firmware/console_board/pedal_link.c`; it passed. Flutter ran the external Dart file against the actual codec and PedalRepository with FakePedalLink; both tests passed. Logs: `c-literal.log`, `dart-literal.log`.

## Fixed oracle results

1. Literal HELLO versions 5 and 7 remain incompatible; version 6 alone establishes trust. Before trust and after incompatibility, Button/Encoder/CTRL inputs and outbound STATE are suppressed. All executed with literal wire bytes, without deriving expected versions from the implementation.
2. Valid HELLO sends remembered STATE; duplicate pushes are suppressed while every subsequent valid HELLO replies. Connected status holds at 2999 ms and expires at 3000 ms; ordinary inputs do not refresh the handshake lifetime. Reconnection sends state, without replaying old input. The C probe separately pins HELLO cadence 1000 ms and watchdog 5000 ms; physical watchdog execution is outside this probe.
3. Both C and Dart decode the independently specified 19-byte payload with Custom=3, Bank B, eight distinct-position LED values, flags, micros and gain. Encoder output matches the fixed full 23-byte wire frame; the expected payload was not produced by an encoder. The embedded sync byte remains payload data.
4. Mode 4, invalid flags/bank/selection/LED and wrong payload lengths are refused. C invalid payloads leave the prefilled output struct unchanged. Old modes 0/1/2 preserve their identities. Invalid-frame-to-next-valid parser recovery was source-reviewed, not separately executed in this bounded run.
5. Adjacent STATE fields and literal CTRL/button/encoder events preserve their values; invalid CTRL combinations are refused. Source-specific gesture ownership is unchanged: this slice alters neither ControlCubit dispatch nor the repository input ownership mechanisms. Prior M3.1 gesture evidence is applicable to that unchanged mechanism; this run does not claim new gesture execution coverage.
6. Source review confirms Custom amber in the firmware and plate, unchanged red/green/blue old modes, and ring color still controlled independently by global_color. Bank B still addresses LED indices 4–7. The author's new sketch test inspects real renderIndicators pixel output through an output-only stub, including literal amber RGB, Bank B track and bank light; the plate test has an explicit mode-to-color table. These tests were inspected for oracle quality; their full execution is root-owned, not an additional independent run here.

## Source and test quality

Reviewed the complete intended production delta and surrounding current codec/repository/firmware callers, then the author tests. The protocol moves 5 to 6 and appends Custom=3 without changing HELLO3, STATE19, existing mode values, CTRL bytes, trust gates or liveness rules. C validates the whole STATE before publishing fields. Retired transport paths remain absent. No compatibility fallback was introduced.

Author round trips and enum-relative invalid checks are supplemented by the independent literal vector and literal invalid value 4. The independent tests exercise refusal and lifetime outcomes rather than source text. No mutation experiment or parent-version red run was performed or claimed; fixed negative cases provide direct refusal sensitivity. Root reports its full firmware, pedal and app gates green on unchanged frozen paths; those aggregate results are separate evidence and were not rerun.

Limits: no appliance flash, physical LED/color verification, electrical UART timing or actual app Custom dispatch. Custom runtime remains the dependent slice. Publication binding and remote CI remain separate gates.
