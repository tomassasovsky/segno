#!/bin/sh
# Runs inside the ARM32 container. $1 = seconds to stay up.
M=/usr/lib/arm-linux-gnueabihf
mkdir -p /shim /media/az01-internal/Looper/usb_mnt /run/user/0

# The app has a hard DT_NEEDED on libmali.so.14.0 (the Mali blob providing
# EGL + GLESv1 + GLESv2). Satisfy that soname with Mesa's glvnd EGL. The
# rootfs also ships a 0-byte libGLESv2.so.2, so shadow that too.
ln -sf $M/libEGL.so.1    /shim/libmali.so.14.0
ln -sf $M/libEGL.so.1    /shim/libEGL.so.1
ln -sf $M/libGLESv2.so.2 /shim/libGLESv2.so.2

# seqshim must precede libasound in the global scope; GLESv2 must be preloaded
# so GL symbols resolve (the libmali shim only provides EGL).
export LD_PRELOAD="/usr/local/lib/libseqshim.so $M/libGLESv2.so.2"

export LIBGL_ALWAYS_SOFTWARE=1 LIBGL_DRIVERS_PATH=$M/dri
export EGL_PLATFORM=surfaceless MESA_LOADER_DRIVER_OVERRIDE=swrast
export QT_QPA_EGLFS_INTEGRATION=eglfs_mali
export QT_QPA_EGLFS_WIDTH=800 QT_QPA_EGLFS_HEIGHT=1280
export QT_QPA_EGLFS_PHYSICAL_WIDTH=108 QT_QPA_EGLFS_PHYSICAL_HEIGHT=172
export ALSA_CONFIG_PATH=/rootfs/usr/share/alsa/alsa.conf

/rootfs/lib/ld-linux-armhf.so.3 \
  --library-path /shim:/rootfs/lib:/rootfs/usr/lib:$M \
  /rootfs/usr/Looper/Looper &
APP=$!
sleep "${1:-60}"
kill -0 $APP 2>/dev/null && echo "[ALIVE after ${1:-60}s]" || echo "[exited]"
kill $APP 2>/dev/null || true
