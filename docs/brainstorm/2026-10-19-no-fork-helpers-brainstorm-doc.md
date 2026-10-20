---
date: 2026-10-19
topic: no-fork-helpers
---

<!-- cspell:words vfork CLONE_VM CLONE_VFORK SIGHAND posix_spawn pidfd addclosefrom tcsetattr tcgetattr cfmakeraw termios rusage RUSAGE_THREAD DONTFORK MADV_DONTFORK mlockall MCL_FUTURE minflt spawni execvp nptl rwsem ddcutil iwd stty dup_mmap ProcessStarter wrprotect waitid closefrom ECHILD CLOEXEC SCHED SIGCHLD SIGSEGV adddup atfork cfsetispeed cfsetospeed dbus getrusage mlock prio pthread setstack sysdeps sysv waitpid -->

# Start helper programs without forking the app process

Tracking: [#1367](https://github.com/tomassasovsky/segno/issues/1367).
Related: [#914](https://github.com/tomassasovsky/segno/pull/914) (fork-shield
the audio buffers), #907, #900, #806, #710.
Benchmark: [`deploy/spike-1367/fork_bench.c`](../../deploy/spike-1367/fork_bench.c).

## Summary

- The Dart VM in the shipped Flutter 3.47.5 (Dart 3.13.4) starts every child
  process with a plain `fork()`. That copies the app's page tables and
  write-protects every private page of the app.
- On the console, a fork from a 512 MB process held a SCHED_FIFO thread up for
  as long as 6.6 to 9.1 ms, and 582 to 885 callbacks missed the 667 us deadline
  per ~90 launches. `posix_spawn` (glibc: `clone(CLONE_VM|CLONE_VFORK)`) from
  the same process gave a worst callback of 97 to 138 us, no missed deadline
  and no page fault in the RT thread, over 1,274 launches.
- #914's `MADV_DONTFORK` shielding reduces the damage of a fork but does not
  bound it. The RT thread still faults once per fork on its own stack, and that
  one fault waits for the whole fork: the worst callback was still 2.2 to 3.9
  ms. The stack cannot be shielded.
- Recommendation: option (a). Start helpers with `posix_spawn` through
  `dart:ffi`, replace `stty` with `termios` calls (part of option (c)), and add
  a CI check that stops `Process.run` and `Process.start` from coming back.
  Keep #914 as protection against a fork from code we do not control. It is
  not a substitute.

## 1. How Dart starts a process on Linux

### The version the app ships

`deploy/yocto/meta-segno/recipes-graphics/flutter-engine/flutter-engine-version.inc`
pins Flutter 3.47.5, engine commit `af7e796e161ae0bb1ff0758c71a7105418bd9ded`.
That commit's `DEPS` sets `dart_revision` to
`b530c21f7de367b94fb04787bfed9d8e989d75e8` (DEPS:59), whose `tools/VERSION` is
Dart 3.13.4 stable. All citations below are from dart-lang/sdk at that
revision.

### The call path

1. `Process.run` calls `_runNonInteractiveProcess`, which calls
   `Process.start` (`sdk/lib/_internal/vm/bin/process_patch.dart:602-620`).
2. `Process.start` reaches the native entry `Process_Start`
   (`process_patch.dart:541`, `runtime/bin/process.cc:76`), which calls
   `Process::Start` (`process.cc:160`).
3. `Process::Start` builds a `ProcessStarter` and calls `Start()`
   (`runtime/bin/process_linux.cc:809-827`).
4. `ProcessStarter::Start()` creates the pipes and then calls
   `TEMP_FAILURE_RETRY(fork())` (`process_linux.cc:374`).

There is no `vfork`, no `clone` with `CLONE_VM`, and no `posix_spawn` anywhere
in `process_linux.cc`. glibc's `fork()` is a `clone` with `SIGCHLD` and without
`CLONE_VM`, so the child gets a copy-on-write copy of the whole address space.

Other details in that file that matter here:

- The child does not exec at once. It blocks on a pipe (`NewProcess`,
  `process_linux.cc:492-505`) until the parent has registered it with the
  exit-code thread and written one byte (`process_linux.cc:388-401`). Then it
  redirects stdio and calls `execvp` (`process_linux.cc:516-555`). While it
  waits, the app's address space is shared copy-on-write, so every page the app
  writes in that window is copied.
- Detached processes fork twice more (`process_linux.cc:574` and `:583`).
- Exit codes are collected by a dedicated thread, "dart:io Process", that
  calls `wait(&status)` for any child (`process_linux.cc:199`). The thread
  starts on the first `Process.start` and the console's `segno` process has
  it running. This matters for option (a).
- Stopping that thread forks once more (`process_linux.cc:168`).
- In attached mode the child closes no file descriptors. It relies on
  `O_CLOEXEC`. Only the detached paths call `CloseAllButStdioAndExecControl`
  (`process_linux.cc:693` and `:707`).

### What the fork does to the app's memory

In the kernel (6.12, the console's), `dup_mmap` holds the app's `mmap_lock`
for write and write-locks each VMA as it copies it. `copy_page_range` then
write-protects every private writable page in the parent. Three costs follow
for the audio thread:

1. A page fault during the copy waits until the copy ends. Under
   `PREEMPT_RT`, `mmap_lock` is a sleeping lock, so the thread sleeps. The
   copy took 2.0 ms for a 200 MB working set and 2.7 to 4.4 ms for 512 MB
   (median `fork()` call time below).
2. While the child exists, the first write to each page copies it.
3. After the child has exec'd, the parent's pages are still write-protected,
   so the first write to each page faults once more. The kernel then reuses
   the page instead of copying it.

The app's existing comments (`performance_recorder_cubit.dart`,
`audio_engine.dart` `volumeSpace`) describe the same mechanism from #806.

## 2. Measurements on the console

### Setup

- Console `192.168.50.124`, build `0.1.0-experimental.181`, kernel
  `6.12.25-v8-16k` `PREEMPT_RT` (16 KB pages), glibc 2.41, 4 cores. The app
  was running throughout. `segno.service` was not touched.
- `fork_bench` (static aarch64, built in the `gcc:14` image) maps and writes a
  512 MB working set and calls `mlockall(MCL_CURRENT|MCL_FUTURE)`, as #914
  does. Two `SCHED_OTHER` threads (nice 10) keep writing to random pages of
  it, as a stand-in for the Flutter engines.
- One `SCHED_FIFO` 70 thread is pinned to CPU 2, below the app's audio
  thread at 80. It wakes every 667 us and writes one byte into each page of
  a 4 MB buffer (256 pages). That is the worst case for copy-on-write: every
  page faults once after each fork. For each cycle it records the time from
  the scheduled wake-up to the end of its work, and its minor faults
  (`getrusage(RUSAGE_THREAD)`, counted from the end of the previous cycle so
  that faults on the wake-up path count too).
- A control thread on CPU 0 starts `/bin/true` every 200 ms. The `fork` mode
  copies Dart's handshake: the child blocks on a pipe until the parent writes
  one byte, then execs. Each run lasts 20 s, about 29,000 cycles and 90
  launches, and skips the first 0.5 s.
- "Missed" counts cycles that finished more than 667 us after their scheduled
  start.

### Results

All times are in microseconds. "RT faults" is the total for the RT thread
over the run.

| Mechanism | Launches | p99 | p99.9 | Max | Missed | RT faults | `fork`/spawn call, median |
|---|---:|---:|---:|---:|---:|---:|---:|
| none (baseline) | 0 | 14.6 | 34.0 | 39.2 | 0 | 0 | - |
| fork | 93 | 2,699 | 5,345 | 6,575 | 582 | 24,022 | 2,711 |
| fork, no `mlockall` | 91 | 4,394 | 6,601 | 7,365 | 882 | 23,512 | 4,066 |
| fork, 200 MB working set | 94 | 2,648 | 4,679 | 8,927 | 628 | 24,284 | 2,020 |
| fork, RT buffers `MADV_DONTFORK` | 91 | 57.2 | 88.9 | 2,226 | 5 | 91 | 4,356 |
| same, second run | 91 | 47.7 | 261.1 | 3,933 | 23 | 92 | 4,314 |
| vfork | 98 | 62.7 | 89.3 | 100.8 | 0 | 0 | 112 |
| `posix_spawn` | 98 | 30.7 | 49.9 | 97.2 | 0 | 0 | 162 |
| `posix_spawn`, 60 s, every 50 ms | 1,176 | 49.4 | 82.3 | 137.8 | 0 | 0 | 139 |
| another process starts `/bin/true` every 50 ms (option (b)) | 400 in the other process | 72.2 | 86.3 | 117.2 | 0 | 0 | - |

An earlier round, with a first version of the benchmark that counted faults
only during the work, gave the same picture: fork reached 7,769 us with 877 missed, fork without
`mlockall` 9,121 us with 885 missed, and `posix_spawn` 103 us with none missed.

What the numbers show:

- **A fork costs the RT thread one fault per page it writes**: about 258
  faults per launch, the 256 buffer pages plus its stack. The worst callback
  is longer than the `fork()` call itself, because the 256 copies follow the
  wait.
- **`mlockall` does not help.** Locked pages are still write-protected by a
  fork.
- **A smaller working set shortens the `fork()` call** (2.0 ms against 2.7 ms)
  **but not the worst callback.** At 200 MB, about the app's current resident
  size, the fork is still far over the deadline.
- **`posix_spawn` and `vfork` do not touch the parent's page tables.** The
  RT thread took no fault and no callback missed. The worst callbacks (97 to
  138 us) are within the range of the noise from the live app sharing the
  CPUs (39 to 117 us in the runs where this process launched nothing).
- **Launches from another process cost nothing**, as expected: that is the
  behaviour option (b) would give.

### `MADV_DONTFORK` and the thread's stack

With the RT buffers marked `MADV_DONTFORK`, the RT thread took exactly one
fault per fork (91 faults for 91 launches): a write to its own stack. That
fault arrives while `dup_mmap` holds `mmap_lock`, so it waits for the rest of
the copy. The worst callback was 2.2 to 3.9 ms, and an earlier run reached
4.3 ms with 57 missed.

The stack cannot be shielded the same way. A first version of the benchmark
ran the RT thread on a stack mapped with `MADV_DONTFORK`
(`pthread_attr_setstack`). Every child then died with `SIGSEGV` inside
`fork()`. In the child, glibc 2.41 walks the descriptor of every thread that
has a user-supplied stack (`sysdeps/nptl/fork.h:139-144`, `reclaim_stacks`),
and glibc keeps that descriptor at the top of the thread's stack, which is not
mapped in the child. Those 26 crashes left records in the console's journal.
Resource limits stopped any core file from being written.

So, for any thread that writes to its own stack, which every thread does, a
fork means at least one fault, and that fault waits for the whole page-table
copy. Shielding the buffers turns hundreds of missed deadlines per 90 forks into
a few dozen at most, but the worst case stays at milliseconds.

## 3. The options

### (a) `posix_spawn` through `dart:ffi`

The app calls glibc's `posix_spawn` (or `pidfd_spawn`, glibc 2.39 and later)
from `DynamicLibrary.process()`, with `posix_spawn_file_actions_adddup2` for
the stdin, stdout and stderr pipes and
`posix_spawn_file_actions_addclosefrom_np(3)` to close every other
descriptor.

How it behaves:

- **Memory.** `clone(CLONE_VM|CLONE_VFORK)` shares the address space and
  copies no page table, so nothing is write-protected. glibc maps a separate
  stack for the child (glibc 2.41 `sysdeps/unix/sysv/linux/spawni.c:364`),
  which takes `mmap_lock` for write for a few microseconds; no RT fault is
  pending, so nothing waits on it. Measured: zero RT faults over 1,274
  launches.
- **Other threads.** `CLONE_VFORK` suspends only the calling thread until the
  child execs, measured at 139 to 162 us median. The audio thread and the
  Flutter threads keep running.
- **Signals.** glibc blocks every signal around the clone and the child
  clears all handlers (`CLONE_CLEAR_SIGHAND`) before exec, so no app signal
  handler runs in the child while it shares the app's memory (`spawni.c:31-47`
  and `:392-410`). This is the reason to call `posix_spawn` and not `vfork`:
  the Dart VM cannot run in a vfork child at all.
