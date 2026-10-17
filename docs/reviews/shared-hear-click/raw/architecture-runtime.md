# Architecture review: Hear click runtime and integration

Base: `3025840dd212a86ee1b23c21b6980f0ac4866e20`. Read-only review of other authors' production code, rebound to frozen runtime fingerprints `a2378fb91d786ffb2a5587dce62eb71cd2e80be2343bf96b955dc65bf7fa41c3` and `93e4273c6fa104b5022fd3f311d138cf5d0ff049374da100fa03c495689a0554`. The same reviewer applied the VGV, architecture, test-quality and simplicity roles sequentially; no claim of four distinct reviewers. No tests were run for this review.

## Layer separation

No new dependency-direction violation was found. Native engine and engine snapshot types remain below LooperRepository; SettingsRepository owns scalar persistence; TempoCubit coordinates the accepted mode; Control consumes a narrow injected port; App composes owners and presents retry; Session uses the shared Click exclusion gate. No presentation code in the inspected runtime/root partition imports a data client directly.

## State and lifetime

`ClickModeSnapshot` is immutable and nullable while initialization/recovery is unresolved. Tempo's ordinary and failure streams are canceled/closed, and App cancels its failure subscription. The one shared Click queue defines order with Click volume and Session. The source contract leaves stopped intent deferred and keeps session/device generations explicit.

## Verdict

No architecture finding in the inspected paths. The source is frozen; aggregate, independent adversary rerun and remote CI are separate pending gates.

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
fac6b1d0017bdb4690fe960bf8ae0c7f1029d7ac55ffbc5c1f17f31010248143  packages/segno_engine/lib/src/audio_engine.dart
cd84d9faab2fe633eca657fda6d0e194b5e2e4e43f12339dc235480e2b3f77ee  packages/segno_engine/lib/src/engine_snapshot.dart
```
