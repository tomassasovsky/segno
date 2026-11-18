#!/usr/bin/env bash
# Tests for the image's network configuration against Raspberry Pi OS (#1843).
#
# The owner's direction is that Wi-Fi, network settings and connectivity work
# exactly as on Raspberry Pi OS: NetworkManager on wpa_supplicant, with Pi
# OS's files, and only the differences the A/B appliance needs
# (docs/NETWORK_PARITY.md). CI does not build the image, so these check the
# layer statically: every Pi OS file is there word for word, nothing of iwd
# is left, every file the recipe names exists and the other way round, and
# the saved-network directory is the one the iwd images used, so saved
# networks carry over.
#
# The last group parses a keyfile shaped like the console's (its non-secret
# fields, read from the console; the key is a dummy) with NetworkManager's
# own reader, `nmcli --offline`, when an nmcli that has it is installed.
set -uo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LAYER="$here/../../.."
FILES="$here/../files"
RECIPE="$here/../segno-bundle.bb"
WPA="$LAYER/recipes-connectivity/wpa-supplicant"
NM="$LAYER/recipes-connectivity/networkmanager"
IMAGE="$LAYER/recipes-core/images/segno-kiosk-image.bb"
KAS="$LAYER/../kas-segno-common.yml"
KAS_RPI5="$LAYER/../kas-segno-rpi5.yml"

pass=0
fail=0

check() {
    local label=$1 expected=$2 actual=$3
    if [ "$expected" = "$actual" ]; then
        echo "  ok   $label"
        pass=$((pass + 1))
    else
        echo "  FAIL $label"
        echo "       expected: $(printf '%s' "$expected" | sed 's/$/|/' | tr '\n' ' ')"
        echo "       got:      $(printf '%s' "$actual" | sed 's/$/|/' | tr '\n' ' ')"
        fail=$((fail + 1))
    fi
}

yesno() { if "$@"; then echo yes; else echo no; fi; }

# --- Raspberry Pi OS's files, word for word ---------------------------------

echo "NetworkManager's configuration is Pi OS's"
# Debian network-manager 1.52.1-1, debian/NetworkManager.conf.
check "NetworkManager.conf" "$(printf '%s\n' '[main]' 'plugins=ifupdown,keyfile' '' '[ifupdown]' 'managed=false')" \
    "$(cat "$NM/files/NetworkManager.conf")"
# raspberrypi-net-mods 1.4.4 (added in 46e7276a; pios/trixie at 9f03eb4a).
check "rpi-no-scan-rand-mac-address.conf" "$(printf '%s\n' '[device]' 'wifi.scan-rand-mac-address=no')" \
    "$(cat "$FILES/rpi-no-scan-rand-mac-address.conf")"
check "installed in /usr/lib, where Pi OS has it" yes \
    "$(yesno grep -qF '${nonarch_libdir}/NetworkManager/conf.d/rpi-no-scan-rand-mac-address.conf' "$RECIPE")"
# Debian wpasupplicant, debian/NetworkManager/no-mac-addr-change.conf.
check "no-mac-addr-change.conf matches brcmfmac nowhere" yes \
    "$(yesno grep -qx 'match-device=driver:eagle_sdio,driver:wl' "$WPA/files/no-mac-addr-change.conf")"
# raspi-config A12, "power save disabled".
check "default-wifi-powersave-off.conf" "$(printf '%s\n' '[connection]' 'wifi.powersave = 2')" \
    "$(cat "$FILES/default-wifi-powersave-off.conf")"
# raspberrypi-sys-mods, etc/modprobe.d/rfkill_default.conf.
check "rfkill_default.conf" "options rfkill default_state=0" "$(cat "$FILES/rfkill_default.conf")"
# RPi-Distro/firmware-nonfree 2788cb5, rpi-brcmfmac.conf (#1818).
check "brcmfmac options" "options brcmfmac roamoff=1 feature_disable=0x282000" \
    "$(grep -v '^#' "$FILES/brcmfmac.conf")"
