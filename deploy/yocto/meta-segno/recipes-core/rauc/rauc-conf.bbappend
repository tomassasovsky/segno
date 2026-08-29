# Override meta-rauc's example rauc-conf (the virtual-rauc-conf provider that owns
# /etc/rauc/system.conf) with the appliance's tryboot A/B config, and add the
# keyring (public CA cert). FILESEXTRAPATHS:prepend makes our files/system.conf win
# over meta-rauc's when the rauc-conf recipe fetches file://system.conf.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI += "file://ca.cert.pem"

# Board-specific values for the @PLACEHOLDERS@ in files/system.conf. Set per
# board in the kas project (deploy/yocto/kas-segno-rpi{4,5}.yml); no defaults
# here on purpose, so a board that forgets them fails the build rather than
# quietly shipping the other board's slot table.
SEGNO_BOOT_DISK        ?= ""
SEGNO_RAUC_COMPATIBLE  ?= ""

do_install:append() {
    install -d ${D}${sysconfdir}/rauc
    install -m 0644 ${UNPACKDIR}/ca.cert.pem ${D}${sysconfdir}/rauc/keyring.pem

    if [ -z "${SEGNO_BOOT_DISK}" ] || [ -z "${SEGNO_RAUC_COMPATIBLE}" ]; then
        bbfatal "SEGNO_BOOT_DISK and SEGNO_RAUC_COMPATIBLE must both be set — see deploy/yocto/kas-segno-rpi5.yml"
    fi

    sed -i -e 's,@SEGNO_BOOT_DISK@,${SEGNO_BOOT_DISK},g' \
           -e 's,@SEGNO_RAUC_COMPATIBLE@,${SEGNO_RAUC_COMPATIBLE},g' \
           ${D}${sysconfdir}/rauc/system.conf

    # A surviving placeholder means RAUC would address a slot named "@...@" and
    # every update would fail on the device. Catch it on the build host instead.
    if grep -q '@SEGNO_[A-Z_]*@' ${D}${sysconfdir}/rauc/system.conf; then
        bbfatal "unsubstituted placeholder left in system.conf: $(grep -o '@SEGNO_[A-Z_]*@' ${D}${sysconfdir}/rauc/system.conf | sort -u | tr '\n' ' ')"
    fi
}

FILES:${PN} += "${sysconfdir}/rauc/keyring.pem"
