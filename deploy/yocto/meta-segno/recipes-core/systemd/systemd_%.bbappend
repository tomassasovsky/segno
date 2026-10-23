# Crash evidence on the appliance (#438).
#
# systemd-coredump is not in poky's default PACKAGECONFIG, so a native fault in
# the engine currently leaves NOTHING behind: /proc/sys/kernel/core_pattern is
# `|/bin/false` on the shipped image, which discards the dump silently.
#
# WHY THIS IS SAFE, stated because #430 broke a release by naming a
# PACKAGECONFIG whose RDEPENDS could not be provided, and #438 flagged that risk
# for exactly this change. From poky walnascar's systemd_257.6.bb:
#
#   PACKAGECONFIG[coredump] = "-Dcoredump=true,-Dcoredump=false"
#   PACKAGECONFIG[elfutils] = "-Delfutils=enabled,-Delfutils=disabled,elfutils,,libelf libdw"
#
# `coredump` carries no DEPENDS and no RDEPENDS at all — it is a pure meson
# switch. `elfutils` adds a build DEPENDS on `elfutils`, which is in poky
# (meta/recipes-devtools/elfutils), and RRECOMMENDS (not RDEPENDS) on libelf and
# libdw. The recipe already packages `coredumpctl` and `coredump.conf`, and adds
# the `systemd-coredump` system user itself via USERADD_PARAM. Nothing here is
# unprovidable.
#
# `elfutils` is what turns a core file into a BACKTRACE in the journal rather
# than a blob nobody on the unit can read — which is what #438 actually asked
# for, since there is no gdb on this image.
#
# NOT `minidebuginfo`. Poky's own default enables this pair via that
# DISTRO_FEATURE, and it would give better backtraces (a compressed symbol table
# embedded in every stripped binary, so static functions get names too) — at the
# cost of touching every package in the image and growing all of them. The
# engine's crash sites are exported `le_*` symbols in a shared object, so the
# dynamic symbol table already names them. If a backtrace ever lands inside a
# stripped static function and stops being readable, minidebuginfo is the
# upgrade, and it is one DISTRO_FEATURES entry away.
#
# Plain `:append`, no `:pn-systemd`. A systemd_%.bbappend can only ever apply to
# systemd_<version>.bb, so pn-systemd is already in OVERRIDES by the time this
# is parsed and the qualifier buys nothing. It costs something, though: pn- is
# the local.conf/distro idiom, and carried in recipe space it invites the line
# to be copied into an include or a differently-named recipe, where it would
# evaluate to nothing at all. A PACKAGECONFIG that looks set and is not is
# exactly the shape of #430.
PACKAGECONFIG:append = " coredump elfutils"

# Kernel crash records on /data (#1437).
#
# `pstore` builds systemd-pstore, which at boot moves whatever the kernel left
# in /sys/fs/pstore (the ramoops region: panic and oops dmesg, the console copy)
# to /var/lib/systemd/pstore and logs it to the journal. On this image that
# directory is a bind mount onto /data (var-lib-systemd-pstore.mount in
# segno-bundle). Like `coredump`, it is a pure meson switch in poky walnascar's
# systemd_257.6.bb, with no DEPENDS and no RDEPENDS:
#
#   PACKAGECONFIG[pstore] = "-Dpstore=true,-Dpstore=false"
#
# The binary and unit land in the main systemd package, and systemd's own
# 90-systemd.preset enables systemd-pstore.service.
PACKAGECONFIG:append = " pstore"

# The hardware watchdog (#1437).
#
# Poky's own knobs for /etc/systemd/system.conf (systemd_257.6.bb seds them in
# at do_install). The device is the BCM2835 PM watchdog, /dev/watchdog0, which
# the Pi 5 kernel already registers ("bcm2835-wdt: Broadcom BCM2835 watchdog
# timer"). Its counter is 20 bits of 1/65536 s, so the hardware tops out at
# 15.99 s (max_hw_heartbeat_ms in bcm2835_wdt.c).
#
# RuntimeWatchdogSec=15s: PID 1 pings every 7.5 s, and if it stops for 15 s the
# board resets. 15 s is the longest timeout the hardware counts by itself, so
# nothing else (the kernel's watchdog worker) has to keep the board alive while
# PID 1 is healthy, and the margin over the ping interval absorbs a slow PID 1
# under load. The reset is warm, so the ramoops region survives it.
#
# RebootWatchdogSec=60s covers only the last phase of a reboot or power-off,
# after PID 1 has handed over to systemd-shutdown (killing what is left,
# unmounting, the final sync). That phase normally takes a second or two; the
# watchdog only has to stop it hanging forever, not hurry it. Above 16 s the
# kernel's watchdog worker feeds the hardware while the kernel is alive, so a
# kernel hang there still resets within 16 s. 60 s is poky's default, set here
# so the choice is visible and tested.
#
# Tryboot is unaffected. The one-shot tryboot flag is consumed when the trial
# boot starts, so a watchdog or panic reset during a trial boot comes back on
# the committed slot, which is the fallback the A/B scheme wants; if it happens
# before segno-mark-good commits, the trial slot stays uncommitted. A reset in
# the final phase of the reboot INTO a trial happens before the kernel passes
# "0 tryboot" to the firmware, so the console boots the committed slot and the
# staged update waits for the next try.
WATCHDOG_RUNTIME_SEC = "15s"
WATCHDOG_TIMEOUT = "60s"
