# Looper X emulation rig

Boots the Sheeran Looper X (HG08) userland under ARM emulation on a developer
machine, so its DSP can be measured rather than guessed at. Background and
motivation: #887, #891.

```sh
ROOTFS=~/Downloads/LooperX_1.0.2_extracted/rootfs ./run.sh 60
```

## Status

The app boots, initializes audio, runs without crashing (with one binary
patch), and now **discovers its own MIDI control surface**:

```
air.devicemanager.midi.enumerator: Found client: 128 ( HG08 Control Surface MIDI 1 )
air.devicemanager.midi.enumerator:   port: 0 ( HG08 Control Surface MIDI 1 )
```

It does **not** render. Qt's event loop never starts -- there are zero
`poll`/`ppoll`/`epoll` calls in a whole run -- so `eglCreateWindowSurface` is
never reached, no QQuickView is created, and no frame has been captured.

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

## Crashes found and fixed

Each was located with `qemu-arm-static -strace` plus qemu's gdbstub, then the
faulting PC resolved by hand (gdb shows `?? ()`): library bases come from
correlating `openat`/`mmap2` pairs in the trace, and **the main binary loads at
`0x40000000`**, so `binary offset = PC - 0x40000000` disassembles directly.

1. **A buffer-pool clear walked off the end of its array.** `null` advertises
   `RATE [1..4294967295]`, `BUFFER_SIZE [1..4294967295]` and
   `CHANNELS [1..1073741823]`, and wrapping it in `plug` does **not** help --
   plug converts rather than constrains, so the client still sees the wide
   ranges. The app sized a pool from them, allocated ~20 buffers, then cleared
   ~10000 entries, `memset`-ing whatever heap followed. Fixed by clamping the
   `hw_params` getters in `alsashim.c` to a plausible interface.
2. **A gain loop over four channel buffers held two garbage pointers.** A
   `vldr`/`vmul`/`vstmia` loop over `ip, r0, r1, r2` where `r1`/`r2` contained
   UTF-16 text from adjacent heap. The device must report **4 channels** -- the
   HG08 has four inputs. Hence `RIG_CHANS = 4`.
3. **A main-thread null-singleton retry loop.** A call at binary offset
   `0x42a504` passes a file-local static pointer (slot `0x241bed4`, no dynamic
   relocation) that is never constructed, and the callee dereferences it at
   `+0x68`. The app's own SIGSEGV handler recovers and retries forever, so
   startup never completes. NOPing that `bl` stops the loop entirely
   (`[ALARM]` count drops to 0) and lets startup continue.

## Where it stops

Qt's event loop never runs: a full run makes **zero** `poll`, `ppoll` or
`epoll` calls, so the app never reaches `QCoreApplication::exec()`. It also
never logs `Engine dependencies initialized`, so it is blocked *inside*
engine-dependency initialization. `futex` is very busy (35k calls), which fits
a condition-variable wait rather than a stall on I/O.

That produced a deadlock worth recording: the app's UDevMonitor discovers
devices **only** through hotplug events, and a hotplug notifier can only fire
from the event loop that has not started. The shim hands that monitor a
pre-armed pipe, but `udev_monitor_receive_device` is never called for exactly
this reason.

With `seqshim.c` presenting a sequencer, the app now finds its control surface
and then stops right there -- earlier than it used to, which is informative: it
is presumably trying to *use* the surface and waiting for a response that real
hardware would send. Emulating that exchange is the next step, and the shipped
assignment files (`usr/Looper/Assignments/*.qml`) document the wire format:
footswitches are notes 0-11 on channel 0, with CCs for the encoder and pedal.

Two dead ends worth not repeating: the audio-device identity failure
(`Can't find file: ""`) is `UserDataDir` being empty -- the app also opens
`"/DeviceConfiguration.json"` at the filesystem root for the same reason -- and
neither creating that file nor setting `HOME`/`XDG_DATA_HOME`/the working
directory changes it.

## Debugging notes

- Run with `--cap-add=SYS_NICE --ulimit rtprio=99`. Without it the app's
  `sched_setscheduler(SCHED_RR)` is refused with EPERM (see below).
- `qemu-arm-static -strace` is the most useful tool here by far — it gives the
  syscall trace and the faulting address without needing symbols.
- **Symbolizing works.** The main binary loads at `0x40000000`, so
  `arm-none-eabi-objdump -d --start-address=$((PC-0x40000000))` disassembles the
  faulting instruction directly.
- **Qt logging**: `-E QT_LOGGING_RULES=...` gets mangled by the shell. The app
  probes `/usr/qt/qtlogging.ini` -- write the rules there instead.
- **There is a startup race.** Without `-strace` the app dies; with `-strace`
  on stderr (slow, through the Docker pipe) it survives. `-D file` is too fast
  to help and `--cpus=1` does not help, so it is syscall latency, not
  parallelism.
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
