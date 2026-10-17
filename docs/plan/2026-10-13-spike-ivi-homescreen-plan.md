---
title: "Spike: Segno on ivi-homescreen — DRM/KMS, no Weston, no GTK (Pi 5)"
type: spike
date: 2026-10-13
---

<!-- cspell:words libepoxy Wrynose libapp pixman gitsm libdisplay libdrm libxkbcommon libseat EDID SIGSEGV unmapping -->

## Spike: Segno on ivi-homescreen (DRM/KMS, no Weston, no GTK)

Issue: #1318 · Direction issue: #897 (part B, the display stack) · Earlier
research: `docs/research/2026-07-22-rpi5-embedded-boot-experience-research.md`
§4.3 ("Tier 3b") · The shipping stack is the Tier 3a GTK image
(`docs/plan/2026-07-23-spike-tier3a-yocto-gtk-plan.md`).

## Why

The July research recommended ivi-homescreen for an embedded Flutter appliance.
The project shipped the GTK runner under Weston kiosk-shell (Tier 3a) because
it needed no app changes. #897's compositor review later recommended staying
there. It ruled out running without a compositor because "a custom DRM embedder
costs the second window and all four plugins". ivi-homescreen was never
assessed in that review.

Since then, most of the appliance's display problems have come from that stack:

- #1302: GTK copies every Flutter frame through the CPU on the main thread
  (about 47% main-thread load). `GDK_GL=always` changes nothing.
- #970: libepoxy aborts with "Couldn't find current GLX or EGL context" when
  Weston restarts.
- #825 and #821: Weston restarts and HDMI hotplug strand the UI.
- Mitigations kept only for that stack: `segno-wait-wayland`,
  `SEGNO_WAVEFORM_OPEN_DELAY_MS`, the per-window app-id override in
  `linux/runner/my_application.cc`, and `PartOf=segno.service` on weston.
