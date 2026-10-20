# Architecture review — final M3.2

Base: `da0c1f70d9815f68f9f5bb43e16f36de01a0b365`. The complete 39-path M3.2 manifest is `final-hashes.json`, fingerprint `90293cd611fb26bab771611de108652d789ea5025d99a1cf2987ecc4598cba7b`. Final file hashes were reconciled with no drift. One independent non-author reviewer performed these five roles and the bug review; a separate independent reviewer executed the adversarial probes. This reviewer authored no M3.2 product or test code and ran no duplicate broad tests or native builds. Prior native/package authorship is outside this delta.

No layer or dependency-direction violation found.

The page owns its unsaved draft and calls ControlCubit only on Save. ControlCubit owns active configuration, unavailable-configuration state and persistent uncertainty; SettingsRepository owns the opaque durable blob, serialized writes, readback and exact raw checkpoint recovery. The typed failure preserves the original storage cause and recovery outcome without leaking a storage client into presentation. Existing state is retained until durable success.

The new holds use the existing gesture lifecycle, take-lock, session-revision and release machinery. Their cancellation is included in reconfiguration and close. Record/Play remains immediate, Track Hold is restricted to Tracks, and Record Hold remains valid in Mute. The Arm overdub admission check reads one fresh repository snapshot so neither active capture nor a pending arm is cycled off; the established polled frame projection remains unchanged.

Routes reuse the established navigator guard and Stage callback pattern. The chooser owns and disposes its scroll controller. Fixed hardware positions have disabled interaction/focus, while editable fields use the established one-stop focus component. No native callback, protocol, FFI or generated binding changes occur. Existing UART/CTRL ownership and independent MIDI release obligations were source-traced and independently probed.

This slice delivers Setup Tracks. Custom editing and the accepted Mode Hold → Custom default remain explicitly assigned to the actual runtime slice, PR #1030. Current Hold → FX and Bank Hold performance recording preserve working capabilities. Retained Custom data does not imply delivered Custom execution. Host tests and desktop journeys do not prove physical pedal timing, electrical behavior or appliance ergonomics.
