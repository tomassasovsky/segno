# Test-quality review: Hear click runtime and integration

Base: `3025840dd212a86ee1b23c21b6980f0ac4866e20`. Read-only review of other authors' tests, rebound to runtime fingerprints `a2378fb91d786ffb2a5587dce62eb71cd2e80be2343bf96b955dc65bf7fa41c3` and `93e4273c6fa104b5022fd3f311d138cf5d0ff049374da100fa03c495689a0554`. This reviewer authored the model/UI tests and does not certify them here. The same reviewer applied four roles sequentially. No suite or coverage command was run as part of this review; author/adversary logs are separate evidence.

## Closed finding

- The initial read found no External expression movement through the real Tempo owner. `test/control/click_mode_dispatch_test.dart:280` now adds a native-backed case. It checks that contact attachment and mapping Save produce no receipt, then moves raw `0→255→128` and checks literal Off, Play & record and Recording, increasing callback revisions, accepted owner mode and stored scalar. The author recorded 20 passing focused dispatch/owner tests after this addition. This gap is closed at source level; final aggregate and independent rerun remain pending.

## Other coverage observed

The native C tests cover callback publication, same-value refusal, capture ordering, armed/count-in eligibility, queue full, reservation width and audible mode semantics. Dart package tests cover strict scalar storage, stopped/restart intent, bounded settlement, compensation and owner recovery. App tests exercise initial recovery, power-off/Retry/Keep playing and a real MIDI held release; native-backed Session tests are explicitly required by the CI job with a checked library path, so ordinary self-skips are not counted as native proof. These are coverage observations, not a claim that final CI or independent adversary gates have passed. No further actionable test-quality finding was established.

## Source binding

SHA-256 hashes below bind the exact tests and CI route inspected in this role. The report must be rebound if any file changes.

```text
be703261a3b605a52832d6f95d47a578b6610ffe0b1895e22ac59b6b94135c4e  .github/workflows/main.yaml
b53e886e1d1df761e833522343329d7648d3fc049be789f79a10c30684d0be54  test/app/audio_bootstrap_test.dart
1240a0a51f47af6a4577c635c17f720cc1a8ea1107490860cc05b4206566a9dd  test/app/view/app_test.dart
bfff4003ba0b8d989a1d6c860c0dfde0329228bcb9b37ec672d9ca803e0fc18b  test/control/click_mode_dispatch_test.dart
768c08021dbbf33a4f215590f4e24dae26404be96bcb89948068877142ace6c8  test/looper/cubit/click_mode_transaction_test.dart
3c77c7a076c55a28257ec97281f00575b2b366198083c4ab66c5dbcac4bb69a4  test/looper/cubit/tempo_cubit_test.dart
e6ed68f2adf203387f27a29d59a8ab95752222ef1b730ca7747fe0d8c7ac746d  test/session/click_persistence_test.dart
eedcd9ae7f875c1b47275c02c17823792ca72ae2c6335982c62beaaaee365abf  packages/looper_repository/test/click_mode_receipt_test.dart
30d87954439e2ac0f0b5b345deb93cb5b054bc43186ea45e019cec14a5a26fd2  packages/segno_engine/test/click_mode_receipt_test.dart
bfdabd18bccfdab3944238a269e86384fa28ed968cd67300876792fc27155c67  packages/segno_engine/src/test/test_engine_core.c
59e58b80f0c4f6dbe9dc3791cfc5d2c10d07b9f9091e2a10be9cb9799405c716  packages/settings_repository/test/click_mode_checkpoint_test.dart
```
