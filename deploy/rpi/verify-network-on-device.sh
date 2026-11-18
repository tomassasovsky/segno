#!/usr/bin/env bash
# On-device check for the Raspberry Pi OS network stack (#1843): run it from a
# workstation after installing an image with NetworkManager on wpa_supplicant.
#
#   deploy/rpi/verify-network-on-device.sh root@192.168.50.123 [step...]
#
# The host is the console's Ethernet address. Steps, in order, all by default:
#
#   stack      what runs and how it is configured; read-only
#   saved      join each saved Wi-Fi network, then join it again
#   wrongkey   a join with a wrong password on the network that is up
#   reboot     reboot the console and see Wi-Fi come back by itself
#   ethernet   pull the Ethernet cable and see Wi-Fi carry the traffic
#   router     take the access point away for a minute and see the console
#              reconnect without anyone touching it
#
# Each check prints `ok`, `FAIL` or `look` (for a value to read), with what
# was expected. `reboot`, `ethernet` and `router` ask before acting and wait
# for you to do something by hand.
#
# Never prints a Wi-Fi key. The wrongkey step compares the stored key before
# and after inside one shell on the console and prints only whether it
# changed.
set -uo pipefail

HOST=${1:?usage: $0 user@console-ethernet-address [step...]}
shift
STEPS=${*:-stack saved wrongkey reboot ethernet router}
# accept-new: the ethernet step reaches the console at its Wi-Fi address,
# which may be new to known_hosts.
SSH_OPTS=(-o ConnectTimeout=8 -o ServerAliveInterval=5 -o ServerAliveCountMax=3
    -o StrictHostKeyChecking=accept-new)

fails=0

on() { ssh "${SSH_OPTS[@]}" "$HOST" "$@"; }

# Runs a script on the console. Its lines are already `ok`, `FAIL` or `look`.
# No output at all, or ssh's own failure (255), is a failure too: a step
# whose console cannot be reached has checked nothing.
run() {
    local out rc
    out=$(on sh -s)
    rc=$?
    printf '%s\n' "$out"
    fails=$((fails + $(printf '%s\n' "$out" | grep -c '^  FAIL')))
    if [ "$rc" -eq 255 ] || [ -z "$out" ]; then
        echo "  FAIL reached $HOST over ssh (exit $rc)"
        fails=$((fails + 1))
    fi
}

ask() {
    local answer
    printf '\n%s [y/N] ' "$1"
    read -r answer </dev/tty
    [ "$answer" = y ] || [ "$answer" = Y ]
}

pause() {
    printf '\n%s, then press Enter. ' "$1"
    read -r _ </dev/tty
}

