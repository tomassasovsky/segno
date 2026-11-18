# dnsmasq as on Raspberry Pi OS (#1843): the program, which NetworkManager
# starts itself when a connection shares its link, and no service of its own.
# Pi OS installs only dnsmasq-base; the dnsmasq package NetworkManager's
# recipe recommends here also enabled dnsmasq.service, which answered DNS for
# the local network. The unit stays in the package, not enabled.
SYSTEMD_AUTO_ENABLE:${PN} = "disable"