check "the regulatory domain is on the kernel command line" yes \
    "$(yesno grep -qE '^[[:space:]]*CMDLINE:append.* cfg80211\.ieee80211_regdom=[A-Z][A-Z]( |")' "$KAS")"

echo "dnsmasq and Avahi are set up as on Pi OS"
# Pi OS ships dnsmasq-base, the program without a service.
check "dnsmasq.service is not enabled" yes \
    "$(yesno grep -qx 'SYSTEMD_AUTO_ENABLE:${PN} = "disable"' "$LAYER/recipes-support/dnsmasq/dnsmasq_%.bbappend")"
# pi-gen stage2/01-sys-tweaks, word for word.
check "avahi publishes the workstation, with pi-gen's edit" yes \
    "$(yesno grep -qF "sed -i 's/^#\\?publish-workstation=.*/publish-workstation=yes/'" "$LAYER/recipes-connectivity/avahi/avahi_%.bbappend")"

echo "wpa_supplicant starts as on Pi OS"
check "the unit's ExecStart is Debian's" \
    'ExecStart=/usr/sbin/wpa_supplicant -u -s -O "DIR=/run/wpa_supplicant GROUP=netdev"' \
    "$(grep '^ExecStart=' "$WPA/files/wpa_supplicant.service")"
check "the unit runs in group netdev" "Group=netdev" "$(grep '^Group=' "$WPA/files/wpa_supplicant.service")"
check "the D-Bus activation file is Debian's" \
    "Exec=/usr/sbin/wpa_supplicant -u -s -O /run/wpa_supplicant" \
    "$(grep '^Exec=' "$WPA/files/fi.w1.wpa_supplicant1.service")"
check "D-Bus activation goes through the unit" "SystemdService=wpa_supplicant.service" \
    "$(grep '^SystemdService=' "$WPA/files/fi.w1.wpa_supplicant1.service")"
check "the netdev group the unit names exists" yes \
    "$(yesno grep -qE '^GROUPADD_PARAM:\$\{PN\} = "--system netdev"' "$WPA/wpa-supplicant_%.bbappend")"
check "the unit is enabled" yes \
    "$(yesno grep -qE '^SYSTEMD_AUTO_ENABLE = "enable"' "$WPA/wpa-supplicant_%.bbappend")"
check "the D-Bus policy lets netdev talk to it" yes \
    "$(yesno grep -qF '<policy group="netdev">' "$WPA/files/dbus-wpa_supplicant.conf")"

# --- nothing of iwd is left -------------------------------------------------

echo "nothing of iwd is left"
# Settings, not comments, in every file bitbake or NetworkManager reads.
settings() {
    grep -rhE --include='*.bb' --include='*.bbappend' --include='*.inc' \
        --include='*.conf' --include='*.yml' "$1" "$LAYER" "$KAS" "$KAS_RPI5" 2>/dev/null \
        | grep -vE '^[[:space:]]*#'
}
check "no wifi.backend anywhere (wpa_supplicant is NetworkManager's default)" "" \
    "$(settings 'wifi\.backend')"
check "no PACKAGECONFIG iwd" "" "$(settings 'PACKAGECONFIG.*[" ]iwd')"
check "no iwd configuration or unit in the bundle" "" \
    "$(ls "$FILES" | grep -i iwd)"
check "wpa_supplicant is not masked" no \
    "$(yesno grep -qF 'systemd/system/wpa_supplicant.service' "$RECIPE")"
check "the image refuses iwd" yes \
    "$(yesno grep -qx 'PACKAGE_EXCLUDE += "iwd"' "$IMAGE")"

# --- the recipe and its files agree ----------------------------------------

echo "every file the bundle recipe names exists, and none is left over"
named=$(grep -oE 'file://[^ \\"]+' "$RECIPE" | sed 's|file://||' | sort -u)
present=$(ls "$FILES" | sort -u)
check "SRC_URI and files/ hold the same files" "$present" "$named"
units=$(sed -n 's/^SYSTEMD_SERVICE:${PN} = "\(.*\)"/\1/p' "$RECIPE" | tr ' ' '\n' | sed '/^$/d')
missing=
for u in $units; do
    [ -f "$FILES/$u" ] || missing="$missing $u"
