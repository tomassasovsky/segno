# Architecture review — runtime and root integration

This is a sequential read-only perspective by the same reviewer as the VGV and simplicity reports. Reviewed other authors' production changes from base `8749688c51912f808c3f36d4eb5bca665ede3ade`; source hashes are in the private review binding. The reviewer's own binding/model/editor work is excluded. No tests or builds were run.

No separate architecture finding arose from the inspected changes. The control editor reaches timing through `RecordTimingControl`; `RecordTimingCubit` serializes Settings and repository writes; `LooperRepository` owns the native pending receipt and separate live/restart intents. Presentation reads the confirmed owner state and sends edits through the cubit or LooperBloc. Session captures the durable owner projection under the declared lock order, while bootstrap stages the complete strict checkpoint before engine start. The C callback owns applied timing state; the FFI snapshot reconstructs per-track timing from the same full tuple rather than later standalone track reads.

The compensated-refusal shutdown issue is reported in the VGV perspective; it is an outcome-state error within the owner, not a second-store or layer-boundary violation. This review did not inspect the reviewer's own target and endpoint changes, run the native tests, or validate physical timing on hardware.
