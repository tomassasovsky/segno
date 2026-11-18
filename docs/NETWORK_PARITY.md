# Network stack: the console against Raspberry Pi OS

Owner direction (#1843, 2026-11-18): Wi-Fi, network settings and connectivity
on the console work exactly as Raspberry Pi OS does it. The image differs only
where the appliance needs it, and each difference is listed here with its
reason. `deploy/yocto/meta-segno/recipes-segno/segno-bundle/test/run_network_config_tests.sh`
checks the files in the layer against this table, and
`deploy/rpi/verify-network-on-device.sh` checks a console after an install.

The reference is Raspberry Pi OS trixie, the current release, as of
2026-11-18. Every Pi OS fact below comes from one of these sources:

| Short name | Source |
|---|---|
| RPI | `archive.raspberrypi.com/debian`, trixie and bookworm `main/binary-arm64/Packages` (Release of 2026-11-17) |
| IMG | `2026-10-06-raspios-trixie-arm64-lite.info`, the package list of the current image (pi-gen `b2cd98a9`) |
| NM-D | Debian network-manager packaging, salsa.debian.org/utopia-team/network-manager, tag `debian/1.52.1-1` (`e0a3970c`) |
| WPA-D | Debian wpa packaging, salsa.debian.org/debian/wpa, tag `debian/2%2.10-24` (`2414487d`) |
| SM | github.com/RPi-Distro/raspberrypi-sys-mods, `pios/trixie` (`15fa4481`, 1:20260914) |
| NETM | github.com/RPi-Distro/raspberrypi-net-mods, `pios/trixie` (`9f03eb4a`, 1.4.4) |
| RC | github.com/RPi-Distro/raspi-config, `trixie` (`22cea75e`, 20261026+2) |
| PG | github.com/RPi-Distro/pi-gen, `arm64` (`c0d2c9f2`) |
| FW | github.com/RPi-Distro/firmware-nonfree (`2788cb5`, `rpi-brcmfmac.conf`) |
| NM | NetworkManager 1.50.0 source (`src/core/nm-manager.c`, `nm-policy.c`, `devices/wifi/nm-device-wifi.c`), the version the image runs |
| WPA | wpa_supplicant 2.11 source (`wpa_supplicant/events.c`, `wpa_supplicant.c`), the version the image runs |

Status: **matches** (already the same), **changed to match** (this work made
it the same), **deviates** (different, with the reason).

## Packages

| Item | Raspberry Pi OS trixie | Image | Status |
|---|---|---|---|
| NetworkManager | network-manager 1.52.1-1+rpt4 (RPI, IMG) | NetworkManager 1.50.0 (meta-networking walnascar) | deviates: the version comes with the pinned Yocto release. Same upstream project. The `+rpt4` delta adds netplan, which Pi OS uses for Imager's cloud-init first boot; the console has no such first boot. |
| wpa_supplicant | wpasupplicant 2:2.10-24+rpt3 (RPI, IMG) | wpa_supplicant 2.11 (poky walnascar) | deviates: the version comes with the pinned Yocto release. Same upstream project, one release newer. |
| iwd | not installed, not in the archive (IMG, RPI) | not installed; `PACKAGE_EXCLUDE += "iwd"` fails the build if anything pulls it in | changed to match (the image ran NetworkManager on iwd since #470) |
| iw, wireless-regdb | iw 6.9, wireless-regdb 2026.05.30 (IMG) | iw 6.9, wireless-regdb-static 2025.02.20 | deviates: wireless-regdb's version comes with the Yocto release. Same signed `regulatory.db`. |
| firmware-brcm80211 | 1:20260519-1~bpo13+1+rpt2 (RPI) | linux-firmware-rpidistro 20230625-2+rpt3 | matches: the 43455 firmware, clm_blob and nvram are byte-identical (#1818) |

## NetworkManager

| Item | Raspberry Pi OS trixie | Image | Status |
|---|---|---|---|
| Wi-Fi backend | wpa_supplicant: NetworkManager's default; Debian's `rules` does not set `config_wifi_backend_default`, and no file sets `wifi.backend` (NM-D) | the same: the recipe's `wifi` option without `iwd`, no `wifi.backend` anywhere | changed to match (was `wifi.backend=iwd`, `wifi.iwd.autoconnect=no`) |
| Build options | Debian's meson flags, iwd support compiled but unused, internal DHCP client (NM-D `debian/rules`) | the recipe's PACKAGECONFIG: wifi, nmcli, ifupdown, dnsmasq, nss, systemd; internal DHCP client | deviates: iwd support is not compiled (it is unused on Pi OS too); no ModemManager, Bluetooth or PPP plugins, since the console has no modem and no Bluetooth (#1199) |
| `/etc/NetworkManager/NetworkManager.conf` | `plugins=ifupdown,keyfile`, `[ifupdown] managed=false` (NM-D) | the same file, word for word (networkmanager bbappend) | changed to match (the image had none) |
| `/etc/network/interfaces` | absent: pi-gen excludes ifupdown (PG `scripts/common`) | absent | matches |
| Scan MAC randomisation | `/usr/lib/NetworkManager/conf.d/rpi-no-scan-rand-mac-address.conf`: `wifi.scan-rand-mac-address=no` (NETM) | the same file, word for word, in the same place | changed to match (the setting was in `99-segno-wifi.conf`) |
| `no-mac-addr-change.conf` | `/usr/lib/NetworkManager/conf.d/`, from wpasupplicant; matches the `eagle_sdio` and `wl` drivers only (WPA-D) | the same file, from the wpa-supplicant bbappend | changed to match |
| Connection MAC address | NetworkManager's default (`preserve`); nothing sets `wifi.cloned-mac-address` | the same | matches |
| Wi-Fi power save | on: Pi OS sets nothing, so the driver's default applies (brcmfmac starts with power save on). raspi-config's A12 "power save disabled" writes `/etc/NetworkManager/conf.d/default-wifi-powersave-off.conf` (RC) | that file, word for word: `[connection] wifi.powersave = 2` | deviates: the console runs on mains power, and power save makes the access point hold the console's incoming traffic (SSH, updates, the internet check) until the radio next wakes. It is the state Pi OS's own option sets, in the file it writes. New profiles no longer carry their own `powersave=2`, and `segno-wifi-ctl` no longer runs `iw ... power_save off`. |
| Saved networks | keyfiles in `/etc/NetworkManager/system-connections` | keyfiles in `/data/NetworkManager/system-connections` (`keyfile.path` in `segno-keyfile-on-data.conf`) | deviates: `/etc` is on the A/B root filesystem, which every OS update replaces; `/data` survives updates. Same directory as the iwd images used. `segno-nm-persist.service` also makes each keyfile 0600 at boot, because NetworkManager ignores one others can read and a profile restored by hand would silently vanish. |
| NetworkManager's state (`/var/lib/NetworkManager`: the Wi-Fi switch, when each profile last connected, the key for stable IPv6 addresses) | persists on the root filesystem | bound from `/data/NetworkManager/state` (`var-lib-NetworkManager.mount`) | deviates in how, matches in effect: on the A/B root filesystem every update reset it. Without the timestamps, NetworkManager treats a network used for months as never connected, and a join that times out asks an agent for a new key instead of retrying the stored one (NM `supplicant_connection_timeout_cb`). |
| DHCP client | NetworkManager's internal client (NM-D) | NetworkManager's internal client | matches |
| Connectivity check | none configured (network-manager-config-connectivity-debian is not installed, IMG) | not compiled | matches in effect |
| udev rules | NetworkManager's own (`84-nm-drivers`, `85-nm-unmanaged`, `90-nm-thunderbolt`); raspberrypi-sys-mods has none for networking (SM) | NetworkManager's own, the same three | matches |
| Interface names | `wlan0`, `eth0`: pi-gen runs `raspi-config nonint do_net_names 1` (PG stage1) | `wlan0`, `eth0`: `net.ifnames=0` on the kernel command line (meta-raspberrypi) | matches in effect |
| systemd-networkd | not installed (IMG) | installed, masked | matches in effect |

## wpa_supplicant

| Item | Raspberry Pi OS trixie | Image | Status |
|---|---|---|---|
| How it starts | `wpa_supplicant.service` enabled (debhelper), and D-Bus activated by NetworkManager through `fi.w1.wpa_supplicant1.service` with `SystemdService=wpa_supplicant.service` (WPA-D) | the same: Debian's two files, the unit enabled | changed to match (the unit was masked) |
| `ExecStart` | `/usr/sbin/wpa_supplicant -u -s -O "DIR=/run/wpa_supplicant GROUP=netdev"`, `Group=netdev`, `RuntimeDirectory=wpa_supplicant` (WPA-D patches `07_dbus_service_syslog`, `wpa_service_netdev`, `wpa_service_ignore-on-isolate`, `systemd-add-reload-support`) | the same unit, word for word | changed to match (poky's was `wpa_supplicant -u`). `-s` logs to the journal as `wpa_supplicant`, which `segno-wifi-ctl` reads; `-O` gives wlan0 a control socket, so `wpa_cli -i wlan0 status` works. |
| D-Bus policy | upstream's plus a `netdev` group policy (WPA-D `02_dbus_group_policy`) | the same | changed to match |
| `netdev` group | exists (Debian base-passwd) | created by the wpa-supplicant bbappend | changed to match: without it wpa_supplicant cannot create wlan0's control socket and NetworkManager cannot add the interface |
| Build options | Debian's `debian/config/wpasupplicant/linux` (WPA-D) | upstream's defconfig plus every option Debian adds (OWE, WEP, WNM, MBO, OCV, FILS, SuiteB, mesh, autoscan and others), except three | deviates in three: `CONFIG_PCSC` (needs pcsc-lite; with it go EAP-SIM, EAP-AKA and EAP-AKA', which read a SIM card the console cannot hold), `CONFIG_READLINE` (only line editing in `wpa_cli`), `CONFIG_EAPOL_TEST` (a test tool Debian ships separately) |
| `/etc/wpa_supplicant.conf` | not shipped | poky's sample file, unused: NetworkManager configures wpa_supplicant over D-Bus | deviates: inert |

## Regulatory domain, rfkill, driver

| Item | Raspberry Pi OS trixie | Image | Status |
|---|---|---|---|
| Wi-Fi country | `cfg80211.ieee80211_regdom=XX` in `cmdline.txt`, written by raspi-config's `do_wifi_country`, which also runs `iw reg set` (RC) | `cfg80211.ieee80211_regdom=AR` in the image's kernel command line (`kas-segno-common.yml`) | changed to match (was `segno-wifi-regdom`, a oneshot running `iw reg set` from `/data/segno/wifi-country` or `/etc/segno/wifi-country`). Deviates in one way: the country is fixed when the image is built, as in a pi-gen build with `WPA_COUNTRY`, because the console has no first-boot setup or raspi-config to choose it. The `/data/segno/wifi-country` override `segno-wifi-regdom` read is gone with it (no console used one); a console used in another country needs an image built with that country until the app can set it. |
| No country set | the kernel keeps the world domain; Wi-Fi stays soft-blocked; `/etc/profile.d/wifi-check.sh` warns at login (NETM) | does not happen: the image always sets one | not shipped: `wifi-check.sh` only reports a missing country |
| rfkill at boot | `/etc/modprobe.d/rfkill_default.conf`: `options rfkill default_state=0`, so every radio starts soft-blocked (SM). NetworkManager lifts the block at start unless Wi-Fi was switched off (NM `nm-manager.c`, `_rfkill_update_system`); pi-gen writes unblocked states for on-board Bluetooth only (PG) | the same file; NetworkManager's Wi-Fi switch persists on `/data` | changed to match. The Bluetooth state files do not apply: the console has no Bluetooth (#1199). |
| brcmfmac options | `options brcmfmac roamoff=1 feature_disable=0x282000` (FW) | the same (`/etc/modprobe.d/brcmfmac.conf`, #1818) | matches |

## Names, DNS and the rest

| Item | Raspberry Pi OS trixie | Image | Status |
|---|---|---|---|
| Hostname | `/etc/hostname`, a `127.0.1.1 <name>` line in `/etc/hosts` (PG); NetworkManager sends it in DHCP (`dhcp-send-hostname` defaults to on) | `segno`, the same `/etc/hosts` line, the same DHCP default | matches |
| DNS | NetworkManager writes `/etc/resolv.conf` itself; no systemd-resolved (IMG) | systemd-resolved runs, NetworkManager hands it the DNS servers, `/etc/resolv.conf` points at resolved's file | deviates, to change in #1849: in poky, systemd without resolved still links `/etc/resolv.conf` into resolved's directory, so the switch needs more than a PACKAGECONFIG and has to be tested on a built image before it ships. A mistake there leaves the console without DNS. |
| dnsmasq | `dnsmasq-base` only: the program NetworkManager runs when a connection shares its link, no service (IMG) | the program; `dnsmasq.service` installed but not enabled (dnsmasq bbappend) | changed to match (the service ran as a DNS forwarder for the local network) |
| Avahi | avahi-daemon and libnss-mdns; pi-gen sets `publish-workstation=yes` (PG) | the same, with pi-gen's edit (avahi bbappend) | changed to match (was `publish-workstation=no`) |
| First-boot network setup | Imager: cloud-init and netplan on trixie, `imager_custom set_wlan` on bookworm | none: networks are joined from the app | deviates: there is no Imager customisation for an appliance image |

## What the console adds on top

| Item | Raspberry Pi OS | Image | Why |
|---|---|---|---|
| `segno-wifi-ctl` | raspi-config and nmcli at a shell | the helper the app's Network page drives, through nmcli only | the console's only interface is the app. It runs no supplicant of its own (#468). |
| Why a join failed | NetworkManager's reason (`no-secrets` and so on) | `segno-wifi-ctl connect` reads wpa_supplicant's journal lines for the attempt: `wrong-password` only after "WPA: 4-Way Handshake failed - pre-shared key may be incorrect" (WPA `events.c`); `not-found`, `no-address`, else `no-connection` | on a console with no secret agent NetworkManager ends many failures that never tested the key as `no-secrets` (NM `nm-device-wifi.c`), and the app once told the owner a good password was wrong (#1817) |
| `segno-wifi-retry` and its dispatcher hook | none | retries a saved network with its stored key, at boot and after a drop, holding off during a performance | NetworkManager retries a missing or timed-out network by itself (four tries, then again five minutes later, NM `nm-manager.c`). A drop during the 4-way handshake, or a timed-out join of a profile that has not connected before, makes it ask a secret agent for a new key; with no agent the profile is blocked from autoconnect until one registers (NM `nm-policy.c`). A desktop's network applet would answer; Pi OS Lite stays offline. The owner decided the console must reconnect by itself (#1326, #1337). |

## Saved networks across the update from an iwd image

NetworkManager keyfiles do not depend on the backend. The iwd images kept them
in `/data/NetworkManager/system-connections`, and this image reads the same
directory, so nothing is moved or rewritten. A saved profile holds its key as
a system secret (`psk=`, no `psk-flags`), which NetworkManager hands to
wpa_supplicant itself. iwd's own store, `/var/lib/iwd`, was on the root
filesystem and is gone with the old slot; nothing of iwd is on `/data`.
NetworkManager's state directory starts empty on `/data` on the first boot, so
the first join after the update is the one that records each network as
connected.
