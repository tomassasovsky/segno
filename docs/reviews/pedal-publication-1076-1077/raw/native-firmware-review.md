# Independent firmware and native publication review

Base: `bedcecf2733dbde1cdddf96530e5c1749a72b710` (verified merge base with origin/master).
Reviewed code head: `0dd9214013d9a5f63e12a7cdd1d1056350c49a6a` on codex/live-ten-pills; working tree verified clean.
Reviewer made no implementation edits. Root owns Dart control/repository orchestration, CI, publication, and the consolidated full-diff report.

## Findings

No unresolved actionable findings in this bounded scope.

### Resolved during review — Clear the entire installed ring in the bench sketch

The initial bench sketch constructed a 24-pixel ring although the current connected ring has 40 pixels. It would leave pixels 24–39 latched in their previous state when entering the pill test without cycling LED power. The reviewed committed version now constructs the full 40-pixel ring; its test preloads all 40 green, executes setup, requires a 40-pixel transmitted frame, and checks every pixel is dark. The README states the full extent. Verified these exact changes at the code head above. The normal console sketch already handled all 40 correctly.

Root reports all four firmware suites and 49 protocol fixtures passing again after the fix, and successful actual Pico 2 builds of both sketches. These are root-run validation results, not separately rerun by this reviewer.

## Completed review angles

- Read all changed native C and header hunks, enclosing queue/transport functions, lifecycle setup/stop paths, existing Free/Song clock semantics, and new regression cases.
- Traced `le_engine_play` through command drain, source latching, replace/repeat/current cancellation, exact source wrap, per-frame state snapshot, synthetic STOP/PLAY logging, and target position zero. The target does not advance accidentally on the handoff frame in either channel order.
- Checked clear, stop, undo-to-empty, capture/arm, cancel-before-command-drain, mode changes, configure, and backend stop invalidation. Queue state is audio-thread-owned except lifecycle reset after the callback stops.
- Checked real-time work: bounded loops, scalar stack state, one packed 32-bit atomic publication; no new allocation, blocking I/O, locks, or DSP-owner crossover in the callback.
- Traced appended C snapshot fields into generated FFI, EngineSnapshot/PumpedNativeEngine, and the codec's logical-track + progress bytes. Queue target/progress are read from one atomic publication; integer fraction and packed bounds are safe.
- Read full console sketch diff and new bench sketch, including pin mapping, 80-pixel pill group addressing, reversed first eight groups, bank mapping, dimming/caps, gamma application, comet interpolation at circular boundaries, held position/color, level overlay restoration, goodbye, and frame timeout.
- Inspected the installed NeoPixelBus PIO/DMA implementation: Show defaults to maintained buffer consistency, copies/swaps the editing/sending buffers, and Dirty forces periodic refresh. Rendering edits the correct buffer without corrupting the in-flight DMA buffer. Its PIO allocator and the Adafruit allocator claim resources, rather than silently sharing a state machine.
- Read new/modified firmware stubs and tests and the native engine regression additions. No removed guard or test leaves the normal console path unprotected. New tests observe actual transmitted pixel buffers and true mixed audio at the boundary rather than just checking constants.
- Reviewed dependency installation changes in both firmware CI paths and fixed-version LED library installation.
- `git diff --check` passed during this independent review.

## Limits and gate

The sole bench-only finding is resolved; no unresolved actionable finding remains in the reviewed native/console/protocol/bench changes. This reviewer did not re-run firmware/native builds concurrently with the root's verification jobs, did not reflash hardware, and did not inspect hosted CI. Physical ring appearance, full queued-fill observation, and electrical current/temperature measurements are outside source review. This is a bounded review contribution, not an assertion that the entire PR has completed its independent review gate.

## Exact reviewed file content (SHA-256)

- `firmware/console_board/console_board.ino`: `765594ca92e2ff0484517a381153a86f8d207f5ffe045bfc0d90588acf40edd8`
- `firmware/console_board/pedal_link.c`: `645f80c0bedabb64e8220e71ceff7a9111e31089331a9ba1b92107955ddfbda9`
- `firmware/console_board/pedal_link.h`: `91ba245bf1c8b90a597792146666bd8f993fd2ea7f6a7f7179e00a69809ed07f`
- `firmware/led_pill_test/led_pill_test.ino`: `db5f845d265a3196e5a4aa62f6ac82f2bfd4b03dd1bac9bc20a7719a57ed80e3`
- `firmware/test/test_console_pill.cpp`: `b5e1e2b825fef6cf64bfa57a1b962de999e039e33c95e6f17ea905167c3c6731`
- `firmware/test/test_led_pill.cpp`: `ffd7c83f193db6526f24d7c03754be358466d99d7f4272e86cc865261b359a78`
- `firmware/test/test_pedal_link.c`: `6fabe8f71065eb57371958a1e9bd913e29717cad1dbc942f4d1d7e8de3d67f8b`
- `firmware/test/stubs/Adafruit_NeoPixel.h`: `3b3993640ca93c9e8fe7a5213014b4499ca4b25fa4be56e85798a7081fc80190`
- `firmware/test/stubs/NeoPixelBus.h`: `35e850e83db98cdfad53345eb87a45ac98aabdf8c46690b38f176ffe2231beef`
- `firmware/test/run_tests.sh`: `6aeddb38330072038dfbf33c8b31a2fc4ba40c345bd7091ccf13724f054b3f61`
- `packages/segno_engine/src/core/engine.c`: `385225ce9a15226687f9fe99bf6f29131988b2d5101f9eeec843b97d9782b344`
- `packages/segno_engine/src/core/engine_commands.c`: `e5b47c434cec9a89c04d7bcee3c916901d1a76f9a1a006e877d70487b869ed7d`
- `packages/segno_engine/src/core/engine_core.h`: `8ff5370216305f42bcb5730de297ff8ca0a94967c7361c132121ca312b410af7`
- `packages/segno_engine/src/core/engine_private.h`: `937dfc2efa47f19b358dc294b9d1b1d58b3297986d7b795c22b32fff594eb0e5`
- `packages/segno_engine/src/core/engine_process.c`: `34256f38c464a6abf4a61c5635a1cbff5324963e72951da2ca9b4f6b52cac3b0`
- `packages/segno_engine/src/core/engine_snapshot.c`: `c3cd2143ae3db026299acd927318daf25b87abcde8a12885a3f42e25cef68c2c`
- `packages/segno_engine/src/core/segno_engine_api.h`: `7d4519cb733e2bee9a2811d05d425b22a5efa238b14c47922ac6f31fef0231fb`
- `packages/segno_engine/src/test/test_engine_core.c`: `207feb131f16e312d803f797e21b6136507c78cab80fb71a6458dc7514f0f976`
- `packages/segno_engine/lib/src/engine_snapshot.dart`: `4ee5de7a181f244c75b3ad21ce1497eb59f0680071d2a9d211aa07d9a790fd2e`
- `packages/segno_engine/lib/src/generated/segno_engine_bindings.dart`: `da973f29c253a8ce43eafa44a2ebf8633c82aae1865494fdda984811a6f9e174`
- `packages/segno_engine/lib/src/native_audio_engine.dart`: `13bb17f0004dacbcabf514be39b363f4fb013f78503ea1f752b63a75c99d46a7`
- `packages/pedal_repository/lib/src/pedal_link_codec.dart`: `e5d7c0cc58a4cb43853cb707b407de159979a135f892c0d1b23bd7553d8b59fa`
- `packages/pedal_repository/lib/src/pedal_state_frame.dart`: `c4a4c98b026edae79baf2023fd86401ef3491e50b0e7801d96aa17d9d1151231`