- #965 / #979: the Wrynose move was parked partly over the epoxy, EGL-only,
  no-GTK-X11 chain (#975).

The spike answers one question with evidence from the bench: does Segno run on
ivi-homescreen on the Pi 5, with both screens and touch, and is it better on the
four measurements below?

**This is a spike, not a migration.** The GTK/Weston image stays the shipping
default and builds unchanged. The ivi image is opt-in and built only on
dispatch. It may be published to the experimental channel only, never to
production. Whether to switch the shipping stack
stays the owner's call under #897.

## What was established before building (2026-10-13)

Sources: ivi-homescreen `v3.0` at `80f9ea4` (2026-10-12), meta-flutter
`master` at `839ea10`, and Flutter's own engine source (3.47.7 SDK).

1. **One engine per screen, in one process, is the topology.**
   - ivi-homescreen runs several `[[view]]`s from one config. Each view is its
     own `FlutterEngine` in one process, bound to an output by DRM connector
     name (`HDMI-A-1`, `HDMI-A-2`).
   - Touch is routed to a view by a libinput device-name substring.
   - Flutter's own multi-view API (one engine, several views) is also
     supported, but only the first view receives input. The 7" readout is the
     console's only touchscreen, so that mode is out.
2. **The two engines can talk without a plugin.**
   - In Flutter's engine (`runtime/dart_vm_lifecycle.cc`), every engine in a
     process shares one Dart VM, and with it one `IsolateNameServer`.
   - So each screen publishes a `SendPort` under a fixed name and looks the
     other's up. That replaces `desktop_multi_window`'s method channel.
   - Engines are separate isolate groups, so messages are limited to plain
     data. `sendableCopy` enforces that at the sender, and waveform peaks
     travel as `TransferableTypedData`.
3. **No embedder plugins are needed.** The four Linux plugins are used as
   follows:
   - `desktop_multi_window`, `window_manager` and `screen_retriever` exist only
     for the GTK second window, which the screen link replaces.
   - `url_launcher` backs the desktop-only "reveal in folder" and ASIO links,
     which have no meaning on a kiosk.
   - The audio engine is a `dart:ffi` library. Its path is given by the
     existing `SEGNO_ENGINE_LIB` override.
4. **No engine build, and no meta-flutter.**
   - meta-flutter supports Scarthgap and Wrynose, not Walnascar. Its engine
     recipe compiles from source: a fetch of more than 14 GB, about 100 GB of
     build space, and network access during the build.
   - meta-flutter also publishes prebuilt engines on GitHub
     (`meta-flutter/flutter-engine` releases). The arm64 release engine exists
     for 3.47.2, 3.47.4 and 3.47.5, but not yet for 3.47.6, 3.47.7 or 3.44.4,
     which the GTK image builds with today.
   - So the spike pins **Flutter 3.47.5**. That is inside the 3.47 line CI
     already tests. ivi-homescreen itself is built as a plain CMake recipe in
     meta-segno.
5. **One embedder gap needs a patch.** On DRM, ivi-homescreen sends window
   metrics with a pixel ratio of 1.0 whatever the view's configured
   `pixel_ratio` is (`shell/view/flutter_view.cc`). The 7" readout needs a
   ratio (below), so the recipe carries a small patch that applies the
   configured one. It is worth sending upstream.
6. **Each panel runs its native mode.**
   - The bench uses the console's own panels, not the old TV: a 1080p touch
     panel on HDMI-A-1 and the 7" 1024x600 on HDMI-A-2.
   - The GTK image drives the 7" with a 1920x1080i signal that the panel
     scales down. ivi-homescreen drives each connector's EDID-preferred mode
     instead.
   - So the readout's `pixel_ratio` is 1.6, not Weston's 3. That keeps its
     physical size: about 1.6 panel pixels per logical pixel either way, now
     at 640x375 logical, without the scaler or the interlaced link.
   - No mode is pinned. A pinned mode the connector does not list stops the
     whole process, while an unexpected native mode only resizes a
     proportional layout.

## Design

### App (Dart): one bundle, two roles

- **Role selection.** `runSegno(args)` reads `--segno-screen=main|readout`,
  which the embedder config passes to each view
  (`lib/visualizer/screen_link.dart` `segnoScreenFrom`).
  - No argument means the GTK runner, and nothing changes on that path.
  - An unknown value is treated as no argument, so a typo cannot start a
    second audio engine.
- **`readout`** runs `runReadoutScreen` (`lib/visualizer/readout_screen.dart`).
  - It owns no audio engine or repositories, and draws the existing
    `WaveformWindowApp` from what the main screen sends.
  - It is black until the main screen says `show`, so a disabled readout
    preference never flashes at boot.
- **`main`** runs the full app with `ScreenLinkWaveformService` in place of
  `DesktopMultiWindowWaveformService`, behind the same `WaveformWindowService`
  interface, so `App` does not change.
  - It skips the GTK window-plugin calls.
  - It passes no display count, because each engine is told about its own
    output only. The readout's announcement is what says a second screen
    exists.
- **The link protocol** is plain maps keyed by `op`:
  - `hello` and `ready` handshake in either start order.
  - `show` and `hide` stand in for open and close.
  - `waveform` and `readout` carry `seq` and are acknowledged with `ack`.
    That keeps the service's contract: a push that never lands completes with
    an error, and the caller re-queues it.
  - `control` carries volume-overlay commands back to the main screen.
  - A readout that announces itself again (after a restart) drops every diff,
    exactly as on the GTK path.

### Image (Yocto): same image, a different embedder

`SEGNO_EMBEDDER` (`gtk` | `ivi`) is set for the whole image by
`deploy/yocto/kas-segno-rpi5-ivi.yml`. The image name, RAUC compatible string
and partition layout stay the same, so a bench unit moves onto the spike with
`rauc install` and back with a rollback.

| Piece | gtk (shipping, unchanged) | ivi (spike) |
|---|---|---|
| Base | `core-image-weston` | same, minus the `weston` feature and its demo clients |
| Embedder | the bundle's `segno` GTK runner | `ivi-homescreen` (meta-segno CMake recipe, pinned, two patches), installed as `/usr/bin/segno` |
| Engine | `libflutter_linux_gtk.so` in the bundle | `flutter-engine-prebuilt` (meta-flutter release, arm64, 3.47.5) |
| `/opt/segno` | the whole bundle | `data/`, `lib/libapp.so`, `lib/libsegno_engine.so` |
| Launch tail | `segno-embedder-gtk` (wait for Wayland, `exec /opt/segno/segno`) | `segno-embedder-ivi` (`exec /usr/bin/segno --config /etc/segno/homescreen.toml`) |
| Unit drop-in | `segno-gtk.conf` (after and requires weston) | `segno-ivi.conf` (after plymouth quits, which frees DRM master) |
| Screen layout | `weston.ini` app-ids, pinned 1080 modes, `scale=3` | `/etc/segno/homescreen.toml` connectors, native modes, readout `pixel_ratio = 1.6` |

Guards:

- `segno-bundle` refuses an ivi bundle whose `flutter-version.json` (written
  by `segno-build.sh`) names a different engine revision than
  `flutter-engine-version.inc`. A mismatched AOT snapshot would otherwise
  build, install, boot, and die before the first frame.
- An ivi build is never published by default: the release workflow builds it
  only on dispatch, on the experimental channel, with `publish: no` unless the
  dispatcher says otherwise. Its RAUC compatible string is the shipping one, so
  a published ivi build reaches every unit polling the experimental channel.

### CI

`appliance-release.yml` takes `embedder: ivi`, which only works for rpi5 on
the experimental channel. Its version, `X.Y.Z-experimental.<run>`, is therefore
never a shipping release's version, and every later experimental build sorts
above it. That dispatch:

- builds the bundle with the pinned Flutter (`FLUTTER_VERSION` build argument);
- builds the image from `kas-segno-rpi5-ivi.yml`;
- uploads the `.wic`, `.bmap` and `.raucb` as an `-ivi` workflow artifact;
- with `publish: yes`, also publishes it to the experimental channel (owner's
  call, 2026-10-13). The release title is marked as the ivi spike.
  - Every unit on that channel is then offered it, and installs stay opt-in
    from Settings.
  - The next GTK experimental build, being newer, is offered back.

## Validated off-device (2026-10-13)

- **ivi-homescreen.** It builds with GCC 13 (C++17) using exactly the recipe's
  `EXTRA_OECMAKE`: drm-kms-egl plus the compositor, nothing else, no plugins.
  - It builds without network access once the submodules are present, so
    `gitsm://` is enough.
  - The pixel-ratio patch applies and builds.
  - The config parser accepts `homescreen.toml` and prints both views: HDMI-A-1
    at 1.0, HDMI-A-2 at 1.6.
- **Engine.** The arm64 release engine exports all 38 embedder symbols the
  shell resolves.
- **Dependencies.** Every one has a recipe at the pinned walnascar commits:
  libdisplay-info 0.2.0 (it needs at least 0.2.0), libinput 1.27.1, libdrm
  2.4.124, meta-raspberrypi's mesa 25.1.6, libxkbcommon 1.8.1, seatd 0.9.1
  (whose libseat is required at build time) and cmake 3.31.6.
- **BitBake.** Parsing the real layer stack at the pinned commits:
  - The ivi image resolves its full graph (413 recipes) with no weston and no
    GTK.
  - The GTK image's recipe list is **identical to master's**.
  - `segno-update-bundle` is skipped only because there are no signing keys
    locally.

## Known gaps, accepted for the spike

- **No touch calibrator.** `segno-touch-ctl` still persists and applies the
  libinput calibration matrix, which libinput applies whatever the compositor.
  But `weston-touch-calibrator`, the thing that measures it, is not on the ivi
  image.
- **Hotplug is shallow upstream.** A lost output parks its view and a returning
  one resumes it, with no re-modeset. The `video=HDMI-A-*:...D` command line
  already forces both connectors on, which also stops a missing HDMI-A-2 at
  boot from exiting the whole process.
- **No splash hand-off.** Plymouth quits before ivi-homescreen takes DRM
  master, the same black gap as the GTK image. ivi-homescreen has no
  first-frame hook for `plymouth quit --retain-splash`.
- **Flutter 3.47.5 on the ivi image, 3.44.4 on the GTK image.** That is a
  second variable in any comparison. Both images can be rebuilt on one version
  if a measurement needs it.
- **Skia.** Both views pass `--enable-impeller=false`, the same as the GTK
  runner. Impeller on V3D stays a separate question (#897).

## On-device checklist (blocked-verify)

Build: dispatch `appliance-release` with `board: rpi5`, `embedder: ivi`,
`channel: experimental`. Then either:

- install it from Settings, once it is published; or
- with `publish: no`, install the artifact's `.raucb` with `rauc install`, or
  flash the `.wic`.

- [ ] Boots straight to both screens: main UI on HDMI-A-1, readout on HDMI-A-2,
      no Weston process.
- [ ] Each output comes up in its panel's native mode: 1080p main, 1024x600
      readout. The journal logs the mode each view drives;
      `segno --drm-list-modes` lists what a connector offers.
- [ ] The 7" readout is the same physical size as on the GTK image
      (`pixel_ratio = 1.6`), and visibly sharper. A tap on it counts as
      activity for idle dimming, its only touch target since integration
      retired the MIX overlay: with a short idle dim set, a tap on the 7"
      alone wakes both panels.
- [ ] Touch on the main panel reaches the main UI. Touch that matches no
      view's `touch_device` goes to the first view.
- [ ] The waveform moves with playback, the readout follows the cursor and
      track states, and readout off/on in `SYSTEM / display` blanks and
      restores it.
- [ ] Audio, pedals, console board, Wi-Fi, OTA check and power button all work
      as on the GTK image.
- [ ] The app keeps the GTK image's settings: no `audio auto-start: first
      run` on the first ivi boot, and the saved rate, routing and pedal
      bindings in force.
- [ ] `segno-prof` main-thread profile shows no per-frame pixman surface work or
      GL readback (#1302's done-when).
- [ ] 15× `systemctl restart segno`: no core dumps (#970's verify).
- [ ] Cold boot to playable, against release 137 (`systemd-analyze` plus a
      stopwatch to first frame).
- [ ] Unplug and replug the 7": the readout comes back.
- [ ] Roll back to the GTK slot, and confirm the unit is unchanged.

## Bench findings (`0.1.0-experimental.166`)

The first bench run (#1318, 2026-10-13) found two defects. Both are fixed on
this branch:

- **Settings not found.** With no GApplication in the process,
  `path_provider_linux` names the support directory after the executable, so
  the app read `$XDG_DATA_HOME/homescreen/shared_preferences.json` and started
  as a fresh install. The GTK runner's directory is `$XDG_DATA_HOME/segno`.
  The ivi-homescreen recipe now installs the binary as `/usr/bin/segno`,
  which also makes `pidof segno` (the profile recorder) find it.
- **SIGSEGV on stop, 12 of 16 stops.** `Engine::Shutdown` collected the AOT
  data, unmapping `libapp.so`, while isolates spawned in the root isolate's
  group were still alive. The pedal link's reader isolate, blocked in an FFI
  `read()`, returned into unmapped code. Patch 0002 leaves the snapshot
  mapped until the process exits.

Two smaller findings from the retest on `.167`:

- **Slow stops while profiling.** While `segno-prof stack` stayed attached to
  any thread of the app, the app did not act on SIGTERM until it detached, so
  a stop landing in the profile recorder's 15-minute sample took ~10 s. #1328
  attaches per sample, and the recorder samples the main engine's UI thread on
  this image (its main thread is an idle reactor).
- **One unexplained hang.** 1 of 211 stops on `.167` hung until systemd's
  90 s SIGKILL; 150 further stop/start cycles did not reproduce it.
  `segno-ivi.conf` now aborts a stop after 15 s (a normal stop takes 0.35 s),
  so the next one leaves a core dump with every thread's stack.

## Out of scope

- Switching the shipping image: that is decided under #897.
- Sending the pixel-ratio patch upstream. It should be offered once the bench
  confirms it.
- A touch calibrator for the ivi image, the splash hand-off, and Impeller.
