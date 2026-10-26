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
# RuntimeWatchdogSec=60s: if PID 1 stops pinging for 60 s, the board resets.
# Not shorter, because PID 1 is not memory-locked and shares the NVMe with
# /data: nvme_core's default I/O timeout is 30 s, so a stall the drive recovers
# from can hold a page fault in PID 1 for longer than 15 s, while the audio
# engine, whose memory is locked, plays on. A short timeout would turn that
# stall into a reset in the middle of a set. 60 s rides out one full NVMe
# timeout and its retry.
#
# 60 s is longer than the hardware can count, so the kernel's watchdog core
# keeps it fed (drivers/watchdog/watchdog_dev.c). When the requested timeout
# exceeds max_hw_heartbeat_ms, a "watchdogd" kthread (SCHED_FIFO, woken by a
# HARD hrtimer) pings the hardware every max_hw_heartbeat_ms / 2 = 8 s, and
# stops once the last ping from PID 1 is older than the timeout. So:
#
# - a dead kernel (panic, hard hang) stops the kthread, and the hardware
#   resets within one hardware window of its last ping;
# - a stuck PID 1 resets just under 60 s after its last ping: the kthread's
#   last ping lands 16 s before the deadline and the 12 s window below runs
#   out first.
#
# Measured on the console: after `echo c` with kernel.panic=0 the next kernel
# banner came 13.4 s later, about 6 s of it waiting for the reset and the rest
# firmware. PID 1 frozen in its crash handler (`kill -SEGV 1`) was reset 57 s
# after the freeze.
#
# The hardware window is not 16 s. bcm2835_wdt has no set_timeout op, so
# it programs (timeout << 16) & 0xfffff ticks: the timeout in seconds modulo
# 16. 60 s programs 12 s. That is longer than the kthread's 8 s ping interval,
# so the scheme holds, but a multiple of 16 would program 0 and reset at once.
# deploy/yocto/test/run_freeze_recovery_tests.sh rejects any value whose
# window is under 10 s. Either reset is warm, so the ramoops region survives.
#
# RebootWatchdogSec=60s applies only after PID 1 has handed over to
# systemd-shutdown (killing what is left, unmounting, the final sync); while
# services stop, the runtime watchdog above still applies. That last phase
# normally takes a second or two; the watchdog only has to stop it hanging
# forever. It is fed the same way (60 s also programs a 12 s window), so a
# kernel hang there still resets within 12 s. 60 s is poky's default, set here
# so the choice is visible and tested.
#
# Tryboot is unaffected. The one-shot tryboot flag is consumed when the trial
# boot starts, so a watchdog or panic reset during a trial boot comes back on
# the committed slot, which is the fallback the A/B scheme wants; if it happens
# before segno-mark-good commits, the trial slot stays uncommitted. A reset in
# the final phase of the reboot INTO a trial happens before the kernel passes
# "0 tryboot" to the firmware, so the console boots the committed slot and the
# staged update waits for the next try.
WATCHDOG_RUNTIME_SEC = "60s"
WATCHDOG_TIMEOUT = "60s"
