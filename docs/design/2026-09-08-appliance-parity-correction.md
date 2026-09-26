# Appliance and MIDI parity correction

September 8, 2026. This changes the HTML studies and a concrete production plan.
It does not change the audit baseline, production code, firmware or hardware.

## Verified reference and current hardware

The supplied Looper X guide, printed page 40, specifies **−10 through +10 ms**
for sent MIDI clock, and **MIDI In → MIDI Out** for MIDI Thru. The extracted
`AppUI/Pages/GlobalSettings.qml` uses `transMIDIOffset.unnormalized` with `ms`
and `midiThroughEnabled`. It does not expose the offset step or establish a
multi-port feedback policy. Guide page 41 and the same QML expose firmware,
hardware identity and licenses.

The current Segno console is a **Pi 5 with console board v2, Pico 2 / RP2350**,
connected by a keyed GPIO ribbon. This is documented in
[`hardware/console/README.md`](../../hardware/console/README.md). The earlier
USB ATmega32U4 board remains a standalone pedal product. Current
[`PedalFirmwareCubit`](../../lib/update/cubit/pedal_firmware_cubit.dart) and
[`segno-update-ctl`](../../deploy/yocto/meta-segno/recipes-segno/segno-bundle/files/segno-update-ctl)
provide useful update/recovery lifecycle evidence, but their Caterina/avrdude
path is **not an RP2350 console updater**. A generic “controller firmware” label
must not hide that gap.

## Implemented prototype paths

`midi-sync-study.js` adds a sender offset per existing output and a DIN Thru
switch. The UI uses the documented range, zero reset, direct touch, encoder
edit/commit/cancel and persistence-failure handling. A 1 ms editing increment
and positive=later/negative=earlier are explicit Segno UI conventions; they are
not claims about the native Looper X translator's resolution or sign mapping.

Sender offsets apply to internally generated clock. External-clock relay keeps
its received timing, with offsets unavailable until Internal is selected. An
unseen incoming clock pulse cannot simply be sent earlier. Outgoing prototype
events expose `nominalAt`, `scheduledAt`, `offsetMs` and `simulated:true`; they
are timing intentions, not a native real-time scheduler or measured MIDI IO.
They do not change session tempo, incoming clock estimation or loop position.

DIN Thru forwards a raw incoming message once, at its received timestamp.
Generated/relayed sync on DIN Out is suspended while Thru is on, avoiding two
clock paths to the same connector. Other output settings remain available.
The forwarder accepts only physical-input-origin traffic from the DIN input;
it excludes its own output/forwarded events. MIDI Learn/control filtering is
independent. This prevents local software recirculation; an external cable
loop still requires a hardware routing policy and testing. Existing source
selection, Follow Play/Stop and clock-loss recovery remain intact.

`appliance-parity-study.js/.css` adds About, an in-place expandable notices
list, and a controller-update view. Unknown identity facts are omitted;
controller status remains available when no version is reported. Firmware
release and wire protocol are distinct. A recorded version is labeled **Last
flashed by this console**, never treated as a fresh identity reply.

The controller lifecycle demonstrates verified/target-matching package gates,
idle performance, restart entry, temporary pedal unavailability, bounded retry,
disconnect/stall, and distinct not-started/interrupted recovery. Only an image
readback confirmation and controller re-enumeration can complete the simulated
write. Version-record persistence must then succeed. Earlier interrupted
attempts cannot be reclassified as harmless after a later preparation failure.
An interrupted attempt is retried only after `retryReady` explicitly confirms
that a usable update connection returned; a remembered connection flag is
insufficient.
The thresholds mirror the existing production lifecycle (three attempts,
eight-minute retry budget, six-minute silent-attempt limit); execution is
entirely simulated. No rollback guarantee is invented for controller flash.

The model defaults to `updateSupported:false`. A matching target and explicit
update capability are required. Test fixtures opt into simulated support;
that does not establish RP2350 update support.