# Shell functions the console scripts share, sent ahead of each one.
LIB='
check() { if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1 (expected: $2; got: $3)"; fi; }
look() { echo "  look $1: $2"; }
wifi_state() { nmcli -t -f DEVICE,STATE device | sed -n "s/^wlan0://p"; }
wait_connected() {
    i=0
    while [ "$i" -lt "$1" ]; do
        [ "$(wifi_state)" = connected ] && { echo "$i"; return 0; }
        sleep 1; i=$((i + 1))
    done
    echo "$i"; return 1
}
'

step_stack() {
    echo "== stack: what runs and how it is configured"
    run <<EOF
$LIB
check "build" yes "\$([ -s /etc/segno/build-version ] && echo yes || echo no)"
look "build-version" "\$(cat /etc/segno/build-version)"
check "NetworkManager runs" active "\$(systemctl is-active NetworkManager)"
check "wpa_supplicant runs" active "\$(systemctl is-active wpa_supplicant)"
check "wpa_supplicant is enabled, as on Pi OS" enabled "\$(systemctl is-enabled wpa_supplicant)"
check "wpa_supplicant started as on Pi OS" yes "\$(tr '\0' ' ' </proc/\$(pidof wpa_supplicant)/cmdline | grep -qF -- '-u -s -O DIR=/run/wpa_supplicant GROUP=netdev' && echo yes || echo no)"
check "wlan0 has a control socket (wpa_cli works)" yes "\$([ -S /run/wpa_supplicant/wlan0 ] && echo yes || echo no)"
look "wpa_cli status" "\$(wpa_cli -i wlan0 status 2>&1 | grep -E '^(wpa_state|ssid|key_mgmt|pairwise_cipher|freq)=' | tr '\n' ' ')"
check "no iwd installed" no "\$([ -e /usr/libexec/iwd ] && echo yes || echo no)"
check "no iwd, regdom or tame unit left" "" "\$(systemctl list-unit-files --no-legend 'iwd*' 'segno-iwd*' 'segno-wifi-regdom*' 2>/dev/null)"
check "NetworkManager sets no backend (wpa_supplicant is the default)" "" "\$(NetworkManager --print-config | grep -E '^wifi\.backend')"
check "scan MAC randomisation off (raspberrypi-net-mods)" "wifi.scan-rand-mac-address=no" "\$(NetworkManager --print-config | grep -E '^wifi\.scan-rand-mac-address=' | head -1)"
check "power save off (raspi-config A12)" "wifi.powersave=2" "\$(NetworkManager --print-config | grep -E '^wifi\.powersave=' | tr -d ' ')"
check "saved networks on /data" "path=/data/NetworkManager/system-connections" "\$(NetworkManager --print-config | grep -E '^path=')"
check "NetworkManager's state on /data" yes "\$(grep -q ' /var/lib/NetworkManager ' /proc/mounts && echo yes || echo no)"
look "NetworkManager state files" "\$(ls /var/lib/NetworkManager | tr '\n' ' ')"
check "regulatory domain on the kernel command line" yes "\$(grep -qw 'cfg80211.ieee80211_regdom=AR' /proc/cmdline && echo yes || echo no)"
check "cfg80211 took it" AR "\$(cat /sys/module/cfg80211/parameters/ieee80211_regdom)"
check "the kernel's regulatory domain" "country AR: DFS-FCC" "\$(iw reg get | sed -n '/^global/{n;p;}')"
check "radios start blocked (raspberrypi-sys-mods rfkill_default)" 0 "\$(cat /sys/module/rfkill/parameters/default_state)"
check "NetworkManager lifted the block on wlan" 0 "\$(for d in /sys/class/rfkill/rfkill*; do [ "\$(cat \$d/type)" = wlan ] && cat \$d/soft; done | head -1)"
check "brcmfmac options (firmware-nonfree)" "options brcmfmac roamoff=1 feature_disable=0x282000" "\$(grep -h '^options brcmfmac' /etc/modprobe.d/*.conf)"
check "no dnsmasq service (Pi OS has only the program)" disabled "\$(systemctl is-enabled dnsmasq 2>/dev/null)"
check "avahi publishes the workstation (pi-gen)" "publish-workstation=yes" "\$(grep '^publish-workstation=' /etc/avahi/avahi-daemon.conf)"
look "DNS (systemd-resolved; Pi OS has NetworkManager write resolv.conf)" "\$(readlink /etc/resolv.conf) \$(grep '^nameserver' /etc/resolv.conf | tr '\n' ' ')"
look "saved Wi-Fi networks (name:uuid:autoconnect)" "\$(nmcli -t -f NAME,UUID,TYPE,AUTOCONNECT connection show | awk -F: '\$3 == "802-11-wireless" { print \$1 ":" \$2 ":" \$4 }' | tr '\n' ' ')"
look "wlan0" "\$(wifi_state)"
if [ "\$(wifi_state)" = connected ]; then
    check "power save is off on the link" "Power save: off" "\$(iw dev wlan0 get power_save)"
fi
look "NetworkManager's Wi-Fi failures this boot" "\$(journalctl -b -u NetworkManager -o cat | grep -cE 'reason .(no-secrets|supplicant-timeout|ssid-not-found).')"
EOF
    cat <<'EXPECT'
  expected: every check ok. wpa_cli shows wpa_state=COMPLETED and
  key_mgmt=WPA2-PSK while connected. The saved networks are the ones the iwd
  image had, with the same UUIDs (e6f358ff-... MyHouseWTF_es_2.4G,
  9f8d2302-... MyPhoneWTF). The state files include secret_key and
  timestamps.
EXPECT
}

step_saved() {
    echo "== saved: join each saved network on its stored key, twice"
    run <<EOF
$LIB
nmcli -t -f UUID,TYPE connection show | awk -F: '\$2 == "802-11-wireless" { print \$1 }' > /run/verify-1843-uuids
while read -r uuid; do
    ssid=\$(nmcli -e no -g 802-11-wireless.ssid connection show uuid "\$uuid")
    for round in 1 2; do
        start=\$(date +%s)
        out=\$(segno-wifi-ctl connect "\$ssid" </dev/null 2>/tmp/verify-1843-err); rc=\$?
        took=\$((\$(date +%s) - start))
        check "\$ssid join \$round" "0 {}" "\$rc \$out"
        [ "\$rc" -eq 0 ] || look "\$ssid join \$round said" "\$(tail -n 2 /tmp/verify-1843-err | tr '\n' ' ')"
        look "\$ssid join \$round took" "\${took}s"
        check "\$ssid status after join \$round" "true" "\$(segno-wifi-ctl status | sed -n 's/.*"connected":\([a-z]*\).*/\1/p')"
    done
done < /run/verify-1843-uuids
rm -f /run/verify-1843-uuids /tmp/verify-1843-err
look "no-secrets this boot" "\$(journalctl -b -u NetworkManager -o cat | grep -c 'reason .no-secrets.')"
EOF
    cat <<'EXPECT'
  expected: each join and rejoin prints ok with `0 {}` and connected true,
  in roughly 3 to 10 s. MyPhoneWTF needs the phone's hotspot on; with it off
  that network fails as `{"error":"not-found"}`, which is the right answer.
  The last network joined stays up.
EXPECT
}

step_wrongkey() {
    echo "== wrongkey: a wrong password for the network that is up"
    run <<'EOF'
uuid=$(nmcli -t -f UUID,TYPE,DEVICE connection show --active | awk -F: '$2 == "802-11-wireless" && $3 == "wlan0" { print $1 }')
if [ -z "$uuid" ]; then
    echo "  FAIL a Wi-Fi network is up (join one first: step saved)"
    exit 0
fi
ssid=$(nmcli -e no -g 802-11-wireless.ssid connection show uuid "$uuid")
before=$(nmcli -s -e no -g 802-11-wireless-security.psk connection show uuid "$uuid" | sha256sum)
since=$(date +%s)
out=$(printf '%s\n' 'not-the-key-1843' | segno-wifi-ctl connect "$ssid" 2>/tmp/verify-1843-err); rc=$?
after=$(nmcli -s -e no -g 802-11-wireless-security.psk connection show uuid "$uuid" | sha256sum)
if [ "$rc" -ne 0 ]; then echo "  ok   the join fails"; else echo "  FAIL the join fails (it succeeded)"; fi
case "$out" in
    *'"error":"wrong-password"'*) echo "  ok   reported as a wrong password" ;;
    *) echo "  FAIL reported as a wrong password (got: $out)" ;;