- **File descriptors.** `addclosefrom_np(3)` closes everything above stderr.
  That is stricter than Dart today, which closes nothing in attached mode.
- **Output and exit status.** `dart:io` cannot wrap a raw descriptor in a
  stream, so the reads have to happen through FFI. A worker isolate runs the
  launch, `poll`s the stdout and stderr pipes (and the pidfd, with
  `pidfd_spawn`), reads them with `read`, collects the exit status with
  `waitpid` or `waitid`, and sends lines and the result back on a `SendPort`.
  Cancelling sends `kill(pid, SIGTERM)` through FFI. These are the four
  features the call sites use today: stdin (the Wi-Fi key), streamed
  stdout (`PROGRESS` lines from the update helper), stderr for errors, and
  kill on cancel.
- **The reaping hazard.** Dart's exit-code thread calls `wait()` for any
  child (`process_linux.cc:199`). If anything in the app still uses
  `Process.start`, that thread can collect the exit status of a child started
  through FFI, and our `waitpid` fails with `ECHILD`. The switch therefore
  has to cover every call site in one change, and a CI check must keep
  `Process.run` and `Process.start` out of `lib/` and `packages/`.

Cost: one small Linux-only Dart package, about 250 lines, with tests that
start real programs (`/bin/sh -c ...`) on the Linux CI runner. Each of the
five clients takes a runner in place of calling `Process` directly; they
already take their helper path as a constructor argument, so this is the
same kind of injection. The macOS development build keeps `dart:io`'s
`Process` behind the same interface, since it has no real-time thread to
protect.

