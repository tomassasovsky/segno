# Avahi as Raspberry Pi OS sets it up (#1843).
#
# pi-gen announces the machine as a workstation on mDNS: stage2/01-sys-tweaks
# runs, on avahi-daemon.conf,
#
#   sed -i 's/^#\?publish-workstation=.*/publish-workstation=yes/'
#
# (RPi-Distro/pi-gen, arm64 c0d2c9f2). The same edit here; the rest of the
# file is upstream's, as Debian's is. The console is reachable as
# segno.local either way, since avahi publishes its address by default.
do_install:append() {
    sed -i 's/^#\?publish-workstation=.*/publish-workstation=yes/' \
        ${D}${sysconfdir}/avahi/avahi-daemon.conf
}
