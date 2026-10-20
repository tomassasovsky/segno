# VGV review: Hear click runtime and integration

Base: `3025840dd212a86ee1b23c21b6980f0ac4866e20`. This is a read-only review of runtime, repository, native, App, bootstrap and Session code written by other authors. The same reviewer applied four roles sequentially; these files do not represent four distinct reviewers. The final runtime source is bound to phase-1 fingerprint `a2378fb91d786ffb2a5587dce62eb71cd2e80be2343bf96b955dc65bf7fa41c3` and phase-2 fingerprint `93e4273c6fa104b5022fd3f311d138cf5d0ff049374da100fa03c495689a0554`. No tests were run for this review.

## Assessment

The intended ownership direction is consistent with the repository's Bloc architecture. The required Click mode port is injected into Control, Tempo serializes durable/native acceptance, Session captures the Released value, and the native callback performs no allocation, blocking I/O or lock acquisition. The old direct Tempo setter and direct Session capture path were removed rather than retained as compatibility routes. State is immutable and new streams/subscriptions have a close path.

The scalar command receipt spans the C snapshot, generated FFI bindings, Dart snapshot and repository. The repository's frozen projection reads the confirmed mode, not the raw mode visible before callback publication. The native reservation uses the 64-bit posted command coordinate. Both corrections have source-bound red/green author tests; the earlier failed probes remain part of the record. The independent adversary rerun and aggregate remain separate pending gates.

## Findings

No additional production defect was established in this pass. The earlier External expression dispatch coverage gap was closed with a native-backed owner test, assessed in the test-quality role report. Full aggregate, independent adversary rerun and remote CI remain pending on the final head.

## Source binding

SHA-256 hashes below bind the exact files inspected in this role. The report must be rebound if any file changes.

```text
793b4557ffd9a6c8cc5e95f8cab7736ab80af058ffae50b9c3981f9bd5a6d767  lib/app/audio_bootstrap.dart
40cc977d2e2597ee497e9d8d14b6bc4c8e5fe35b2b585647f2d617e05a4dafc1  lib/app/view/app.dart
33ec90a16cea75f8dae0948ca2d2941ddbcb28ede4ee578372c0aaa93dbe802f  lib/control/cubit/control_cubit.dart
802508d9e9afb251a268506b72fa11d8b9b4231b3fec048679b72c77f3576d2a  lib/control/cubit/control_midi.dart
b27186b985b6f265e82bf0adf4fd894eec2e87abc11bb988a0ae413a29641a23  lib/looper/cubit/tempo_cubit.dart
b0cbc1f20312f9ffed1756a4fe10e7cf1bde09adb81ea841a45a9a9cc4d43ccd  lib/looper/model/click_mode.dart
98d994e884f9608c8dcb07177dc0d5dbe88cea2b2f4310518aed536e3e3937b3  lib/session/cubit/session_cubit.dart
8870efa81020857bafef7192401b40ca74a2b4b216ed0da170c6506eb3f4ff58  lib/session/session_mapping.dart
f4f636c4c7be70f6802017aaab2fb6a7d9e95e07bfaa8f9d7b6d25f7717fd36e  packages/looper_repository/lib/src/looper_repository.dart
8715d192adccc13b64a24decf43fb34cd7f8055b400a89c1169129ec9591b015  packages/settings_repository/lib/src/settings_repository.dart
cd84d9faab2fe633eca657fda6d0e194b5e2e4e43f12339dc235480e2b3f77ee  packages/segno_engine/lib/src/engine_snapshot.dart
2c1063eaa645b191e53a4cd9d85a886a551331db1041528c333a8735bd08804e  packages/segno_engine/lib/src/generated/segno_engine_bindings.dart
0e24fea217b1a2e4c1f702673f94828a6c871db8c1da57cde99029cb6a958465  packages/segno_engine/src/core/engine.c
b061aea17b12f4e9054a926f8b623ad79be66ab5e794d1e80e7b629602c62705  packages/segno_engine/src/core/engine_commands.c
1313d3285a5468d74644024a53c39f812de4f791a8432a03ef49106ad9144e47  packages/segno_engine/src/core/engine_process.c
9d54861b36f2c326b8439eedaa0e25cef9253ffd1d2d96a807998c5485e7c356  packages/segno_engine/src/core/engine_snapshot.c
6c68ac342212867fe0a99abb79f7db64bfd7211b4db659354e8a016d64e1dc4c  packages/segno_engine/src/core/engine_private.h
d0908f21fda2d6943b298736bf9a14bc58aa3965caef90f7b50ed31e85c11103  packages/segno_engine/src/core/segno_engine_api.h
```
