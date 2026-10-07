# MIDI source review

## Published CI correction

The original review below remains the application/native review. After
publication at `1c7c07ebbce9ed87130e9484d259aed05cc7f616`, an independent
review covered the complete test-only MIDI coverage correction and its
production call paths, including all five quality perspectives. It resolved
one timing-fixture finding and has no unresolved actionable findings.
No original assertion, threshold or exclusion was removed or weakened.

Current test SHA-256:
`c8308f8f386493607bde8d6eec63f65755833d7918941868baaeb7143b797672`.
The current 134-path fingerprint is
`755a00187a8e6064d218fd552e9581513249d160c9108d3dcf145dc255c3f936`.
The manifest retains the previous fingerprint for the original review below.
All other reviewed source, asset and Pen bytes are unchanged. Runtime results
and remaining CI requirements are in [verification](verification.md).

## Original application/native review

Base and current Git HEAD: `1ef7fb30abd328b86ac481ec71e72c9bbc59e83c`. This is a working-tree review; a later commit requires the coordinator to bind the resulting commit to these reviewed bytes. Exact intended-path hashes and scope are in [the source review](source-review.md#reviewed-file-binding).

One independent source reviewer performed the VGV, architecture, test-quality, simplicity and readiness roles sequentially. These are five review lenses, not five independent reviewers. No delegation, product edits, test execution or UI automation was performed by this reviewer. The coordinator and separate adversarial reviewer supplied execution evidence.

The local source and quality gate is **clean** for the exact 134-path manifest fingerprint `3cb49b9c0e522f35d7275b5b58a6a30095a4f8350c161796bb48f3806c2be705`. All eleven functional findings and the final future annotation are resolved; no actionable finding remains. Final app, package, native and static evidence passes. Published-head CI and final commit binding remain separate, pending gates. No ready-to-merge, merge or deployment claim is made.

## Scope and completeness

Reviewed the full intended diff against the External predecessor, including untracked product files, then reread all repair deltas and the final five fixture/import repairs. Excluded unrelated Loop settings raw review documents and transient macOS build changes, which the coordinator restored. The source review retains the original base scan; it is not a review of only the final fixes.

Read the project instructions, build/test and tracking contracts, the bug-focused review skill, and all five role definitions. Accepted authority was the MIDI controls behavior/design and mapping-parity decisions, plus the explicit retirement decision in implementation handoff section 8. Project rules supersede generic role advice to remove fakes, generated code or interfaces, or refactor by line count.

Completed line-by-line changed-source inspection, enclosing-function review, removed-invariant audit, cross-file caller/callee tracing, lifecycle/failure-path review, reuse/simplicity review and real-time boundary review. No delegated reviewer failed or was omitted; the single-reviewer arrangement is disclosed above.

## Findings and repair verification

| Finding | Repair verified |
| --- | --- |
| R-MIDI-1 | Accepted Mixer Reset removes Released projection and publishes final ordinary track values; refusal preserves the prior hold. |
| R-MIDI-2 | Built-in chain, binding and encoder writes participate in shared ownership. B1 release deliberately restores captured prior and publishes fresh ordinary intent; refusal retains its obligation. |
| R-MIDI-3 | Track, monitor and Looper persistence wrappers join the shared shutdown flush. |
| R-MIDI-4 | Draft endpoints support boundary reset and cancellation of keyboard preview on Escape or focus loss. |
| R-MIDI-5 | Native capture microseconds reach immediate decoding before asynchronous dispatch, preserving the 100 ms multiple-byte window. |
| R-MIDI-6 | MIDI track-level submission captures session, engine generation and device before the exclusive queue. |
| R-MIDI-7 | Existing FX activation resolves through the shared picker and labels, with binary Off/On endpoint editing. |
| R-MIDI-8 | Continuous/toggle retirement retains accepted sound and original ordering without writing an older value. |
| R-MIDI-9 | Stage closes the host tray and pops the MIDI route for both Settings and Control tray entry. |
| R-MIDI-10 | Delayed monitor metadata persistence rereads the live acknowledged FX owner after receipt barriers. |
| R-MIDI-11 | Close cancels and drains binding confirmations and restore readiness before closing; completion cannot emit afterward. |

The R-MIDI-11 regression tests were inspected without execution by this reviewer. Coordinator evidence shows both new cases fail on the prior implementation, including an actual `Cannot emit new states after calling close` exception; the unchanged tests and their built-in/momentary neighbors then pass, 17 tests total. Confirmation cancellation releases the shared pending-persistence barrier in `finally`; close awaits all tracked decisions and readiness before clearing held obligations.

## Cross-file and removed-invariant audit

- Decoder/model: strict field validation, disabled/Omni source reservations, Program without release, relative two's-complement `64 = -64`, and fresh complete multiple-byte assembly remain enforced. Native capture time is retained through the device lifetime and immutable readings are decoded before queued dispatch.
- Lifecycle: selected-device epochs, editor ownership and Learn tokens fence stale work; session/device/engine origins are checked before deferred mix admission. Reconnect does not replay retired input. Raw musical capture remains independent of remote-control pause.
- Ownership: the shared accepted-target ledger orders MIDI, External, built-in and ordinary UI writes. Refused commands create no holder and retain earlier cleanup. Non-held retirement preserves audible toggle value while logical latch resets Off. Built-in B1 intentionally restores captured prior rather than adopting External's authored endpoint contract.
- Persistence: one application-owned `FxChainPersistence` and `MixSettingsCoordinator` are injected across writers. Authored Released values are projected into FX, Mixer and Session saves after confirmation; performance audio capture remains live. Pending saves join shutdown flush. Malformed configuration is retained until deliberate confirmed replacement; failed Remote Off remains paused with the previously confirmed setting and explicit retry/resume.
- Native: Program parser/private enum/ALSA conversion agree. Apple packet splitting already handles the one-byte payload. Apple host timestamps and ALSA monotonic time both become microseconds. Close clears queued input after producer teardown, and Dart closes native capture before releasing its callback. No public C API signature changed, so FFI regeneration is not required. No new allocation, blocking I/O or lock was introduced in real-time callback changes.
- Removed behavior: implicit CC80–86 mappings, old click-toggle/cancel-arm defaults and obsolete Learn/simulation UI are intentionally retired. Shared `command:tap-tempo` and UART console authority remain. No fallback or migration was added. Unused `MidiSignalLevels` was removed and has no remaining export/caller.
- Final fixtures: missing stream/getter/session stubs now model the real dependencies. The tracks fixture supplies its actual 48 kHz engine state while retaining original bar assertions. App teardown explicitly unmounts the page before disposing its borrowed device repository. Assertions were not weakened to match a changed expectation.

## Validation evidence and limits

The coordinator's normal, AddressSanitizer and telemetry-disabled native suites pass with no drift in their 611 bound input paths. Nine relevant package suites report successful exits and semantic pass; all configured package coverage floors pass. The independent adversary reports 18 passing runtime probes and a required failing negative control. These execution claims belong to those runners, not this source reviewer.

The five final fixtures have coordinator evidence of 306 passing tests and six explicit skips, clean focused analysis, positive-scan Bloc lint on five files, and no format changes. The final app aggregate passes with 2,433 tests, six existing explicit skips and 90.857% coverage (23,314/25,660 lines; floor 90%) under the repository's configured exclusions. Final format, strict analyzer, Bloc lint and whitespace checks all pass; Bloc lint actually analyzed 703 files. Earlier failed/stalled aggregate attempts were superseded by this completed run. The sole source delta after the app aggregate is the explicit `unawaited(_bindingDecisions.remove(holder))` annotation: it does not await its own completion or change execution, and both disposal regressions passed again. The coordinator's final binding records no drift in package/native inputs; this reviewer independently matched every final manifest entry.

Existing Mixer pan/balance and loop/click catalogue coverage remains explicit M3 follow-on work; this M3.9 cutover does not complete the full accepted catalogue. Transform, backing and instrument families require their later M4–M6 owners. These are scope limits, not waived campaign requirements.

Physical MIDI interoperability, appliance behavior and platform callback stress are not proved by source inspection or desktop tests. ALSA device identity based on names is inherited. Author screenshots and saved Pen references are separate visual evidence; this reviewer did not independently operate the UI or approve pixels. Required generated bindings/assets and production `AudioEngine` fakes remain intentional project seams.

## Reviewed file binding

The authoritative [source manifest](source.json) records 134 intended changed/deleted paths against base `1ef7fb30abd328b86ac481ec71e72c9bbc59e83c` and fingerprint `3cb49b9c0e522f35d7275b5b58a6a30095a4f8350c161796bb48f3806c2be705`. This reviewer independently compared all current files and intentional absences with that manifest: zero drift. The only aggregate-to-final source delta was the reviewed future annotation, followed by focused regression and final static checks. The table below repeats the exact hashes for durable review evidence; `DELETED` records intentional absence. Visual artifact hashes bind those files but do not claim this source reviewer performed visual validation. Reports are excluded to avoid self-reference.

```text
lib/app/fx_chain_persistence.dart	671ba63e6bb8ff6746b2436bb2dda5deb4ed5b7dd5e510768fd11e1f035e7f6c
lib/app/mix_settings_coordinator.dart	dd05927b943fe0fadd0f615d630e8d315421273d5b2eff94590f5379c935212d
lib/app/run_segno.dart	991a341f96bbeb6e547056e6a546a3a4e73748eb45e85fb31704ab7f86c596a6
lib/app/segno_navigator.dart	5cd9002ac4b300cbdb59c1b7dc9fc8b5d30a745732b8b7a6f6be2080f06b52b0
lib/app/view/app.dart	5b8dc742fd3c1034c913e442df3d8f71045e9f9eb97bc774acd268c8ed2e82e3
lib/appliance/power_off/power_off_cubit.dart	9f8b22e83cf0450a5201a775a8dd00e10150e74116d1f74a4063e9b7dbbd8084
lib/audio_setup/audio_setup.dart	13e4779037a791235c369da31348bde29bd005e897cb2f52da5416cf7a2a4aae
lib/audio_setup/cubit/monitor_cubit.dart	c484d3bcad80a260e4753f9bd455456710bdb8937de127157d3d078a4e9ab8de
lib/audio_setup/view/audio_settings_section.dart	a8bade3c69887a0748628661b590371e1863ca632ec3b38959cdcc10748a9550
lib/audio_setup/view/midi_learn_section.dart	DELETED
lib/common/fx_chain_persistence.dart	DELETED
lib/control/binding/binding_labels.dart	6fb085946ef54ad3b65c4c075967186e0e7364b89924f19f4129201244b14125
lib/control/binding/control_action.dart	ffa38b9c446d66fb14e12f155d00578b974e1885ba5ab5b99d3484d64127033f
lib/control/binding/control_action_labels.dart	75cd4d55d4d7b7d9f226e87e67caabd063dd0b635426e4e5d891d025e94b21fd
lib/control/binding/controller_learn.dart	DELETED
lib/control/binding/midi_edit.dart	4bb608390d392b2da73c8b29721df39007e994101c379184139dcdb9246741f5
lib/control/binding/midi_labels.dart	85240cc81c793dbbfaacf3fefcf7002330d7a4f9ea0a12990ce0e4ef68416d7b
lib/control/binding/midi_learn.dart	6451d9afc7406eef62b044c5292593ed9277267686212276a5d76709809b8c7e
lib/control/binding/midi_mapping_draft.dart	ac81ac6dceb7f301abea88e14e5186a7e978a56f7362b99ab148420bc7e4fffb
lib/control/control.dart	1c0286292f3a4b21849c1a21a0dc27fa8dfe77dad727b64619586c844834fb0f
lib/control/cubit/control_cubit.dart	7011a9aaa7c166b6ab9de5b89575226e12d64a80859dfde602d103049fa37874
lib/control/cubit/control_midi.dart	a19b94a8859a54501ad6bdbe1534bb1aa8c78189d9ec47f58c22cedc9564ec92
lib/control/cubit/control_state.dart	c7e0ada242a844b4f37cb4d746503c731403803eea45d5d6f7ac77dec3c041e0
lib/control/view/controllers_tray_body.dart	12b2c7ae6308e7fd5221e029755d73f61bb273e2b2984caa2327df2ff3ccbb4d
lib/control/view/midi_controls/midi_choice_grid.dart	f45b223879074492ced3d8b09ffd89002339da9e9043fbd0af5141dbcd7f96c8
lib/control/view/midi_controls/midi_control_cards.dart	883340d1aeec214db28142475677d8c03796ebe6c831f7fb22f7d2211eb4bcf8
lib/control/view/midi_controls/midi_controls_page.dart	ce8dd13fa3547607cdbe8584ff7bbb5c01db4b42d073d4c22972c01903d3c419
lib/control/view/midi_controls/midi_device_cards.dart	069b674db4adc4740cbf115238061b1389cccae15d94348b40236b4537d91e87
lib/control/view/midi_controls/midi_mapping_rows.dart	dc716c967ac40c663fedbd4d9f5542abbd06285ce1cb66dc78c896f7da23379c
lib/control/view/midi_controls/midi_segmented.dart	888ae06dd553d4d8e7f52c70c608ffefc831d170057f2d4700282e7992ba5576
lib/control/view/midi_controls/midi_source_panel.dart	d27da2461dc1200c7af92d659ee62d601750fabb544acfcfe248105a5b625873
lib/l10n/arb/app_en.arb	7eb92d15ce82c12bfe2e89979986d442977ba8d72e27b65f936fbd84f1b00c9f
lib/l10n/arb/app_es.arb	f7e3090987f1ce099416988619b5b04a76a5c031ed347ac30c77db76abb833cc
lib/looper/bloc/looper_bloc.dart	302a7b7e134e3144d28f7af762eb82df2647029bee6cf9f2e847d5ea9a5e4278
lib/looper/bloc/looper_event.dart	93f22c0d23c86fb64a9b895d80c329a86b1f8570b3b4426d3537751eb70fdf90
lib/looper/view/looper_page.dart	26720f0ccf21e8ee82e0ea448b0fb23d24a800595adde6b0718698b5e8738046
lib/looper/view/settings_page.dart	f99b0ae091928c682d692ce095e43c39f28d8193f54fcad39a610f88dcef494b
lib/session/cubit/session_cubit.dart	e132daffea109e419d672dd4e721aa5b31194b9651b5995ef020d9ab05b8f77f
lib/session/session_mapping.dart	3a19504bb6d2d5eee682c3f0ec49524f1534ff05f8ce84c5203407aec72da640
packages/controller_repository/lib/controller_repository.dart	dc8f6a85c5576b953da3d15ffcbd04768fe6b763731c78763ee5d6424392f104
packages/controller_repository/lib/src/controller_binding.dart	DELETED
packages/controller_repository/lib/src/controller_binding_event.dart	f9cdfea29aca06c2c0010b61b4b4e67949e30aae6a1bb6089151f4f89b942dfb
packages/controller_repository/lib/src/controller_binding_set.dart	DELETED
packages/controller_repository/lib/src/controller_event.dart	DELETED
packages/controller_repository/lib/src/controller_input.dart	1407e9c860074ba42206e5f0454b6750db46dc208c9c645c34da4d3116db9610
packages/controller_repository/lib/src/controller_mapping.dart	DELETED
packages/controller_repository/lib/src/controller_repository.dart	8f624e4de93c7fecfec182a4ad1412f6b02ab80431b14b2be32386421cefcb38
packages/controller_repository/lib/src/looper_action.dart	DELETED
packages/controller_repository/lib/src/midi_mapping.dart	2e5c24b211229d7fe543a70ca03315aa69169536dfee71b4d25a8a9f3b69db33
packages/controller_repository/lib/src/midi_mapping_engine.dart	acd7b667d2a1d8fea177b82de1bed3df9816d479cfa4f3d723e887122c68ae8a
packages/controller_repository/lib/src/midi_protocol.dart	b3f5fb41588eb5ee48746dd09c27b6505745963a605b1b7f2df1a4b6b149d6fc
packages/controller_repository/lib/src/simulated_controller_source.dart	367dcdda3ce541f2b441b7dbdcc9aff89d3bebd6ad1425a569df71e66e6a6349
packages/controller_repository/test/controller_binding_set_test.dart	DELETED
packages/controller_repository/test/controller_binding_test.dart	DELETED
packages/controller_repository/test/controller_bindings_dispatch_test.dart	DELETED
packages/controller_repository/test/controller_mapping_test.dart	DELETED
packages/controller_repository/test/controller_repository_test.dart	23ee81d1a0ca18f68e199497a2fb2224d5d0aa0df3a5a43a927a20f41ede2497
packages/controller_repository/test/midi_mapping_engine_test.dart	fb29ef29c83051186815687d0f368ea02c3fe7bc72e50455a0ae4d0a3cfa4dfe
packages/controller_repository/test/midi_mapping_test.dart	c837953a248026d096e20ea695cc6d9e25afce24c7e4fff7333d53d31c376df6
packages/controller_repository/test/midi_protocol_test.dart	eebd683af315fb83d6f61ecc06c98e3080e651389e1a0fb4fe950505e4ae0f7b
packages/controller_repository/test/simulated_controller_source_test.dart	5329cd8e11738b10c3fdaeac4f59f2cc6a5805dc8b7fdecf6d467811690af98b
packages/midi_client/lib/src/midi_controller_source.dart	034fd5ad0beebe86eaabe99c6c9753456d576373ba3469f8a16b8e46e272f39c
packages/midi_client/test/midi_controller_source_test.dart	2e8f0d2cc4cea08f6e89ac0a65afd57ea50a53e04b9319dd38f2583ee3fe17e8
packages/midi_device_repository/lib/src/midi_device_repository.dart	09d1f7755da32f2253dff7f3c579169adfed1e95462105097bd98c354c28fdfa
packages/midi_device_repository/pubspec.yaml	cc3e6e110d5d85b8bc3a82a6301c288b5db67bdceacebd663ec464c9e9378acf
packages/midi_device_repository/test/midi_device_repository_test.dart	463ce341c5bcd017141d4c9516499ab531cc32a2c660927119947bc308c725cf
packages/segno_engine/src/midi/le_midi_internal.h	7378f468a32d1d17d2c38d8b1f5f984aacbeab1fc4e7377c655d843ee7d48b1a
packages/segno_engine/src/midi/midi.c	5b9479245174fecc312bf6a870853cbf691189485d915d9f008068cc1d410cbb
packages/segno_engine/src/midi/midi_backend_linux.c	c0037cd1bf66209ae3badd974559c90cfc435e22cb0bc925674dbe2f3a3364db
packages/segno_engine/src/test/test_midi_core.c	ec0e2d9a124e25c3317c28e10975b6b69bede40b4305e2108469bbc4cf1e7f31
packages/settings_repository/lib/settings_repository.dart	f7788a2b6b5543a834a2cfcd373a87ee55fc9f20964f86b96bf98219cf00c0ec
packages/settings_repository/lib/src/settings_repository.dart	9bc19f7f15b68a4f34ecb1a36ec560e252ebe7312934fba0faaa84e5424762bb
packages/settings_repository/test/settings_repository_test.dart	3d06c34be648477ff41f01ae6923c6ce95f7dd8276b718e64a0288c7486b6f78
segno-ui.pen	98671cebbb7d422db64a882383fd264efb146e54033535334ea2765996ab5e8e
test/app/audio_bootstrap_test.dart	84368c5b3110762a27fda8df98699636bc64ffc718a5f331761a443badcd9be7
test/app/fx_chain_persistence_test.dart	f7c1c4ce18ccb30f00fdd5593d07fa57447e244e48dcc556aee82caebcc4ba8d
test/app/mix_settings_coordinator_test.dart	a8a82bbfca83d7d1f6badc0eb12c9f490ab5111404e8452526e7e4bf819bba34
test/app/view/app_test.dart	d04105d6ad30d68c8c006706539a07dd276e5a925bc443ed1f3b4fe61e48d6d0
test/appliance/power_off/power_off_cubit_test.dart	77bbe3c647e09e7547de966110a9406f12a67c4097c7dfa3b53c036a2f61449c
test/audio_setup/cubit/monitor_cubit_test.dart	d651d1571e9f00e0edc7e94507bd3b3dc8701429c57c95598131fed1c5781d5f
test/audio_setup/view/audio_settings_section_test.dart	21566995d6dc423891ad7fd915d5874bbd4413a6078fc3393f5627e7e9cd0d9b
test/audio_setup/view/midi_learn_section_test.dart	DELETED
test/common/fx_chain_persistence_test.dart	e7ae7562ca1d9827d350dbdefcb86c935881e7322450a3807e0c0503394057e8
test/control/binding/binding_labels_test.dart	f4a26fd14c2f85f28a026bd1f1d98b5412782e103ef3ab960e730c5c771f64b7
test/control/binding/control_action_test.dart	c6365d9884eb18fc05b56b19c99904b544820b7ecc14f519dbbe52d01baf4d52
test/control/binding/midi_mapping_draft_test.dart	44f46f307de49f8f092292ef5c888bb48ebfbd33dad12266360d5e401c825e0b
test/control/control_cubit_controller_test.dart	DELETED
test/control/control_cubit_test.dart	1d914ea1eab53af1f26f94e475f4654e0cd74168a0496fd243ed86848f642515
test/control/control_face_test.dart	88b318a1d24357b9108ebc7cf3ed3d5e3da192ad4c53bb7240e0cc5faf1e893b
test/control/external_controls_page_test.dart	b5c85eff751df2ff3e1f4cc67bf4d93044da6c2d45e8f62e97f91cf1f6cc9432
test/control/external_dispatch_test.dart	55afebe346a28fcc65082e4a08e99c054bb31ea46d2e6c1800a921f78369b77b
test/control/external_expression_page_test.dart	7d7fe9269cf8cc120d067887d03c54668fe156d21b48bc3552de9161138cb1d0
test/control/external_pedal_page_test.dart	b86b6761a3b7b5e53a7a48f3f9182a6b162c4700491d14e7860482ccff75e4dd
test/control/midi_controls_page_test.dart	326a97283a7cf362ae208f0fed99520006c4e92c8d96a085856699ab778f3e2a
test/control/pedal_setup_page_test.dart	0e3604bb4975547ac0b9499e60fc9854820fe4942324da70a20f1cf5719a5f58
test/fuzz/control_sequence_fuzz_test.dart	8377ed6c718a18b9133c0cbe2b8f9bf448c202e29cf6c762d913607655037e71
test/looper/bloc/looper_bloc_test.dart	02596a58fe3c93b8919221e9e02460974edc4e6ead93e05183539de964a60da3
test/looper/bloc/looper_mode_persistence_test.dart	13a7e981dfdfad69aa4a966a21e61dcaf4f9ecd9dff8dc361542e4ecfb676852
test/looper/bloc/midi_looper_integration_test.dart	DELETED
test/looper/view/audio_routing/audio_routing_test.dart	0af8e2bbeb6b01a9fe90acf629d8a91750e2a144b76b3f448de6e3499f10a3b6
test/looper/view/fx/fx_page_test.dart	5baee77c7d0f18c23a5c80c9c14779f1530828ea852d3bb64eba1942f597d81c
test/looper/view/looper_page_test.dart	0fb630390c5551fe4b34ead8f4d033dd8c380594607dc7225411914f2da6573e
test/looper/view/session_persistence_sync_listener_test.dart	1cffca2473dd5a610fdf74a35237a3db2ebf57ed053cf92d04997c0f38c645c8
test/looper/view/settings_page_test.dart	d18c091287bdbb501d1c393ea8cf56cdf8f5e4247e6834553eba80fb9836214b
test/looper/view/settings_tray_test.dart	26e6d1a4cd651bf172c78abea71b65d48892961b9fd67d9271d12d1cb303427c
test/looper/view/tracks_view_test.dart	fa659dbe7dfbe82fec75240ae3262f28d729d2bae8e5b5521430e6d496f2112b
test/pedal/view/pedal_assignment_page_test.dart	bbc22897043a46c2ef27c4b69faf5f10d964fd433809cc7dc11b6bf472b78a2e
test/screenshots/audio_routing_screenshots_test.dart	0fecaa1db0393b1ed787511ee11923841d6aba0b70d8fad50349a5ec3a3b0700
test/screenshots/control_center_preview_test.dart	8fdd251ed56f13541fa40363fa4e1c4b93eed76a9215ebd3460f54b014ad5d30
test/screenshots/external_pedal_screenshots_test.dart	aca562d176dd314b6c4dd70fbdc2139c019aa2165eca1a9c22cd3ade66452e5d
test/screenshots/fx_screenshots_test.dart	69f8eb2796e5af6730b076dfab9ce9cf3eb0fda663fa989d64ab32a5ffa2116c
test/screenshots/goldens/control_center_control_midi.png	73d1405ce88b4dec22a4d0561a87d45a5094e74c88f3a6665956593d76517881
test/screenshots/goldens/control_center_control_midi_device.png	DELETED
test/screenshots/goldens/midi_controls_connected.png	4dfae9c02d534b266489d3ea8b71a051aafe683555b7fd9e90dd9db14412315f
test/screenshots/goldens/midi_controls_continuous.png	a72b6f20cbd3edd020f1144f72c02b4cde8c3216efd60d65385c7d0422ed5297
test/screenshots/goldens/midi_controls_disconnected.png	6d3d40b3798fae470f9e44e94ca6e4633d10182504c8b1acf3d95416f3618d67
test/screenshots/goldens/midi_controls_formats.png	bb4e7cbcd4e4103d851b10200e7082c62769706538ea027ac8e831c9b724ec7f
test/screenshots/goldens/midi_controls_listening.png	45110190b95a052f4ed243cd4eb6c8e60c9d16f81aa52ca5ae9bf66a15b79734
test/screenshots/goldens/midi_controls_missing.png	139114a5796565c5004b84591d10b8518f95fb0dfbd15243d4707dcb8d8b5c23
test/screenshots/goldens/midi_controls_momentary.png	481dd10af8944e015da5f104d9f728ae3b858e179d91b7abaa3303b21ba30164
test/screenshots/goldens/midi_controls_paused.png	011815f89300b30d04917d093c761d7ae8b5948443d45f5fd905f3fa342e2f6f
test/screenshots/goldens/midi_controls_unavailable.png	47b2c53cba23cdaa439ce35b7430a3bd3c70d01c49a8ba7986f570917e3365e9
test/screenshots/goldens/settings_audio_recording.png	d49882ec77625a3eddf996e330d28cb131f84569b27178114a3730e2996d9d9f
test/screenshots/goldens/settings_view_tracks.png	611373cfc1c35d5ecb3e46b6976df343a03a160c741f3d5470ca83d2453a9924
test/screenshots/midi_controls_screenshots_test.dart	ac968eecfa6d34acced6eefde17478af6f8fc2f922039056e26ba591663dc5b1
test/screenshots/pedal_setup_screenshots_test.dart	d96aa93c0b80836839ec539502166e546314df61d1668f50608dd679eb4edbbd
test/screenshots/settings_screenshots_test.dart	51b55b144c1540ec17d6d358ec87e06b47fe510237d44423b76d20aa5cf559fa
test/screenshots/tracks_screenshots_test.dart	4ad91f1a3e78473af4d2799927b1941deb3ed67f94803c4b801321aeb8442eb1
test/session/cubit/session_cubit_test.dart	c1451de1cd9154d6bdc67e7cd1e1c11d1cd893b66d666d84a3f97af5af22a6dc
test/session/midi_persistence_test.dart	a17494d50e58b5d16d7e35f30886a70137e3d96ea584b15f6c2a83d27d224465
test/session/session_chain_idempotence_test.dart	f8770e028fb56d5341047145ee734b678f28dfbf5320f8cc67ba4d3f3430a71f
test/session/session_fx_roundtrip_test.dart	6f58fd188413fb29cadc2ed09bdbaf49310caa3d4bbc2b70b5479d41e79cae71
test/session/session_layers_roundtrip_test.dart	b88a04ca217d79bdd0cb28bec090068ac9b6dc824d6289763ae187287231b5cb
test/session/session_mapping_test.dart	b19ba283837d0e79af4fc0712b15b267dcf4a574d67a3e165ea70dbd8988315e
```
