# The v3d BO cache keeps large BOs (an offscreen render target's MSAA
# buffers) under a budget, so a page transition reuses the last one's instead
# of having the kernel zero 73 MB of pages under the audio callback (#1914).
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI += "file://0001-v3d-keep-large-BOs-cached-under-a-budget.patch"
