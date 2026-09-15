#!/usr/bin/env bash
# Real sockets and the production shell helpers; no compositor or device needed.
set -euo pipefail
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
python3 - "$here/../files" <<'PY'
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import unittest

files = Path(sys.argv.pop())

class StartupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="segno-wl-", dir="/tmp")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.sock = self.root / "wayland-1"
        self.env = dict(os.environ, XDG_RUNTIME_DIR=str(self.root),
                        WAYLAND_DISPLAY="wayland-1",
                        SEGNO_WAYLAND_WAIT_ATTEMPTS="1",
                        SEGNO_WAYLAND_SETTLE_SECS="0.02")

    def socket(self):
        sock = socket.socket(socket.AF_UNIX)
        sock.bind(str(self.sock))
        sock.listen(1)
        self.addCleanup(sock.close)

    def run_wait(self):
        return subprocess.run(["sh", str(files / "segno-wait-wayland")],
                              env=self.env, capture_output=True, timeout=5)

    def test_missing_socket(self):
        result = self.run_wait()
        self.assertEqual(result.returncode, 1)
        self.assertIn(b"not ready", result.stderr)

    def test_regular_file_is_not_ready(self):
        self.sock.touch()
        self.assertEqual(self.run_wait().returncode, 1)

    def test_stable_socket(self):
        self.socket()
        self.assertEqual(self.run_wait().returncode, 0)

    def test_absolute_display_path(self):
        self.socket()
        self.env["WAYLAND_DISPLAY"] = str(self.sock)
        del self.env["XDG_RUNTIME_DIR"]
        self.assertEqual(self.run_wait().returncode, 0)

    def change_during_wait(self, change, attempts=1):
        # Pause the first production sleep so socket replacement is deterministic.
        sleeper = self.root / "sleep"
        sleeper.write_text('''#!/bin/sh
if [ ! -f "$XDG_RUNTIME_DIR/sleeping" ]; then
  touch "$XDG_RUNTIME_DIR/sleeping"
  while [ ! -f "$XDG_RUNTIME_DIR/resume" ]; do /bin/sleep 0.01; done
fi
''')
        sleeper.chmod(0o755)
        self.env["PATH"] = str(self.root) + os.pathsep + os.environ["PATH"]
        self.env["SEGNO_WAYLAND_WAIT_ATTEMPTS"] = str(attempts)
        with subprocess.Popen(["sh", str(files / "segno-wait-wayland")],
                              env=self.env, stderr=subprocess.PIPE) as process:
            try:
                deadline = time.monotonic() + 5
                while not (self.root / "sleeping").exists():
                    if time.monotonic() > deadline:
                        self.fail("helper never entered its wait")
                    time.sleep(0.01)
                change()
                (self.root / "resume").touch()
                return process.wait(timeout=5)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()

    def test_socket_disappearing_during_settle_is_rejected(self):
        self.socket()
        self.assertEqual(self.change_during_wait(self.sock.unlink), 1)

    def test_replacement_socket_must_settle_again(self):
        self.socket()
        def replace():
            self.sock.unlink()
            self.socket()
        self.assertEqual(self.change_during_wait(replace), 1)

    def test_late_socket_can_become_ready(self):
        self.assertEqual(self.change_during_wait(self.socket, attempts=2), 0)

    def test_launcher_propagates_wait_failure(self):
        # Run its exact final launch block with only absolute executable paths
        # redirected into this sandbox; none of the device setup above runs.
        launch = (files / "segno-kiosk-launch").read_text()
        block = launch[launch.index("export SEGNO_WAVEFORM_OPEN_DELAY_MS="):]
        wait = self.root / "wait"
        app = self.root / "app"
        app.write_text('#!/bin/sh\n: > "$XDG_RUNTIME_DIR/launched"\n'
                       '[ "$SEGNO_WAVEFORM_OPEN_DELAY_MS" = 750 ]\n')
        app.chmod(0o755)
        block = block.replace("/usr/bin/segno-wait-wayland", str(wait))
        block = block.replace("/opt/segno/segno", str(app))
        for code in (1, 0):
            wait.write_text(f"#!/bin/sh\nexit {code}\n")
            wait.chmod(0o755)
            result = subprocess.run(["sh", "-c", block], env=self.env)
            self.assertEqual(result.returncode, code)
            self.assertEqual((self.root / "launched").exists(), code == 0)

unittest.main()
PY
