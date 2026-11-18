# wpa_supplicant as Raspberry Pi OS runs it (#1843).
#
# Pi OS drives the radio with NetworkManager on wpa_supplicant, the Debian
# wpasupplicant package (trixie: 2:2.10-24+rpt3). This image builds poky's
# wpa_supplicant 2.11. The version stays poky's; everything Debian's package
# sets around the binary is reproduced here, from salsa.debian.org/debian/wpa
# at tag debian/2%2.10-24 (2414487d):
#
# - wpa_supplicant.service and the D-Bus activation file: upstream's, with
#   Debian's patches 07_dbus_service_syslog, wpa_service_ignore-on-isolate,
#   systemd-add-reload-support and wpa_service_netdev applied. `-s` logs to
#   syslog (the journal, as `wpa_supplicant`), and `-O` gives every interface
#   NetworkManager adds a control socket in /run/wpa_supplicant, so
#   `wpa_cli -i wlan0 status` works as on Pi OS.
# - The netdev group those name. Debian creates it in base-passwd; poky has
#   none, and without it wpa_supplicant cannot create the control socket for
#   wlan0, so NetworkManager could not add the interface at all.
# - The D-Bus policy with Debian's netdev group (02_dbus_group_policy).
# - The unit enabled at boot. debhelper enables it on Pi OS (WantedBy=
#   multi-user.target); NetworkManager also starts it through D-Bus
#   activation if it is not running yet.
# - /usr/lib/NetworkManager/conf.d/no-mac-addr-change.conf, which Debian ships
#   in wpasupplicant (debian/wpasupplicant.install).
# - The build options in Debian's debian/config/wpasupplicant/linux that
#   upstream's defconfig, which poky builds from, leaves out. Among them are
#   OWE (Enhanced Open networks), WEP, WNM (802.11v BSS transition), MBO and
#   OCV. Three are left out on purpose: CONFIG_PCSC needs pcsc-lite, and the
#   SIM-card EAP methods that use it (EAP-SIM, EAP-AKA, EAP-AKA') go with it,
#   since this console has no smart-card reader; CONFIG_READLINE needs
#   readline and only adds line editing to wpa_cli; CONFIG_EAPOL_TEST builds
#   a test tool Debian ships in a separate package. CONFIG_IEEE80211N and
#   CONFIG_IEEE80211W are not options any more in 2.11 (both always on).

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI += " \
    file://wpa_supplicant.service \
    file://fi.w1.wpa_supplicant1.service \
    file://dbus-wpa_supplicant.conf \
    file://no-mac-addr-change.conf \
"

do_configure:append() {
    cat >> ${S}/wpa_supplicant/.config <<'EOF'
CONFIG_ACS=y
CONFIG_AUTOSCAN_EXPONENTIAL=y
CONFIG_AUTOSCAN_PERIODIC=y
CONFIG_BGSCAN_LEARN=y
CONFIG_DEBUG_LINUX_TRACING=y
CONFIG_DEBUG_SYSLOG_FACILITY=LOG_DAEMON
CONFIG_DELAYED_MIC_ERROR_REPORT=y
CONFIG_DRIVER_NL80211_QCA=y
CONFIG_DRIVER_NONE=y
CONFIG_EAP_EKE=y
CONFIG_EAP_PSK=y
CONFIG_FILS=y
CONFIG_FILS_SK_PFS=y
CONFIG_FST=y
CONFIG_GETRANDOM=y
CONFIG_HT_OVERRIDES=y
CONFIG_VHT_OVERRIDES=y
CONFIG_MBO=y
CONFIG_MESH=y
CONFIG_OCV=y
CONFIG_OWE=y
CONFIG_PMKSA_CACHE_EXTERNAL=y
CONFIG_SUITEB=y
CONFIG_SUITEB192=y
CONFIG_TLSV11=y
CONFIG_TLSV12=y
CONFIG_TLS_DEFAULT_CIPHERS="DEFAULT@SECLEVEL=1"
CONFIG_WEP=y
CONFIG_WNM=y
CONFIG_WPS_ER=y
CONFIG_WPS_NFC=y
CONFIG_WPS_REG_DISABLE_OPEN=y
EOF
}

do_install:append() {
    install -m 0644 ${UNPACKDIR}/wpa_supplicant.service \
        ${D}${systemd_system_unitdir}/wpa_supplicant.service
    install -m 0644 ${UNPACKDIR}/fi.w1.wpa_supplicant1.service \
        ${D}${datadir}/dbus-1/system-services/fi.w1.wpa_supplicant1.service
    install -m 0644 ${UNPACKDIR}/dbus-wpa_supplicant.conf \
        ${D}${sysconfdir}/dbus-1/system.d/dbus-wpa_supplicant.conf
    install -d ${D}${nonarch_libdir}/NetworkManager/conf.d
    install -m 0644 ${UNPACKDIR}/no-mac-addr-change.conf \
        ${D}${nonarch_libdir}/NetworkManager/conf.d/no-mac-addr-change.conf
}

FILES:${PN} += "${nonarch_libdir}/NetworkManager/conf.d/no-mac-addr-change.conf"

SYSTEMD_AUTO_ENABLE = "enable"

inherit useradd
USERADD_PACKAGES = "${PN}"
GROUPADD_PARAM:${PN} = "--system netdev"
