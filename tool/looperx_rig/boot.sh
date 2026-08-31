#!/bin/sh
# Runs inside the ARM32 container. $1 = seconds to stay up.
M=/usr/lib/arm-linux-gnueabihf
mkdir -p /shim /media/az01-internal/Looper/usb_mnt /run/user/0
# The app shells out to its own scripts by ABSOLUTE path and reads resources
# from /usr/share/Looper, so those paths must exist as the device has them.
ln -sfn /rootfs/usr/Looper       /usr/Looper
ln -sfn /rootfs/usr/share/Looper /usr/share/Looper

# usb_mnt is a real mountpoint (tmpfs), so the app's is_mounted_usb_img check
# passes and it never enters the losetup retry loop -- Docker has no loop
# devices. Seed it with the factory FX presets the device would unpack there.
if [ -n "${LOOPERX_FRAMEDIR:-}" ]; then mkdir -p "$LOOPERX_FRAMEDIR"; fi
xz -dc /rootfs/usr/share/Looper/FxPresets.tar.xz \
  | tar x -C /media/az01-internal/Looper/usb_mnt 2>/dev/null || true

# The app has a hard DT_NEEDED on libmali.so.14.0 (the Mali blob providing
# EGL + GLESv1 + GLESv2). Satisfy that soname with Mesa's glvnd EGL. The
# rootfs also ships a 0-byte libGLESv2.so.2, so shadow that too.
ln -sf $M/libEGL.so.1    /shim/libmali.so.14.0
ln -sf $M/libEGL.so.1    /shim/libEGL.so.1
ln -sf $M/libGLESv2.so.2 /shim/libGLESv2.so.2

# seqshim must precede libasound in the global scope; GLESv2 must be preloaded
# so GL symbols resolve (the libmali shim only provides EGL).
export LD_PRELOAD="/usr/local/lib/libseqshim.so /usr/local/lib/libalsashim.so /usr/local/lib/libfbshim.so $M/libGLESv2.so.2"

export LIBGL_ALWAYS_SOFTWARE=1 LIBGL_DRIVERS_PATH=$M/dri
export EGL_PLATFORM=surfaceless MESA_LOADER_DRIVER_OVERRIDE=swrast
export QT_QPA_EGLFS_INTEGRATION=eglfs_mali
export QT_QPA_EGLFS_WIDTH=800 QT_QPA_EGLFS_HEIGHT=1280
export QT_QPA_EGLFS_PHYSICAL_WIDTH=108 QT_QPA_EGLFS_PHYSICAL_HEIGHT=172
# alsa-lib's `null` advertises CHANNELS [1 .. 1073741823]; RtAudio reads
# channels_max and the app then throws std::bad_array_new_length. Wrap null in
# a `plug` with an explicit slave so the device reports a sane, real-device
# shape (2ch / 48k / S32_LE) instead.
cat > /tmp/rig-asound.conf <<CONF
</rootfs/usr/share/alsa/alsa.conf>

pcm.rigpcm {
    type plug
    slave {
        pcm "null"
        format S32_LE
        rate 48000
        channels 2
    }
}
ctl.rigpcm { type hw card 0 }
CONF
export ALSA_CONFIG_PATH=/tmp/rig-asound.conf
export LOOPERX_PCM="${LOOPERX_PCM:-rigpcm}"

/rootfs/lib/ld-linux-armhf.so.3 \
  --library-path /shim:/rootfs/lib:/rootfs/usr/lib:$M \
  /rootfs/usr/Looper/Looper &
APP=$!
sleep "${1:-60}"
kill -0 $APP 2>/dev/null && echo "[ALIVE after ${1:-60}s]" || echo "[exited]"
kill $APP 2>/dev/null || true
