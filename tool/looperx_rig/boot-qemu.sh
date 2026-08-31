#!/bin/sh
M=/usr/lib/arm-linux-gnueabihf
mkdir -p /shim /media/az01-internal/Looper/usb_mnt /run/user/0
# content trees the app expects to exist on the device
mkdir -p /media/hg03-content/Resources/Audio
# the app's DB path is the BUILD machine's path, baked in. QSQLITE creates the
# file if the directory exists, so make the directory exist.
mkdir -p /data/4/w/HeadRush/Looper-Embedded-Pipeline/release_hg08_1.0.2/hg08-secure/buildroot/output/build/looper-custom/Apps/Looper/buildroot-build/Generated/DB
mkdir -p /media/az01-internal/Looper/Resources/Audio
mkdir -p "/media/az01-internal/Looper/usb_mnt/FX Presets"
mkdir -p "/media/az01-internal/Looper/usb_mnt/Loops"
mkdir -p "/media/az01-internal/Looper/usb_mnt/Backing Tracks"
xz -dc /rootfs/usr/share/Looper/FxPresets.tar.xz | tar x -C "/media/az01-internal/Looper/usb_mnt/FX Presets" 2>/dev/null || true
ln -sfn /rootfs/usr/Looper /usr/Looper
ln -sfn /rootfs/usr/share/Looper /usr/share/Looper
ln -sf $M/libEGL.so.1 /shim/libmali.so.14.0
ln -sf $M/libEGL.so.1 /shim/libEGL.so.1
ln -sf $M/libGLESv2.so.2 /shim/libGLESv2.so.2
# the app probes /usr/qt/qtlogging.ini -- the reliable way to turn on Qt's
# categorised logging here, since -E with globs/semicolons gets mangled.
mkdir -p /usr/qt
cat > /usr/qt/qtlogging.ini <<'INI'
[Rules]
qt.qpa.*=true
qt.scenegraph.*=true
qt.quick.*=true
qt.qml.*=true
INI
cat > /tmp/rig-asound.conf <<CONF
</rootfs/usr/share/alsa/alsa.conf>
pcm.rigpcm { type plug slave { pcm "null" format S32_LE rate 48000 channels 4 } }
ctl.rigpcm { type hw card 0 }
CONF
qemu-arm-static -strace -L /rootfs \
  -E LD_LIBRARY_PATH=/shim:/rootfs/lib:/rootfs/usr/lib:$M \
  -E LD_PRELOAD="/usr/local/lib/libseqshim.so /usr/local/lib/libalsashim.so /usr/local/lib/libfbshim.so $M/libGLESv2.so.2" \
  -E ALSA_CONFIG_PATH=/tmp/rig-asound.conf -E LOOPERX_PCM=rigpcm  \
  -E LIBGL_ALWAYS_SOFTWARE=1 -E LIBGL_DRIVERS_PATH=$M/dri \
  -E EGL_PLATFORM=surfaceless -E MESA_LOADER_DRIVER_OVERRIDE=swrast \
  -E QT_QPA_EGLFS_INTEGRATION=eglfs_mali -E QSG_INFO=1 -E QSG_RENDER_LOOP=basic -E QT_LOGGING_RULES="qt.scenegraph.*=true;qt.qpa.*=true;qt.quick.*=true" \
  -E QT_QPA_EGLFS_WIDTH=800 -E QT_QPA_EGLFS_HEIGHT=1280 \
  -E LOOPERX_FRAMEDIR=/out/frames -E LOOPERX_FRAME_EVERY=5 \
  /rootfs/usr/Looper/Looper > /out/qemu2.log 2>&1 &
QPID=$!
i=0
while [ $i -lt 40 ]; do
  if kill -0 $QPID 2>/dev/null; then cp /proc/$QPID/maps /out/maps.txt 2>/dev/null; fi
  i=$((i+1)); sleep 1
done
kill $QPID 2>/dev/null
