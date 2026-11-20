# The v3d BO cache keeps large BOs (an offscreen render target's MSAA
# buffers) for minutes, so a page transition reuses the last one's instead
# of having the kernel zero 73 MB of pages under the audio callback (#1914).
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI += "file://0001-v3d-keep-large-BOs-in-the-cache-for-minutes.patch"
