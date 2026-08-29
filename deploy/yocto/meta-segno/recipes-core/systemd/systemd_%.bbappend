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
