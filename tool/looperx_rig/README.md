# Looper X emulation rig

Boots the Sheeran Looper X (HG08) userland under ARM emulation on a developer
machine, so its DSP can be measured rather than guessed at. Background and
motivation: #887, #891.

```sh
ROOTFS=~/Downloads/LooperX_1.0.2_extracted/rootfs ./run.sh 60
```

## Status

The app **boots and reaches its audio engine** — graphics, MIDI and ALSA are all
satisfied and `InputFXThread CPU affinity: 0..3` appears, which is the DSP
engine's own threads starting. It then segfaults before rendering a frame, so
no UI has been captured yet. See "Where it stops".

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

## The fatal crash, as far as it is understood

`-strace` pins the sequence:

```
sched_setscheduler(23, 2, ...) = -1 errno=1 (Operation not permitted)
--- SIGSEGV {si_signo=SIGSEGV, si_code=1, si_addr=0x702d7562} ---
```

The app asks for `SCHED_RR` on an engine thread and is refused, then
immediately faults. `si_code=1` is SEGV_MAPERR and `si_addr=0x702d7562` is
**ASCII bytes** (`p`, `-`, `u`, `b`) — a string being dereferenced as a
pointer, i.e. a garbage or type-confused pointer rather than a plain null.

Granting `CAP_SYS_NICE` makes the EPERM go away but **does not** fix the crash,
so the scheduling failure is a symptom sharing a cause rather than the cause.
Creating the content trees the app expects
(`/media/hg03-content/Resources/Audio`, `Resources/Audio`, the `usb_mnt`
folders) does not fix it either.

The strongest remaining hypothesis is still the empty audio-device identity:
the app logs `Failed to fetch the audio device ""` shortly before, and an empty
name flowing into a lookup is exactly the shape that yields a bogus pointer.

## Where it stops

```
Device Identifier ( Line: 95 ): Can't find file: ""
void airHost::updateAudioDeviceChanged(bool) Failed to fetch the audio device "" from the device manager.
InputFXThread CPU affinity: 1 [ALARM] Caught Segmentation fault signal, ...
qemu: uncaught target signal 11 (Segmentation fault)
```

Note the device name is **empty**, not wrong — the lookup produced `""` and the
app then built an empty file path from it. So the miss is upstream of the file:
the device manager never resolved a device identity for our synthetic card.

The app has a `KnownDevices` table and looks for a `DeviceConfiguration.json`
that exists neither on disk in the rootfs nor in its Qt resources, so it is
either generated at runtime or expected somewhere not yet created.

`[ALARM] Caught Segmentation fault` is the app's own handler — it survives
several of these before one becomes fatal, so the crash is recoverable state
being hit repeatedly rather than a single hard fault.

## Two ways to run it

- `Dockerfile` + `boot.sh` — arm32 container, Docker's transparent binfmt.
  Simplest, but **gdb cannot attach** (binfmt qemu-user has no ptrace).
- `Dockerfile.debug64` + `boot-qemu.sh` — **arm64** container invoking
  `qemu-arm-static` explicitly. Better in every way for diagnosis: the base is
  native on Apple Silicon so `apt` is fast, the shims cross-compile with
  `arm-linux-gnueabihf-gcc`, and qemu's own `-g <port>` gdbstub and `-strace`
  both work. Needs `libc6-dev:armhf` for `crti.o`.

## Debugging notes

- Run with `--cap-add=SYS_NICE --ulimit rtprio=99`. Without it the app's
  `sched_setscheduler(SCHED_RR)` is refused with EPERM (see below).
- `qemu-arm-static -strace` is the most useful tool here by far — it gives the
  syscall trace and the faulting address without needing symbols.
- Symbolizing is still unsolved: gdb sees `?? ()` because it has no module
  bases, and `/proc/<qemu-pid>/maps` captured at the wrong moment shows only
  qemu itself. Reconstructing bases from the `openat`/`mmap2` pairs in an
  `-strace` log is the obvious next attempt.
- **How far it gets depends on whether the PCM opens.** With `LOOPERX_PCM`
  pointing at a working device the app starts `InputFXThread` and dies; with it
  pointing at a nonexistent device (so `snd_pcm_open` fails) it gets *further* —
  `Streaming`, `WORKER THREAD` and `LooperTrack` threads all start — and then
  still dies. That is useful: the crash is not in device setup, it is in state
  reached shortly after, and audio being absent delays rather than prevents it.

## Next step

Give the device manager an identity it accepts. Options, cheapest first:
report the card as `UAC2Gadget` (the PCM card name in the device's own
`etc/asound.conf`) rather than `HG08`; seed whatever settings store holds the
selected device; or find where `DeviceConfiguration.json` is expected and
supply one.

Once a frame renders, `fbshim.c` writes raw RGBA frames to
`$LOOPERX_FRAMEDIR`. It is wired up and reports its geometry on first swap, but
has not yet fired — `eglSwapBuffers` is never reached.

## Seeing the screen

`fbshim.c` does this: it intercepts `eglSwapBuffers` and calls `glReadPixels` on
the back buffer just before the swap, which is exactly the finished frame. Set
`LOOPERX_FRAMEDIR` to collect raw RGBA frames (`LOOPERX_FRAME_EVERY` thins them
— software rendering under emulation is slow). GL's origin is bottom-left, so
rows come out bottom-first; the panel is 800x1280 portrait shown rotated, the
same geometry the splash screens decode with.
