# Looper X emulation rig

Boots the Sheeran Looper X (HG08) userland under ARM emulation on a developer
machine, so its DSP can be measured rather than guessed at. Background and
motivation: #887, #891.

```sh
ROOTFS=~/Downloads/LooperX_1.0.2_extracted/rootfs ./run.sh 60
```

## Status

**Not finished.** The app boots, initializes graphics, the virtual keyboard,
udev and MIDI enumeration, then dies during audio device enumeration. See
"Where it stops" below.

## Why each substitution exists

Every item here was established by running the thing, not by reading docs.

| symptom | cause | fix |
|---|---|---|
| `QT_QPA_PLATFORM=offscreen` ignored | the app calls `qputenv("QT_QPA_PLATFORM", "eglfs")` itself — the two strings are adjacent in `.rodata` | irrelevant; use the eglfs knobs instead |
| `-platform offscreen` → "Available platform plugins are: eglfs, eglfs" | Qt is **statically linked**; there is no `plugins/platforms` directory anywhere in the rootfs and only eglfs is registered | cannot be forced; work within eglfs |
| `EGLFS: Failed to open /dev/fb0` | the `eglfs_mali` device integration sizes the screen from fbdev, and Docker's kernel has no fbdev (no major 29 in `/proc/devices`) | bind-mount a **regular file** at `/dev/fb0` — it opens, the `ioctl` fails non-fatally, and geometry comes from `QT_QPA_EGLFS_WIDTH`/`HEIGHT` |
| `The DDK is not compatible with any of the Mali GPUs on the system` | `usr/lib/libEGL.so` → `libmali.so.14.0`, an ARM Mali vendor blob wanting `/dev/mali`; no Mesa in the rootfs | satisfy the `libmali.so.14.0` **soname** with Mesa's glvnd `libEGL.so.1`, and `LD_PRELOAD` Mesa's `libGLESv2.so.2` for the GL half |
| `egl: failed to create dri2 screen` | Mesa found no DRI driver | `LIBGL_ALWAYS_SOFTWARE=1`, `MESA_LOADER_DRIVER_OVERRIDE=swrast`, `EGL_PLATFORM=surfaceless` |
| `EGL library doesn't support Emulator extensions` | `eglfs_emu` (also compiled in) needs Qt Emulator EGL extensions Mesa lacks | use `eglfs_mali` instead — it only wanted the framebuffer |
| `Cannot access file /usr/share/alsa/alsa.conf` | the container has no ALSA config; the **rootfs does** | `ALSA_CONFIG_PATH=/rootfs/usr/share/alsa/alsa.conf` |
| `snd_seq_query_next_client: Assertion 'seq && info' failed` | **their bug**: `snd_seq_open` fails with no `/dev/snd/seq`, the result is not checked, and alsa-lib asserts | `seqshim.c` intercepts the call and returns `-ENODEV` |

Both C libraries are glibc **2.36** (rootfs is Buildroot 2.36; bookworm armhf is 2.36), so
mixing Mesa from the container with the rootfs is safe. That is why this works
at all.

Do **not** pass `--privileged`: it breaks library resolution against the
bind-mounted rootfs, and nothing here needs it.

## Where it stops

```
ALSA lib confmisc.c:(snd_config_get_card) Cannot get card index for HG08
RtApiAlsa::getDeviceInfo: control open, card = hw:HG08, No such device.
qemu: uncaught target signal 11 (Segmentation fault)
```

The app enumerates its own audio hardware — `etc/asound.conf` names a
`UAC2Gadget` PCM card and an `HG08` control card — finds nothing, and
segfaults. Docker Desktop's kernel has **no ALSA whatsoever**: no
`/proc/asound`, zero `snd` entries in `/proc/devices`. No real card can ever
appear, so enumeration has to be faked in userspace.

## Next step

Extend the shim to cover ALSA enumeration: `snd_card_next`, `snd_ctl_open`,
`snd_ctl_card_info` and friends, presenting one synthetic card, and route
`snd_pcm_open` to alsa-lib's own `file` plugin. That is not a detour — writing
audio to a file is what the rig is *for*.

## Seeing the screen

Qt renders through EGL/GLES, so nothing is written to the framebuffer file and
there is no scanout to read. To watch the UI, add an `LD_PRELOAD` shim that
intercepts `eglSwapBuffers`, calls `glReadPixels` on the bound surface, and
writes each frame out — the same build pipeline `seqshim.c` already uses. The
panel is 800x1280 portrait, displayed rotated (see the splash decode in the
extraction README).
