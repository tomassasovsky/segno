/// Starts helper programs with `posix_spawn` through `dart:ffi`, never with
/// `fork`.
///
/// `dart:io`'s `Process.run` and `Process.start` call `fork()` on Linux. On
/// the appliance that copies the app's page tables and write-protects every
/// private page, and the real-time audio thread stalls for milliseconds
/// behind it (#1367, `docs/brainstorm/2026-10-19-no-fork-helpers-brainstorm-doc.md`).
/// `posix_spawn` (glibc: `clone(CLONE_VM | CLONE_VFORK)`) copies no page
/// table and stops only the calling thread until the child execs.
///
/// `startProcess` and `runProcess` cover what the app uses of `Process`:
/// stdin, streamed stdout and stderr, the exit code, kill and a timeout.
///
/// - Each call runs on its own worker isolate, which makes the calls that
///   wait (`posix_spawnp`, `poll`) and polls the pipes, so the calling
///   isolate never blocks. The worker wakes every 100 ms while the child
///   runs.
/// - The child keeps only stdin, stdout and stderr: the app's other
///   descriptors are closed in it (`posix_spawn_file_actions_addclosefrom_np`
///   on Linux, `POSIX_SPAWN_CLOEXEC_DEFAULT` on macOS).
/// - The child runs in a process group of its own. `SpawnedProcess.kill`
///   and a timeout signal the whole group, so what the child started (a
///   helper's `ddcutil`) goes with it and releases the pipes.
/// - After the child exits, the worker reads its pipes for at most a second
///   more, so a program the child left running cannot keep the worker alive.
/// - The worker's thread blocks SIGPIPE while it runs, so writing to a stdin
///   the child closed fails with EPIPE whether or not the process ignores
///   SIGPIPE.
///
/// ## The invariant: nothing in the app uses `dart:io` `Process`
///
/// The Dart VM collects the exit status of its own children on a thread that
/// calls `wait()` for any child (`runtime/bin/process_linux.cc`,
/// `ExitCodeHandler`). That thread starts with the first `Process.start` or
/// `Process.run`, and calls `wait()` only while at least one child it
/// started is still running. While it does, it can reap a child started
/// here, and this package then reports a `ProcessException` with `ECHILD`
/// in place of the exit code.
///
/// So the app must start no process through `dart:io`: then the VM's thread
/// never starts and only this package waits for children. A CI step
/// (`tool/check_no_dart_process.sh`) fails on `Process.run`,
/// `Process.start` and `Process.runSync` in `lib/`, `packages/*/lib` and the
/// app's runtime dependencies, apart from an allowlist that names why each
/// entry is never reached. `path_provider`'s documents and downloads lookups
/// run `xdg-user-dir` on Linux, so the app resolves its documents directory
/// itself there.
///
/// This package never waits for any child but its own: the worker checks
/// the child's pid with `waitid(P_PID, pid, WEXITED | WNOWAIT | WNOHANG)`,
/// which does not reap, and the calling isolate then reaps it with
/// `waitpid(pid)`. The pid stays reserved until then, so
/// `SpawnedProcess.kill` cannot reach a recycled pid. When `SIGCHLD` is
/// ignored in the process, the kernel reaps children itself and no exit
/// status exists; the error says so.
library;

export 'src/spawned_process.dart' show SpawnedProcess, runProcess, startProcess;
