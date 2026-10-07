# Shared Mixer final independent adversarial execution

**All 52 unchanged probes passed against product-freeze-v3.** The previous M310-7 failure is closed within this independently exercised scope: the same test now observes both live and durable track gain 1.5 after MIDI toggle retirement. No expectation, input sequence or baseline was relaxed. No unresolved behavioral finding remains in this harness.

Execution is closed and the test slot is released. All 1294 files in the final before/after binding were unchanged. The previous failed run, fixture compilation failure and isolated launcher failures remain preserved in `execution-report-v1.md`, its JSON and their original logs/bindings.

## Exact final binding

- Product base: `06633b2b537efba4c59108e38764e58c0b2c542e` plus final frozen product delta.
- `product-freeze-v3.json`: `e1ffe4c243ec3e62f5fa349531b1df3aba9e006baf35a32a4f772982357b6e12`.
- `independent_mixer_v3a_test.dart`: `560adec4d5815b9e54c36cab04e4aab89e8d7b60a1a0762109d6a912ba792c9b` (identical to the 51-pass/1-fail run).
- Original oracle: `5ba698752cca325924b389a06aaede70162b82643495b7eedb64a4305fc21731`; original v2/v3 expected-value addenda retained unchanged.
- Frozen native test library: `31ebe531d01e3eb85297b1785e0f3cdf05b9f04134f277dd2b5bb97ef2bb80a8`; no rebuild.
- Final log: `156273164a483b73d22ef33e9a9f0b38cdb4a8a9e12514604f7ae55974851d78`.
- Final before/after binding: `f01b2361d3835c98dfd8caee8a8e4bcdeedc05092455ee2fc73a943e6dc8b01d`.
- Command result: exit 0, 52 passed, 0 failed; source/native/oracle/harness drift: none.

## Red-to-green result

The preserved red trace seeds accepted ordinary track gain .47, accepts External Held .75 with Released .4, accepts MIDI toggle 1.5, then removes the MIDI device. In the prior bound candidate, live gain remained 1.5 but the durable snapshot was .40000000000000013. The final replay uses the exact same fixture and requires live 1.5 and durable 1.5; both pass. This independently verifies the requested repair at the observed boundary. The separate author tests locating the first stale projection at admission are not counted as independent execution here.

The other 51 cases also pass unchanged: literal conversions and relative steps; strict/missing identities; all eight target families through actual MIDI and External dispatch; MIDI live/durable/raw-envelope checks; source priority including zero; prior versus during-hold ordinary values; same-value intent and reset; native/store refusal and stale retry; one-receipt multi-row admission; missing-sibling isolation; unrelated pair changes around queued track/FX; actual pair replacement/missing-lane availability; queued session replacement; real shutdown flush waiting; and actual SessionCubit track/pan file output.

## Negative-control reuse

`mixer-v3d-sensitivity04` previously executed an isolated app-library copy with the actual `mixerGainAt` helper changed to `2*travel`. The unchanged literal test failed at travel .25: expected .00668740304976422, actual .5. Its binding hash is `9d5f150468fa4489874b4a4463eacd3ecd32350e08498b4d4c3cea82d8276e16`.

That result is reused, not rerun. Exact hash comparison confirms the final gain helper, target conversion class, executed harness, original oracle and frozen native library are identical to those bound by that sensitivity run. The per-file comparison is recorded in `execution-report-v2.json`. The repair changes a persistence decision and labels, not the tested gain-law seam. The earlier three framework-launch failures are retained and are not counted as successful sensitivity evidence.

## Material limits and disposition

The fixture crosses real LooperRepository, MixSettingsCoordinator, settings persistence and pumped native callback receipts. Input delivery, headless device-name metadata and injected storage/refusal conditions are controlled test seams. This does not prove physical controllers, real device re-enumeration, audible listening, OS shutdown or visual labels. UI editor/keyboard/Save/Cancel and expression calibration/sweeps belong to other evidence. Full rollback-uncertainty recovery and every device/channel-removal permutation are not exercised.

Actual SessionCubit **save** writes and reads a file containing Released track gain/pan while live held values remain audible. Six other families have live/coordinator/raw-envelope coverage without individual session-file round trips. This is not proof of a full session **load** with live Control: root separately reproduces the inherited M5 `EMPTY length256` native assertion on parent/current, and this report neither closes nor works around it to claim success.

Existing unrelated analyzer exclusions included in broad binding remain provenance-only; this review does not approve their origin. No separate full source/five-role gate, aggregate coverage result or published-head CI result is asserted here. Those gates remain parent-owned. Within the unchanged 52-probe scope, the final candidate is clean; further product edits invalidate this exact binding.