`appliance-reference-notices.js` includes exact checkout texts for Segno, CLAP
and VST3 SDK. The UI labels this a reference set. It does not claim that three
notices are the complete application distribution. Production reuses
[`readConsoleLicencePackages`](../../lib/system/view/console_licences_sheet.dart)
and the complete installed-build registry, including native bundled notices.

## Main HTML integration (applied)

The coordinator temporarily delegated the shared HTML for this integration.
The following hooks are applied in `fx-ux-prototype.html`.

1. Existing MIDI sync script/style loads pick up their owned-file changes.
   Add `appliance-parity-study.css`, `appliance-reference-notices.js`, then
   `appliance-parity-study.js` before the main script.
2. Route sync range events before generic FX ranges:
   `if(id.startsWith('sync:offset:')) syncUI.input(id,value,screen)`.
   `turn` calls `syncUI.turn(delta)` before focus navigation; encoder press
   calls `syncUI.finish()`. Back cancels with `syncUI.finish(true)` and returns
   if it handled an edit. Double-tap reset calls `syncUI.resetOffset(id)`.
   Add `syncUI.editingAction` to the existing focused/editing decoration.
   Finish or cancel an edit when leaving Clock & sync.
3. Keep `syncUI.receive(port,type,at)` for clock/transport; it forwards the raw
   DIN timing message itself. For other physical MIDI input, call
   `syncUI.receiveMessage(port,message,at,'input')` alongside `midiUI.receive`.
   Never feed a timing message through both entry points. Never feed outgoing
   messages back as input. The optional fourth argument can identify output
   origin and is rejected by the forwarder.
4. Create `applianceUI=window.createApplianceParityStudy({...})` with:

   ```js
   {button,header,escape,render,focus:setFocus,
    facts:()=>({appVersion:updatesUI.snapshot().settings.current}),
    readController:()=>savedControllerPreview,
    writeController:value=>persistControllerPreview(value),
    capturing:()=>/* active capture */,
    playing:()=>/* loop/backing playback */,
    transferring:()=>/* USB/app update/session transfer */,
    restart:request=>powerUI.requestRestart(request),
    updates:()=>go('updates'), stage:()=>go('stage'),
    open:view=>{applianceUI.enter(view);go('appliance');},
    active:()=>page==='appliance'}
   ```

   Controller preview persistence is appliance-owned, outside musical session
   recall. Its state contains `{connected,target,updateSupported,installed,
   protocol,versionSource,pending}`, where `pending` contains
   `{version,protocol,target,verified}`. Use explicitly simulated values in the
   review fixture; do not import a remembered AVR version as an RP2350 fact.
5. Add `page==='appliance'?applianceUI.body()` and the `appliance-study` class.
   Expose About from Settings or Updates, and Controller firmware from Updates
   or External pedals. The helper handles `appliance:about`,
   `appliance:controller`, `appliance:licenses` and its own action prefix.
   It does not require another large Settings tile or edits to other agents'
   files; a secondary header action preserves the accepted ten-tile menu.
6. While `applianceUI.busy()` is true, block navigation and performance input
   at the shared dispatcher, including physical pedal/encoder/MIDI input; keep
   the controller page visible. After an interrupted write, use
   `controllerAvailable()` for physical-controller input while allowing touch
   continuation. Do not claim that a controller works merely because the user
   dismissed the failure screen.
7. Add `applianceUI.tick()` to the existing timer and call
   `applianceUI.back()` on Back. Review hooks: `applianceState:applianceUI.snapshot`
   and `simulateAppliance:applianceUI.simulate`. Failure fixtures use
   `{failure:'not-started'}` or `{failure:'interrupted'}`, and
   `{returning:false}` exercises failure after programming. All are visibly
   labeled simulation. No actual updater is called.

## Production, removal and hardware gates

