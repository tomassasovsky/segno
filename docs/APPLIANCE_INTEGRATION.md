# Appliance integration — September 2026

<!-- cspell:words Wrynose -->

## Source of the running release

The appliance release `0.1.0-experimental.137` was built on September 4 from
`570a7b24bfab8021f359a84a2a97b5e0177a2c60` on
`feat/appliance-flashes-console-board`:
[successful build](https://github.com/tomassasovsky/segno/actions/runs/33886519324),
[release artifacts](https://github.com/tomassasovsky/segno/releases/tag/appliance-experimental-0.1.0-experimental.137).
The owner confirmed that this release is running on the appliance.

The release tag points to `aaf042655b5059d9aff7c647a02249c1d019de84`, which
is not the workflow's source commit. Use the workflow head above when tracing
this build. Future releases explicitly target the commit being built. Existing
release tags and published artifacts are unchanged.

## Integration scope

The stack comprises [#984](https://github.com/tomassasovsky/segno/pull/984),
[#986](https://github.com/tomassasovsky/segno/pull/986), and
[#990](https://github.com/tomassasovsky/segno/pull/990). It brings the console's
UART pedal link, CTRL jack assignments and calibration, boot-time console
firmware flashing, and boot-partition OTA payload into the current master.
The obsolete USB-MIDI pedal and AVR flashing path are removed.

The integration retains master's later RTC configuration, application fixes,
and enclosure/manufacturing changes. The final hardware changes following the
released commit are also retained. The base remains Yocto Walnascar with the
6.12 kernel; the separate Wrynose work is not required for this stack.

Integration review corrections cover compatible-HELLO gating, UART resource
ownership and reconnect tests, CTRL disconnect/unplug behavior, calibration
persistence, boot-file producer dependencies, and release-tag provenance.
These corrections make the integrated tree different from release 137.

## Hardware boundary

The running firmware targets the v2 console board: Pico 2, direct encoder and
NeoPixel ring, and CTRL ring sensing. Earlier bench records in #984 and #990
cover end-to-end console controls, boot flashing on release 133, and the FS-6
and EX-P on release 136 with firmware 1.4 / link protocol 5. Those records do
not validate a newly integrated image.

The v3 PCB and ring-board design files are retained as hardware work in
progress. They still require:

- Console firmware for the PIO UART ring link and firmware for the ring
  board's XIAO controller.
- Firmware, protocol fields, and application display for the negotiated USB
  power contract.
- End-to-end validation of those paths on assembled v3 hardware.

A clean software test run or recorded PCB DRC does not establish v3 readiness.
The v2 top-rail unplug heuristic also remains distinct from v3's physical
presence contacts; test both pedal travel and insertion/removal on the target
board before publishing a new appliance release.

## Verification and release boundary

The owner authorized integrating and merging the stack. That authorization
covers source control, required CI, and review; it does not deploy an image or
flash an appliance. Release 137 remains the device reference until a separate
release and hardware-validation task records a newer installed build.

Software checks cover the Dart application and affected packages, the native
firmware contract and sketch behavior, appliance shell helpers, and the Linux
builds in CI. Local screenshot comparisons had the same 52 failing tests on
the unmodified master baseline; their results must stay separate from the
functional checks and remote CI.

## Startup readiness and release inspection

The narrowed #982 work retains the startup mitigation from
`7adfb722250078ab40c54274a39bf3b5e4ab43c7` on current master. It uses the boot
archive and install hook delivered by #990; it does not add the old branch's
alternate boot-image extraction or post-install hook.

Before starting the app, `segno-wait-wayland` requires a UNIX socket with the
same inode across an 800 ms settle interval. A missing or replaced socket
keeps startup waiting; exhaustion fails the launcher so systemd retries after
three seconds. The launcher also sets `SEGNO_WAVEFORM_OPEN_DELAY_MS=750` to
space creation of the secondary native view after the main view mounts.
The app honors the current preference when the delay ends and cancels a
pending open when its owner unmounts.

The bundle recipe inspects the signed artifact before deployment, using the
pinned Yocto-native RAUC, archive tools and jq. Native RAUC enables JSON
support explicitly; the release host does not need RAUC. It checks the selected
board's compatible string, release version, exactly one rootfs image and one boot archive,
nonempty payload metadata and checksums, and the boot archive's `install`
hook. The boot archive retains meta-rauc’s `.tar.img` filename for file slots.
This inspects the artifact rather than inferring its contents from the recipe.
Collection requires the exact versioned bundle filename and fails if it is
missing or empty. Signature trust remains the appliance's install-time check.

Local behavior checks use real UNIX sockets, a sandboxed launch block,
widget tests, and valid/invalid RAUC metadata. Linux CI additionally creates
signed test bundles and verifies that a rootfs-only bundle is rejected.
Run the shell suites with:

```sh
bash deploy/yocto/meta-segno/recipes-segno/segno-bundle/test/run_wayland_wait_tests.sh
bash deploy/yocto/meta-segno/recipes-core/images/test/run_bundle_slots_tests.sh
```

These checks do not establish compositor/EGL readiness, either screen's
behavior after a Weston restart, or an installed update's boot/rollback
behavior. Those remain device checks under #970 and the appliance integration
boundary above. No operating-system migration is included.