done
check "every enabled unit is a file" "" "$missing"
for f in segno-nm-persist.service var-lib-NetworkManager.mount; do
    check "$f is enabled" yes "$(yesno grep -qE "^SYSTEMD_SERVICE:.*[ \"]$f[ \"]" "$RECIPE")"
done

# --- saved networks carry over ----------------------------------------------

echo "saved networks stay where the iwd images kept them"
# The iwd images set keyfile.path=/data/NetworkManager/system-connections in
# 99-segno-wifi.conf. The same directory means the update loads every saved
# network without moving a file.
check "keyfile.path" "path=/data/NetworkManager/system-connections" \
    "$(grep '^path=' "$FILES/segno-keyfile-on-data.conf")"
check "segno-nm-persist creates it" yes \
    "$(yesno grep -qE '^ExecStart=/bin/mkdir -p .*/data/NetworkManager/system-connections' "$FILES/segno-nm-persist.service")"
check "and NetworkManager's state directory" yes \
    "$(yesno grep -qE '^ExecStart=/bin/mkdir -p .*/data/NetworkManager/state' "$FILES/segno-nm-persist.service")"
check "which is bound at /var/lib/NetworkManager" \
    "$(printf '%s\n' 'What=/data/NetworkManager/state' 'Where=/var/lib/NetworkManager')" \
    "$(grep -E '^(What|Where)=' "$FILES/var-lib-NetworkManager.mount")"
check "before NetworkManager starts" yes \
    "$(yesno grep -qE '^Before=.*NetworkManager\.service' "$FILES/var-lib-NetworkManager.mount")"

echo "a keyfile shaped like the console's loads in NetworkManager"
# The console's MyHouseWTF_es_2.4G profile as an iwd image saved it, with a
# dummy key. Nothing in it names a backend: NetworkManager hands the psk to
# whichever supplicant it runs.
keyfile='[connection]
id=MyHouseWTF_es_2.4G
uuid=e6f358ff-ed4c-4e07-b7a2-497441a9a773
type=wifi
autoconnect-priority=114
interface-name=wlan0

[wifi]
mode=infrastructure
powersave=2
ssid=MyHouseWTF_es_2.4G

[wifi-security]
auth-alg=open
key-mgmt=wpa-psk
psk=not-the-real-key-1843

[ipv4]
method=auto

[ipv6]
addr-gen-mode=default
method=auto

[proxy]'
check "the fixture has no backend-specific key" "" \
    "$(printf '%s\n' "$keyfile" | grep -iE 'iwd|backend')"
check "the key is stored in the profile (psk-flags 0: no agent needed)" "" \
    "$(printf '%s\n' "$keyfile" | grep -E '^psk-flags=[^0]')"
# `--offline` (NetworkManager 1.42 and later) reads a keyfile on stdin and
# prints it back as NetworkManager loaded it, with no daemon involved.
offline_nmcli() {
    command -v nmcli >/dev/null 2>&1 || return 1
    printf '%s\n' '[connection]' 'id=probe' 'type=ethernet' \
        | nmcli --offline connection modify connection.id probe >/dev/null 2>&1
}
if offline_nmcli; then
    out=$(printf '%s\n' "$keyfile" | nmcli --offline connection modify connection.id MyHouseWTF_es_2.4G 2>&1)
    rc=$?
    check "nmcli --offline reads it" 0 "$rc"
    check "as a WPA-PSK network with its key" "$(printf '%s\n' 'key-mgmt=wpa-psk' 'psk=not-the-real-key-1843')" \
        "$(printf '%s\n' "$out" | grep -E '^(key-mgmt|psk)=')"
    check "with its SSID and priority" "$(printf '%s\n' 'autoconnect-priority=114' 'ssid=MyHouseWTF_es_2.4G')" \
        "$(printf '%s\n' "$out" | grep -E '^(autoconnect-priority|ssid)=')"
else
    echo "  skip nmcli with --offline is not installed here"
fi

echo
echo "network-config: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
echo "ALL PASSED"