| Slice / audit rows | Smallest complete implementation and reuse | Removal and observable gate |
|---|---|---|
| MIDI sender offset, 162 | Add a per-port output-clock policy through presentation → bloc → repository → native MIDI scheduler. Reuse the accepted sync source/loss state. Schedule internal-clock pulses against one monotonic clock with an advance window covering negative offsets. Rebase future events on tempo/source changes and clamp only to the documented UI domain. | Remove generic/immediate duplicate emit paths once the scheduler owns all clock output. Test ±10/0 ms, 24 PPQN, start/continue/stop, rapid tempo changes, disconnect, bounded queues and no audio-callback allocation. Measure real DIN/USB latency and jitter; prototype timestamps do not close this gate. |
| MIDI Thru, 163 | Add explicit DIN input→output routing before control-channel filters. Preserve supported message bytes, including SysEx and realtime interleaving; serialize with generated traffic according to the chosen DIN exclusivity policy. Use distinct input/output identities and a single routing owner. | Remove second forwarding paths and any short-message-only assumption from this route. Test Note On/Off, CC, pitch, program, SysEx, clock/transport, malformed/truncated input, disconnect, same-port bookkeeping and external feedback loops. MIDI Learn may ignore a message while Thru still forwards it. |
| About/licenses, 174 | Reuse ConsoleFactsCubit, actual engine device facts, UpdateCubit, controller identity/last-written state and readConsoleLicencePackages. Present release version separately from protocol. Obtain this build's native notices in the same registry. | Replace old System/Settings About entry points after the new destination is reachable. Remove preview facts/reference-only notice assets from production. Test unknown serial/version omission, controller missing/error, exact registry text, package count/list consistency, search/scroll/focus and asynchronous load failure. |
| Controller firmware, 176 | Identify the current RP2350 console board and transport. Define its authenticated target manifest, update capability, bootloader entry, image verification, reconnect and physical recovery. Reuse the existing updater's lifecycle/failure-class lessons, not its AVR command. Keep the standalone AVR updater behind its correct product identity. | Remove hand-entered protocol/version claims and any generic flasher dispatch that could target the wrong MCU. Package and test the RP2350 adapter only after board validation. Gate checksum/target mismatch, interruption before/during write, stalled helpers, bounded retry, durable last-written version, unknown old failure marker, re-enumeration and recovery from bootloader. Run firmware protocol-drift tests for either tree when changed. |
| Phones and tuner audition, 107/138/144 | Discover the chosen interface's physical headphone bus, controllable gain and direct-monitor paths. Name a Phones role only when independently addressable. Route tuner audition and dry sends to that verified destination, with independent output ownership and level. | Never substitute “Monitor output” or generic pair gain for Phones. Preserve main output when Phones is unavailable; show only verified controls. Bench-test main/Phones isolation, mute/audition return, physical knob linkage, reconnect and interface replacement. |
| Computer USB audio, 148–150 | First prove an externally accessible device-mode port/controller on the actual Pi 5/enclosure topology. The documented rear USB-C connection is the PD power path, not proof of data/gadget access. If adopted, build an explicit UAC2 service and stereo host-return routing/level plus Live/DAW monitoring ownership. Advertise only negotiated rates. | Do not add a fake mode switch to the host-interface selector. Remove unsupported options. The guide's 88.2 kHz discrepancy remains recorded; test actual descriptor negotiation, sample-clock drift, hotplug, duplex audio, dropout/recovery and power/data wiring. Hardware/product decision remains open. |
| Computer Transfer, 151–153 | Decide whether computer mass-storage mode belongs in the product after device-mode feasibility. If adopted, use one storage owner: save/close audio → unmount/export selected volume → host eject → detach gadget → fsck/remount/reconcile → resume. USB audio and mass storage require explicit mutually exclusive transitions and recovery. | Keep managed internal copies and USB-stick import/export. They are not computer Transfer. Never expose the mounted live session filesystem to two writers. Test refusal during capture/transfer, cancelled handoff, cable/power loss, host-eject failure and corrupted media before offering a user-facing control. |
| Physical capacity/control, 173 and associated hardware rows | Enumerate actual input/output/CTRL/MIDI capability from interface/board identity. Phantom power, ground lift and line/amp controls appear only when the chosen device reports and can control them. | Remove fixed claims copied from Looper X. Verify the real interface and assembled console, not only desktop audio enumeration. |

