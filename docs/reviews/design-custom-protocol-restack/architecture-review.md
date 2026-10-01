# Architecture review — final M3.3

Base: `45ec78fb8b2b5e2e118b910677c172646ca4f761`. The complete 15-path source/test/fixture manifest is `final-hashes.json`, fingerprint `1969ff20d13e9144b6b3c65196dd425d189f0a80728e94d69cfc37f04a9e024a`. Final hashes match the builder freeze and coordinator manifest without drift. One independent non-author reviewer performed these five quality roles and the complete bug review. A separate independent reviewer ran the raw-byte probes. This reviewer changed no product source or tests and ran no duplicate builds.

No architecture or dependency-direction violation found.

The incoming fourth-mode intent is ported to the existing UART architecture. The retired MIDI SysEx codec and two obsolete firmware trees remain absent. Framing, checksum, message types, byte order and payload lengths are unchanged. The release firmware marker reads the protocol from the same header; there is no stale hardcoded release version to update separately.

PedalRepository still requires exact compatible HELLO before admitting BUTTON, ENCODER or CTRL and before sending STATE. Incompatible or stale status remains visible; reconnect sends the latest remembered state. Learned calibration is cleared when trust is lost. No second interpreter or source owner is added.

Firmware STATE validation still completes before output publication. Custom changes only Mode color: track LEDs retain active-bank indexing, while the ring reads global activity and gain independently. The Flutter color switch is exhaustive over the expanded enum. Current ControlCubit and InteractionMode remain unchanged, so the wire addition does not silently enable incomplete Custom dispatch.

This is representation support only. The Custom action interpreter and accepted final Mode Hold → Custom behavior remain the next runtime slice. No physical UART, LED hue/brightness, firmware installation or appliance-validation claim follows from host checks. Exact publication-head review and remote CI remain separate coordinator gates.