esac
case "$out" in
    *"\"restored\":\"$ssid\""*) echo "  ok   $ssid came back on its stored key" ;;
    *) echo "  FAIL $ssid came back on its stored key (got: $out)" ;;
esac
if [ "$before" = "$after" ]; then echo "  ok   the stored key is unchanged"; else echo "  FAIL the stored key is unchanged"; fi
echo "  look the helper's evidence: $(grep 'join failed' /tmp/verify-1843-err | tail -n 1)"
echo "  look wpa_supplicant said: $(journalctl --since "@$since" -t wpa_supplicant -o cat | grep -E '4-Way Handshake failed|TEMP-DISABLED' | tail -n 2 | tr '\n' ' ')"
rm -f /tmp/verify-1843-err
EOF
    cat <<'EXPECT'
  expected: all ok. The evidence line names
  "WPA: 4-Way Handshake failed - pre-shared key may be incorrect", and
  wpa_supplicant shows CTRL-EVENT-SSID-TEMP-DISABLED ... reason=WRONG_KEY.
  On the Network page the same attempt reads "The password for <ssid> is
  wrong." Any other code here means the classification is wrong: report the
  look lines.
EXPECT
}

step_reboot() {
    echo "== reboot: Wi-Fi comes back by itself"
    ask "Reboot the console now?" || { echo "  skip reboot"; return; }
    on 'systemctl reboot' || true
    echo "  waiting for the console..."
    sleep 20
    local i=0
    until on true 2>/dev/null; do
        i=$((i + 5)); [ "$i" -lt 300 ] || { echo "  FAIL the console came back within 5 min"; fails=$((fails + 1)); return; }
        sleep 5
    done
    run <<EOF
$LIB
up=\$(wait_connected 120); rc=\$?
check "wlan0 connected within 2 min of SSH coming back" 0 "\$rc"
look "since boot" "\$(cut -d. -f1 /proc/uptime)s"
look "joined" "\$(nmcli -t -f GENERAL.CONNECTION device show wlan0 | cut -d: -f2)"
look "NetworkManager's Wi-Fi lines this boot" "\$(journalctl -b -u NetworkManager -o cat | grep -E 'wlan0.*(Activation: starting|state change: .* -> activated|reason .no-secrets)' | sed 's/^<[a-z]*> *\[[0-9.]*\] //' | head -n 6 | tr '\n' '|')"
look "segno-wifi-retry" "\$(journalctl -b -u segno-wifi-retry -o cat | tail -n 2 | tr '\n' ' ')"
check "nothing failed" "" "\$(systemctl --failed --no-legend --plain | awk '{print \$1}' | tr '\n' ' ' | sed 's/ \$//')"
EOF
    cat <<'EXPECT'
  expected: ok on both checks; NetworkManager starts the saved network once
  and reaches activated with no no-secrets line; segno-wifi-retry says
  "wifi already connected; no retry needed" or "wifi connected".
EXPECT
}

