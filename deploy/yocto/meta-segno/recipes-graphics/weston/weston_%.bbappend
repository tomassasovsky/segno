# Raspberry Pi 4 floor-console (Tier 3a spike): weston 14 on vc4/V3D KMS aborts
# in the DRM plane-assignment path (assert(fb) in drm_output_find_plane_for_view)
# as soon as a client sets a pointer cursor, crashing the compositor on mouse
# input. The patch turns those asserts into `continue`s so an unplaceable view
# skips that plane and falls through to the renderer. It does NOT set
# cursors_are_broken / sprites_are_broken — cursor views still enter plane
# proposal every frame (#825). See the patch header for the full rationale.
#
# 0002: kiosk-shell click-to-activate SIGSEGVs after an HDMI HPD blip (#821)
# because pointer focus still names a view whose surface went with the
# disabled output. Guard that path; the cmdline D flag is what stops the
# disable itself.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI += "file://0001-segno-vc4-cursor-planes-broken.patch \
            file://0002-segno-kiosk-shell-guard-stale-pointer-focus.patch"
