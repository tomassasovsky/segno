# NetworkManager as Raspberry Pi OS runs it (#1843).
#
# Pi OS ships Debian's network-manager (trixie: 1.52.1-1+rpt4). This image
# builds meta-networking's NetworkManager 1.50.0 with the recipe's own
# PACKAGECONFIG, which has the `wifi` option and not `iwd`: the Wi-Fi backend
# is then wpa_supplicant, NetworkManager's built-in default and the one Pi
# OS uses (Debian's debian/rules does not set config_wifi_backend_default),
# and networkmanager-wifi depends on wpa-supplicant (the recipe's
# get_wifi_deps). The DHCP client is NetworkManager's internal one on both.
#
# The one file added is Debian's /etc/NetworkManager/NetworkManager.conf,
# verbatim (salsa.debian.org/utopia-team/network-manager, tag
# debian/1.52.1-1, debian/NetworkManager.conf). The image has no
# /etc/network/interfaces, as on Pi OS, so the ifupdown plugin finds nothing
# and keyfiles hold every profile.

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI += "file://NetworkManager.conf"

do_install:append() {
    install -d ${D}${sysconfdir}/NetworkManager
    install -m 0644 ${UNPACKDIR}/NetworkManager.conf \
        ${D}${sysconfdir}/NetworkManager/NetworkManager.conf
}
