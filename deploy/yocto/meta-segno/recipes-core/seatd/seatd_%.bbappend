# Install seatd but do not start it. ivi-homescreen links libseat, which this
# recipe packages together with the daemon, so the daemon comes with it. Both
# views in homescreen.toml set `no_seat = true` and open the DRM master and
# the input devices themselves, so nothing connects to seatd (#1330).
SYSTEMD_AUTO_ENABLE:${PN} = "disable"
