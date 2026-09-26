# Remaining design work

**September 8 update:** use the [complete reference recheck](../research/segno-looper-x-comparison/2026-09-08-recheck/README.md) and [correction record](../research/segno-looper-x-comparison/2026-09-08-recheck/corrections.md) for the current gap list and correction order. The owner authorized fixes; Mixer is first. Existing accepted flows remain accepted.

This is a review snapshot following Tuner, external-function access and pedal
gesture feedback. It groups the remaining target UX; GitHub remains the delivery
status layer. Earlier plan language predates many accepted prototypes and must
not be interpreted as requiring them to be redesigned again.

| Area | Remaining outcome |
|---|---|
| Main Stage and two displays | Retain the reviewed main-display banked four-track overview and selected-track waveform on the small display. The interactive study now covers core capture, queued transitions, per-pass Undo/Redo and inline Mute. Production transport and complete mode/history integration remain open. |
| MIDI controls | Learn, multi-target assignments, ranges, button states, conflicts and reconnect now have a reviewed interactive reference. Real device I/O, relative/high-resolution messages and complete target coverage remain open. |
| External synchronization | Clock send/follow, transport and loss recovery have an approved UX reference. Real-device timing, clock offset, Thru, network sync and tempo-aware import remain open. |
| Wave and mode changes | Wave is owner accepted: sample-derived continuous waveforms, spaced track metadata, phrase landmarks, shared capture growth and direct foot entry. Compatible-only mode changes are owner accepted and have a tested prototype; complete production scheduling remains open. Production waveform projection and destination-first import remain open. |
| Complete mappings | Remaining assignable targets/commands, meaningful parameter names and distinct continuous, switch and enumerated types. |
| Appliance settings | Connected-interface setup, rate/buffer controls, latency calibration and recovery now have a revised prototype. Negotiated settings and missing-port reassignment remain. Wi-Fi joining, remembered networks and recovery have an owner-accepted prototype; real connectivity remains. Displays and per-screen touch calibration have an owner-accepted prototype. Storage and safe USB eject are owner accepted at prototype level. Safe shutdown and restart are owner accepted at prototype level. Software updates are owner accepted at prototype level; real installation, controller firmware and boot recovery remain. |
| Remaining media operations | Whole-session USB backup and restore, including the useful waveform preview, are accepted. Backing seek/end/repeat has an interactive proposal. Bulk/appliance backup, stems and DAW export remain. |
| Consistency and recovery | Wire accepted Undo/Redo decisions through every edit; review audibility/repair paths and reconcile stale proposal labels against owner decisions. |

Wave performance refinement is accepted. Existing-audio loop-mode changes now implement the approved compatible-only path. The owner authorized starting
these remaining areas after reviewing this list. That is authorization to develop
the design, not acceptance of a particular display-role split.

Production delivery remains separate: integrate accepted UI, prove session fidelity
and durable storage, implement processing/control contracts, delete replaced code,
and validate the appliance. Neither browser checks nor native Pen alignment prove
audio or hardware behavior. Preserve Linux appliance scope and macOS dev launching.

Sources: [programme](README.md), [delivery slices](../plan/2026-09-05-feat-appliance-ux-roadmap-plan.md#delivery-slices-and-dependencies),
[mapping gaps](../design/2026-09-07-pedal-mapping-catalogue.md#missing-mappings-and-catalogue-cleanup),
and [performance contracts](../design/2026-09-06-pedal-performance-contracts.md).

[MIDI controls and Learn](../design/2026-09-07-midi-controls-ux.md) records the reviewed behavior and validation boundary.

[Clock & sync](../design/2026-09-07-midi-sync-ux.md) records the owner-approved direction and hardware-validation boundary.

[Existing-audio mode changes](../design/2026-09-07-loop-mode-transitions-ux.md) records the approved compatible-only path: immediate while stopped, explicit Stop loops and switch during playback, and short reasons for incompatible choices. It replaces the fixture-only content lock; automatic conversion is excluded. Browser and Pen verification cover the prototype, not production mode scheduling.

[Audio device setup](../design/2026-09-07-audio-device-ux.md) replaces the rejected interface-picker-first draft with connected-interface controls and recovery. The current review is positive; explicit acceptance and real-device validation remain separate.

[Wi-Fi setup](../design/2026-09-07-network-ux.md) is owner accepted: Settings → Network, password entry, saved connections, radio state and recovery. Network changes leave music running. Hardware connectivity remains separate.

[Displays and touch calibration](../design/2026-09-07-display-settings-ux.md) is owner accepted: Track display first, independent brightness, idle dimming and verified calibration with cancellation and recovery. Storage and safe USB eject are now owner accepted. Safe shutdown and restart are now owner accepted; software updates are also owner accepted.

[Storage and safe eject](../design/2026-09-07-storage-ux.md) is owner accepted. Library cleanup, filesystem support and real mount/unmount operations remain separate.

[Safe shutdown and restart](../design/2026-09-07-safe-power-ux.md) is owner accepted. It finishes captures, saves the session, and stays on when saving fails. Hardware power sequencing and durable writes remain production work.

[Software updates](../design/2026-09-07-software-updates-ux.md) is owner accepted: check, download or USB preparation, explicit safe restart and simulated rollback. Whole-session USB backup and restore, including its waveform preview, is owner accepted.

[Session backup and restore](../design/2026-09-07-session-backup-ux.md) copies one complete session and its referenced media, with explicit duplicate handling and restore as a new Library entry. The owner accepted the flow and revised waveform preview; real disk recovery remains.