step_ethernet() {
    echo "== ethernet: Wi-Fi carries the traffic without the cable"
    local wifi_ip
    wifi_ip=$(on "ip -4 -o addr show dev wlan0 | awk '{print \$4}' | cut -d/ -f1")
    if [ -z "$wifi_ip" ]; then
        echo "  FAIL wlan0 has an address (join a network first)"
        fails=$((fails + 1))
        return
    fi
    echo "  look wlan0 is $wifi_ip; this step reaches the console there while the cable is out"
    ask "Ready to pull the Ethernet cable?" || { echo "  skip ethernet"; return; }
    pause "Pull the Ethernet cable and wait 10 s"
    HOST_SAVED=$HOST
    case "$HOST" in
        *@*) HOST="${HOST%@*}@$wifi_ip" ;;
        *) HOST=$wifi_ip ;;
    esac
    run <<EOF
$LIB
check "eth0 is down" unavailable "\$(nmcli -t -f DEVICE,STATE device | sed -n 's/^eth0://p')"
check "the default route is wlan0" wlan0 "\$(ip route show default | awk '{print \$5}' | sort -u | tr '\n' ' ' | sed 's/ \$//')"
check "the gateway answers over wlan0" yes "\$(ping -c 3 -W 2 -I wlan0 \$(ip route show default dev wlan0 | awk '{print \$3}' | head -1) >/dev/null 2>&1 && echo yes || echo no)"
check "names resolve and the update host answers" '{"internet":true}' "\$(segno-wifi-ctl connectivity)"
look "resolv.conf nameservers" "\$(grep '^nameserver' /etc/resolv.conf | tr '\n' ' ')"
EOF
    pause "Plug the Ethernet cable back in and wait 15 s"
    HOST=$HOST_SAVED
    run <<EOF
$LIB
check "eth0 is back" connected "\$(nmcli -t -f DEVICE,STATE device | sed -n 's/^eth0://p')"
check "Wi-Fi stayed up" connected "\$(wifi_state)"
look "default routes (wired first, lower metric)" "\$(ip route show default | tr '\n' '|')"
EOF
    cat <<'EXPECT'
  expected: all ok. While the cable is out the only default route is wlan0
  and the update host answers. With it back, both default routes exist and
  eth0's metric (100) is lower than wlan0's (600).
EXPECT
}

step_router() {
    echo "== router: the access point goes away and comes back"
    cat <<'HOW'
  Use the phone hotspot: join MyPhoneWTF first (on the Network page, or
  step saved with the hotspot on). Turn the hotspot off for 60 s, then on.
  For the house router instead, apply any setting on its wireless page, which
  restarts its radio. Leave the console alone the whole time.
HOW
    ask "Is the console on the network you will take away, and are you ready?" || { echo "  skip router"; return; }
    local since
    since=$(on 'date +%s')
    pause "Take the access point away now, wait 60 s, bring it back"
    echo "  watching for up to 10 minutes..."
    run <<EOF
$LIB
up=\$(wait_connected 600); rc=\$?
check "reconnected by itself within 10 min" 0 "\$rc"
look "waited after you pressed Enter" "\${up}s"
look "joined" "\$(nmcli -t -f GENERAL.CONNECTION device show wlan0 | cut -d: -f2)"
look "NetworkManager's reasons" "\$(journalctl --since @$since -u NetworkManager -o cat | grep -oE 'wlan0.*reason .[a-z-]+.' | grep -oE 'reason .[a-z-]+.' | sort | uniq -c | tr '\n' ' ')"
look "wpa_supplicant's events" "\$(journalctl --since @$since -t wpa_supplicant -o cat | grep -oE 'CTRL-EVENT-[A-Z-]+' | sort | uniq -c | tr '\n' ' ')"
look "segno-wifi-retry" "\$(journalctl --since @$since -u segno-wifi-retry -o cat | tail -n 3 | tr '\n' ' ')"
EOF
    cat <<'EXPECT'
  expected: ok, usually within a minute of the access point coming back.
  NetworkManager or segno-wifi-retry reconnects; a no-secrets reason may
  appear (a drop during the handshake), and if it does segno-wifi-retry's
  lines show the attempt that joined on the stored key.
EXPECT
}

for step in $STEPS; do
    case "$step" in
        stack|saved|wrongkey|reboot|ethernet|router) "step_$step"; echo ;;
        *) echo "unknown step: $step" >&2; exit 2 ;;
    esac
done

echo "verify-network: $fails failed"
[ "$fails" -eq 0 ]