USB gadget support, independent Phones hardware, and RP2350 flashing remain
explicit hardware/product gates. They are not closed by adding a menu name.
These gates do not prevent completing and reviewing the verified local UX.

## Verification

`node --test docs/design/appliance-parity.test.cjs` exercises the actual sync
module and controller model: offset bounds/commit/cancel/reset/failure,
source/tempo isolation, Thru origin and copy semantics, duplicate-clock
suppression, external lock/loss/transport, recording guard, package/target
gates, retry and interrupted-write ownership, disconnect/stall limits,
readback/reconnect/version-record requirements, exact license-source bytes
and About unknown-fact omission. No native firmware or appliance tests are
claimed by this prototype work.

`node docs/design/appliance-parity.browser.cjs` passed isolated Chrome checks
for clock-offset touch, DIN Thru ownership, external-offset guarding, sync
canvas bounds, About version-source labels, exact license text, and simulated
restart/progress/readback/reconnect completion. It uses the current main-page
styles and reports no browser errors. `SEGNO_CHROME_EXECUTABLE` overrides the
Chrome path; `SEGNO_APPLIANCE_SCREENSHOT` optionally writes sync/controller
screenshots. Shared-page integration is also verified below. Pen synchronization remains
a coordinator check.


## Shared-page verification and review fixtures

`appliance-main-integration.cjs` passed in Chrome and Firefox. It opens the real
prototype and checks the Settings About entry (the existing ten tiles stay),
Updates → Controller firmware, exact notice text and wheel scrolling, unknown
identity omission, disabled hardware capability, restart cancellation, saved
restart followed by simulated programming, navigation/performance/MIDI gates,
verified completion, not-started versus interrupted recovery, touch
continuation, clock offset touch/encoder/Back cancellation and DIN forwarding
origin. The optional `SEGNO_APPLIANCE_PREVIEWS` directory receives browser
screenshots. Both browser runs reported no page errors. These are author-only
prototype checks, not device or production update validation.

Use `fx-ux-prototype.html?review=` with these names:

- `appliance-about`, `appliance-licenses` (expand a notice in place).
- `controller-unsupported` (the normal current-console capability state).
- `controller-pending`, `controller-updating`, `controller-not-started`,
  `controller-interrupted` (visibly simulated capability, versions and results).
- `sync-offset`, `sync-thru` (source-backed range and explicit timing simulation).
- `stage-imported-duration` (7.5 beats with no materialized audio array).
- `session-empty` (New loop returns to the accepted empty Tracks view).

The integration also fixes MIDI Learn's direct Stage exit, clears its draft,
and preserves saved device mappings. Stage and Save audio now share
`trackDurationBeats`: imported `durationBeats` wins over the intentionally empty
`audio` array. The imported fractional-loop fixture stays finite on Stage;
the independent lifecycle review confirms a 24-second / 120 BPM source adapted
to 84 BPM exports 34.285714 seconds. Empty track duration is zero and its
fallback Stage position is finite.

The mapping agent's journal hooks are integrated: complete track snapshots,
a shared `rig.editHistory`, no legacy per-tool commit/history callbacks, and
import's complete before snapshot. New-session completion explicitly chooses
the accepted Stage view. The mapping agent owns journal implementation and
its behavioral verification.


Intentionally unequal `performance-*` transform fixtures now identify their
mode as Free before any fixture action. `performance-multiply-multi` provides
an independent equal-eight-beat Multi case. Both browsers assert fixture mode
and that attempting one incompatible resize leaves the complete rig unchanged.
The host applies only changed fields when restoring/editing track snapshots;
layer-only edits do not materialize unrelated defaults or reorder effect racks.
The shared imported-duration and new-session checks also pass after these hooks.