Risk: low. The kernel and libc path is the one the standard process APIs of
Go, Java, Python and Rust use on Linux, for the same reason. The new code is
FFI plumbing around pipes, which is where the bugs would be, and the tests
cover it.

### (b) A long-lived launcher process

A small root process, started by systemd before `segno.service` (or by
socket activation), listens on a Unix socket under `/run/segno/`. The app
sends a request; the launcher forks itself (a few MB, so its fork is cheap
and touches none of the app's memory), runs the helper, and returns stdout,
stderr and the exit status.

- **Memory.** The app never forks. Measured: launches from another process
  had no effect on the RT thread.
- **What has to be built.** systemd units, the launcher program (in C, or a
  shell script under socket activation with `Accept=yes`), a framing protocol
  for argv, stdin, streamed stdout, stderr, exit status and cancel, and an
  allowlist so the root socket runs only the `segno-*-ctl` helpers. On the
  Dart side, a client over `Socket` with `InternetAddressType.unix`, and the
  same change at every call site as in (a).
- **Failure modes it adds.** The launcher can be absent, slow to start, or a
  different version from the app after a partial update. Cancel needs its own
  path: closing the socket does not stop a helper that is not writing.
- **What it gains over (a).** The app has no child processes at all, and the
  helpers could later run with fewer privileges than the app. Neither is a
  current requirement. The image already uses a related pattern for USB
  storage (`segno-usb-mount@.service` writes state under `/run/segno/usb`,
  the app watches it with inotify, #1177), which suits events but not
  request and response.

Cost: more than (a). The Dart side is about the same size, and a daemon, a
protocol and units come on top. Risk: medium, mostly from the protocol and
the lifecycle.

### (c) Replace helpers with direct access

| Call site | When it runs | Direct replacement | Verdict |
|---|---|---|---|
| `stty` in `packages/pedal_repository` | When a pedal is plugged in, which can be mid-take | `tcgetattr`, `cfmakeraw`, `cfsetispeed`/`cfsetospeed`, `tcsetattr` through FFI, on the descriptor the package already opens through FFI | Do it. Small, and it removes the helper most likely to run during a performance. |
| `segno-wifi-ctl` status and scan in `packages/wifi_client` | When the Network page is open | NetworkManager's D-Bus API (the image runs NetworkManager with the iwd backend; the helper says NetworkManager owns the radio), through a new `package:dbus` dependency | Not now. Once launches do not fork, these calls no longer stall the audio thread. Connect, forget and restore carry the fixes from #463 and #468 in 783 lines of shell, and porting them is a separate decision. |
| `segno-brightness-ctl` in `packages/brightness_client` | When brightness changes | `ddcutil` speaks DDC/CI over I2C. Reimplementing it is not worth it. | Keep the helper. |
| `segno-update-ctl` in `lib/update/appliance/system_appliance_env.dart` | Update check, install, reboot, power off | RAUC and systemd both have D-Bus APIs | Keep the helper. It runs at update and power time, and its install logic lives in the script. |
| `segno-touch-ctl` in `packages/touch_calibration_client` | Touch calibration | Writes calibration state the helper manages | Keep the helper. It runs at setup time. |

(c) alone cannot remove every launch. It works alongside (a) or (b).

## 4. Is #914's shielding still needed?

Once the app no longer forks, `MADV_DONTFORK` changes nothing. Its remaining
value is limiting the damage when something we do not control forks the
process: a plugin, a dependency, the Flutter engine, or Dart's own exit-code
thread shutdown (`process_linux.cc:168`, which only runs if `Process` was
used). In the benchmark it cut missed deadlines from 582 to 882 per ~90 forks
down to 5 to 57, and RT faults from 256 per fork down to 1. It does not limit
the worst case, which stays at 2 to 4 ms because of the stack fault.

#914's `mlockall` is a separate protection, against page reclaim and major
faults on code and data pages, and stays useful either way.

Recommendation: land #914 as it is. It is already built and cheap at run
time, and it reduces a regression from hundreds of missed deadlines to a few
dozen at most.
Do not count it as the fix: "no audio-thread stalls, ever" needs the forks to
stop.

## 5. Recommendation

Option (a), with the `stty` part of (c), and a guard:

1. A small Linux-only spawn package: `posix_spawn` through FFI, a worker
   isolate for the pipes and the exit status, kill on cancel, and a
   `Process`-backed implementation for the macOS development build.
2. Move all five call sites to it in one change, because Dart's exit-code
   thread would otherwise reap the new children.
3. Replace `stty` with `termios` calls in `NativeUartPedalIo.configure`.
4. Add a CI check that fails on `Process.run`, `Process.start` and
   `Process.runSync` under `lib/` and `packages/`, outside the spawn
   package's macOS implementation.
5. Optional, for regressions from dependencies: a `pthread_atfork` prepare
   handler in the engine that counts forks of the process and logs the first
   one with a timestamp, so a fork from any library shows up in `segno.log`.
   glibc runs atfork handlers for every `fork()` it performs.

Reasons for (a) over (b): it removes the fork with less new code, no new
daemon, socket or protocol, and no new startup ordering. It uses the same
mechanism other language runtimes use to start processes from large
programs. (b)'s benefits (no child processes, helpers with fewer privileges
than the app) are not needed today.

A change to Dart itself, using `posix_spawn` in `process_linux.cc`, would fix
this for every Dart program on Linux. It would reach the console only with a
Flutter upgrade that meta-flutter publishes an engine for, so it is not a
substitute for (a), but it is worth reporting upstream.

## Raw output

<details>
<summary>fork_bench output, final binary</summary>

```text
mode=none ws_mb=512 rt_mb=4 page=16384 mlock=1 prio=70 cycles=29250 launches=0
  done_us p50=10.0 p99=14.6 p99.9=34.0 max=39.2  max_wake_us=30.2  missed(>667us)=0
  rt_faults total=0 cycles_with_faults=0 max_per_cycle=0 (during launches: 0 faults over 0 cycles)
mode=fork ws_mb=512 rt_mb=4 page=16384 mlock=1 prio=70 cycles=29250 launches=93
  done_us p50=10.1 p99=2699.3 p99.9=5344.9 max=6575.3  max_wake_us=5946.9  missed(>667us)=582
  rt_faults total=24022 cycles_with_faults=213 max_per_cycle=258 (during launches: 23994 faults over 1522 cycles)
  launch_call_us p50=2711.2 max=3987.5  launch_to_reap_us p50=11343.5
mode=fork-dontfork ws_mb=512 rt_mb=4 page=16384 mlock=1 prio=70 cycles=29250 launches=91
  done_us p50=10.2 p99=57.2 p99.9=88.9 max=2226.0  max_wake_us=2207.9  missed(>667us)=5
  rt_faults total=91 cycles_with_faults=91 max_per_cycle=1 (during launches: 91 faults over 2200 cycles)
  launch_call_us p50=4355.8 max=6862.5  launch_to_reap_us p50=16423.5
mode=vfork ws_mb=512 rt_mb=4 page=16384 mlock=1 prio=70 cycles=29250 launches=98
  done_us p50=9.7 p99=62.7 p99.9=89.3 max=100.8  max_wake_us=93.3  missed(>667us)=0
  rt_faults total=0 cycles_with_faults=0 max_per_cycle=0 (during launches: 0 faults over 77 cycles)
  launch_call_us p50=111.6 max=681.5  launch_to_reap_us p50=517.3
mode=spawn ws_mb=512 rt_mb=4 page=16384 mlock=1 prio=70 cycles=29250 launches=98
  done_us p50=10.3 p99=30.7 p99.9=49.9 max=97.2  max_wake_us=83.6  missed(>667us)=0
  rt_faults total=0 cycles_with_faults=0 max_per_cycle=0 (during launches: 0 faults over 92 cycles)
  launch_call_us p50=162.4 max=620.7  launch_to_reap_us p50=577.7
mode=fork ws_mb=512 rt_mb=4 page=16384 mlock=0 prio=70 cycles=29250 launches=91
  done_us p50=10.1 p99=4394.3 p99.9=6601.0 max=7364.7  max_wake_us=6717.7  missed(>667us)=882
  rt_faults total=23512 cycles_with_faults=216 max_per_cycle=257 (during launches: 23479 faults over 2176 cycles)
  launch_call_us p50=4066.1 max=4920.8  launch_to_reap_us p50=15955.2
mode=fork ws_mb=200 rt_mb=4 page=16384 mlock=1 prio=70 cycles=29250 launches=94
  done_us p50=9.8 p99=2648.0 p99.9=4679.4 max=8927.2  max_wake_us=8295.3  missed(>667us)=628
  rt_faults total=24284 cycles_with_faults=217 max_per_cycle=257 (during launches: 24256 faults over 1344 cycles)
  launch_call_us p50=2019.8 max=8223.7  launch_to_reap_us p50=9163.5
mode=fork-dontfork ws_mb=512 rt_mb=4 page=16384 mlock=1 prio=70 cycles=29250 launches=91
  done_us p50=10.9 p99=47.7 p99.9=261.1 max=3932.9  max_wake_us=3919.0  missed(>667us)=23
  rt_faults total=92 cycles_with_faults=91 max_per_cycle=2 (during launches: 92 faults over 2214 cycles)
  launch_call_us p50=4314.1 max=6516.4  launch_to_reap_us p50=16308.1
mode=spawn ws_mb=512 rt_mb=4 page=16384 mlock=1 prio=70 cycles=89250 launches=1176
  done_us p50=10.3 p99=49.4 p99.9=82.3 max=137.8  max_wake_us=117.3  missed(>667us)=0
  rt_faults total=0 cycles_with_faults=0 max_per_cycle=0 (during launches: 0 faults over 937 cycles)
  launch_call_us p50=138.8 max=724.8  launch_to_reap_us p50=511.5
# mode none, while a separate sh process ran /bin/true 400 times, 50 ms apart
mode=none ws_mb=512 rt_mb=4 page=16384 mlock=1 prio=70 cycles=29250 launches=0
  done_us p50=10.0 p99=72.2 p99.9=86.3 max=117.2  max_wake_us=106.8  missed(>667us)=0
  rt_faults total=0 cycles_with_faults=0 max_per_cycle=0 (during launches: 0 faults over 0 cycles)
```

</details>
