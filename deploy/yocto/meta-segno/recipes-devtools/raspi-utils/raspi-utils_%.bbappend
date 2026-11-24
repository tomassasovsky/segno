# RAUC's system-info handler (rauc-rpi-backend) reads the board serial through
# `vcmailbox` (the VideoCore mailbox CLI). The backend used it for the tryboot
# one-shot flag too, until SEG-101 left that flag to the tryboot reset itself.
# The base meta-raspberrypi raspi-utils recipe only compiles pinctrl + dtmerge:
#
#     OECMAKE_TARGET_COMPILE = "pinctrl/all dtmerge/all"
#     OECMAKE_TARGET_INSTALL = "pinctrl/install dtmerge/install"
#
# so `vcmailbox` never lands in the image. Build + install the vcmailbox
# target too. It's a standalone C
# program (mailbox ioctl, no extra DEPENDS) with its own install() rule, exactly
# parallel to pinctrl/dtmerge.
OECMAKE_TARGET_COMPILE:append = " vcmailbox/all"
OECMAKE_TARGET_INSTALL:append = " vcmailbox/install"
