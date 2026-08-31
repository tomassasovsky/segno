# Raspberry Pi floor-console: weston on vc4/V3D KMS aborts in the DRM plane-
# assignment path when a cursor view hits a non-shm buffer. The patch turns
# that assert into a continue so the view falls through to the renderer (#825).
# Rebased for weston 15 on wrynose.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI += "file://0001-segno-vc4-cursor-planes-broken.patch"
