"""Host tests for GPIO ownership and the compositor power lifecycle."""

import importlib.machinery
import importlib.util
import errno
import io
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time
import types
import unittest
from unittest.mock import MagicMock, Mock, patch

FILES = Path(__file__).resolve().parents[1] / "files"
loader = importlib.machinery.SourceFileLoader("screen_power", str(FILES / "segno-screen-power"))
spec = importlib.util.spec_from_loader(loader.name, loader)
power = importlib.util.module_from_spec(spec)
loader.exec_module(power)


class PowerTest(unittest.TestCase):
    def setUp(self):
        self.values = types.SimpleNamespace(ACTIVE=1, INACTIVE=0)
        self.gpiod = types.ModuleType("gpiod")
        self.gpiod.line = types.SimpleNamespace(
            Value=self.values, Direction=types.SimpleNamespace(OUTPUT="output"),
        )
        self.gpiod.LineSettings = Mock(side_effect=lambda **kw: kw)
        self.gpiod.request_lines = Mock()
        self.modules = patch.dict(sys.modules, {
            "gpiod": self.gpiod, "gpiod.line": self.gpiod.line,
        })
        self.modules.start()
        self.addCleanup(self.modules.stop)

    def test_discovers_rp1_and_requests_initially_low(self):
        def chip(path):
            label = "pinctrl-rp1" if path.endswith("4") else "other-controller"
            device = Mock()
            device.get_info.return_value.label = label
            context = Mock()
            context.__enter__ = Mock(return_value=device)
            context.__exit__ = Mock(return_value=False)
            return context

        self.gpiod.Chip = chip
        with patch.object(power.glob, "glob", return_value=["/dev/gpiochip0", "/dev/gpiochip4"]):
            power.request_gpio()
        args, kwargs = self.gpiod.request_lines.call_args
        self.assertEqual(args, ("/dev/gpiochip4",))
        self.assertEqual(kwargs["config"]["GPIO17"]["output_value"], 0)

    def test_missing_controller_never_requests_some_other_gpio(self):
        with patch.object(power.glob, "glob", return_value=[]):
            with self.assertRaises(RuntimeError):
                power.request_gpio()
        self.gpiod.request_lines.assert_not_called()

    def test_low_precedes_discharge_wait_and_gpio_error_propagates(self):
        events = []
        request = Mock()
        request.set_value.side_effect = lambda line, value: events.append((line, value))
        with patch.object(power.time, "sleep", side_effect=lambda delay: events.append(delay)):
            power.set_power(request, False)
        self.assertEqual(events, [("GPIO17", 0), 5.0])
        request.set_value.side_effect = OSError("GPIO lost")
        with patch.object(power.time, "sleep") as wait:
            with self.assertRaises(OSError):
                power.set_power(request, False)
            wait.assert_not_called()

    def test_command_waits_for_ack_and_rejects_missing_ack(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = str(Path(temporary) / "control")
            for response in (b"ok\n", b""):
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
                    server.bind(path)
                    server.listen(1)
                    received = []

                    def serve():
                        connection, _ = server.accept()
                        with connection:
                            received.append(connection.recv(16))
                            connection.sendall(response)

                    worker = threading.Thread(target=serve)
                    worker.start()
                    with patch.object(power, "SOCKET", path):
                        if response:
                            power.command("off")
                        else:
                            with self.assertRaises(RuntimeError):
                                power.command("off")
                    worker.join(2)
                    self.assertFalse(worker.is_alive())
                    self.assertEqual(received, [b"off\n"])
                Path(path).unlink()

    def test_failed_daemon_still_drives_low_before_releasing(self):
        events = []

        class Request:
            def __enter__(self):
                return self

            def __exit__(self, *_):
                events.append("released")

            def set_value(self, line, value):
                events.append((line, value))

        with tempfile.TemporaryDirectory() as temporary, \
                patch.object(power, "SOCKET", str(Path(temporary) / "control")), \
                patch.object(power, "request_gpio", return_value=Request()), \
                patch.object(power, "notify_ready", side_effect=OSError("notify failed")), \
                patch.object(power.signal, "signal"), \
                patch.object(power.time, "sleep", side_effect=lambda delay: events.append(delay)):
            with self.assertRaises(OSError):
                power.daemon()
        self.assertEqual(events, [("GPIO17", 0), 5.0, "released"])

    def test_force_off_reclaims_gpio_after_keeper_dies(self):
        request = Mock()
        request.__enter__ = Mock(return_value=request)
        request.__exit__ = Mock(return_value=False)
        with patch.object(sys, "argv", ["segno-screen-power", "force-off"]), \
                patch.object(power, "request_gpio", return_value=request), \
                patch.object(power.time, "sleep"):
            power.main()
        request.set_value.assert_called_once_with("GPIO17", 0)
        request.__exit__.assert_called_once()

    def test_signal_during_reenable_wait_still_cuts_power(self):
        events = []
        request = MagicMock()
        request.__enter__.return_value = request
        request.set_value.side_effect = lambda line, value: events.append(value)
        request.__exit__.side_effect = lambda *_: events.append("released")
        server = MagicMock()
        server.__enter__.return_value = server
        connections = []
        for data in (b"off\n", b"on\n"):
            connection = MagicMock()
            connection.__enter__.return_value = connection
            connection.makefile.return_value = io.BytesIO(data)
            connections.append((connection, None))
        server.accept.side_effect = connections

        def wait(delay):
            events.append(delay)
            if delay == power.ON_DELAY:
                raise SystemExit(0)  # SIGTERM after GPIO goes high, before ACK.

        with patch.object(power, "request_gpio", return_value=request), \
                patch.object(power.socket, "socket", return_value=server), \
                patch.object(power, "notify_ready"), \
                patch.object(power.os.path, "exists", return_value=False), \
                patch.object(power.os, "chmod"), \
                patch.object(power.signal, "signal"), \
                patch.object(power.time, "sleep", side_effect=wait):
            with self.assertRaises(SystemExit):
                power.daemon()
        self.assertEqual(events, [0, 5.0, 1, 1.0, 0, 5.0, "released"])

    def test_missing_keeper_off_reclaims_but_on_never_bypasses_keeper(self):
        for action in ("on", "off"):
            with patch.object(sys, "argv", ["power", action]), \
                    patch.object(power, "command", side_effect=ConnectionRefusedError), \
                    patch.object(power, "force_off") as reclaim:
                if action == "on":
                    with self.assertRaises(ConnectionRefusedError):
                        power.main()
                    reclaim.assert_not_called()
                else:
                    power.main()
                    reclaim.assert_called_once()

    def test_reclaim_waits_for_cleanup_owner_then_holds_low(self):
        request = Mock()
        request.__enter__ = Mock(return_value=request)
        request.__exit__ = Mock(return_value=False)
        with patch.object(power, "request_gpio", side_effect=[OSError(errno.EBUSY, "busy"), request]), \
                patch.object(power.time, "sleep") as wait:
            power.force_off()
        self.assertEqual([call.args[0] for call in wait.call_args_list], [0.05, 5.0])
        request.set_value.assert_called_once_with("GPIO17", 0)
        request.__exit__.assert_called_once()

    def test_reclaim_times_out_and_does_not_hide_other_gpio_errors(self):
        for code in (errno.EBUSY, errno.ENODEV):
            with patch.object(power, "request_gpio", side_effect=OSError(code, "failed")), \
                    patch.object(power.time, "monotonic", side_effect=[0, 11]), \
                    patch.object(power.time, "sleep") as wait:
                with self.assertRaises(OSError) as error:
                    power.force_off()
                self.assertEqual(error.exception.errno, code)
                wait.assert_not_called()

    def test_successful_cleanup_does_not_repeat_completed_discharge(self):
        with patch.object(sys, "argv", ["power", "force-off"]), \
                patch.dict(power.os.environ, {"SERVICE_RESULT": "success"}), \
                patch.object(power, "force_off") as reclaim:
            power.main()
        reclaim.assert_not_called()

    def test_live_keeper_on_off_bad_command_and_termination(self):
        # Run the actual socket loop and signal handler in a process. Only GPIO
        # and wall-clock delays are replaced; command framing/ownership is real.
        with tempfile.TemporaryDirectory(dir="/tmp") as temporary:
            folder = Path(temporary)
            path = str(folder / "control")
            events = folder / "events"
            child = r'''
import importlib.machinery, importlib.util, sys, types
loader = importlib.machinery.SourceFileLoader("power", sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
power = importlib.util.module_from_spec(spec)
loader.exec_module(power)
power.SOCKET = sys.argv[2]
power.ON_DELAY = power.OFF_DELAY = 0.01
power.notify_ready = lambda: None
sys.modules["gpiod.line"] = types.SimpleNamespace(Value=types.SimpleNamespace(ACTIVE=1, INACTIVE=0))
class Request:
    def __enter__(self): return self
    def __exit__(self, *_):
        with open(sys.argv[3], "a") as log: log.write("release\n")
    def set_value(self, line, value):
        with open(sys.argv[3], "a") as log: log.write(str(value) + "\n")
power.request_gpio = Request
power.daemon()
'''
            process = subprocess.Popen([
                sys.executable, "-c", child, str(FILES / "segno-screen-power"),
                path, str(events),
            ], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                deadline = time.monotonic() + 5
                while not Path(path).exists() and time.monotonic() < deadline:
                    if process.poll() is not None:
                        self.fail(process.communicate()[1].decode())
                    time.sleep(0.01)
                with patch.object(power, "SOCKET", path):
                    power.command("on")
                    with self.assertRaises(RuntimeError):
                        power.command("invalid")
                    power.command("off")
                    power.command("on")
                process.terminate()
                _, errors = process.communicate(timeout=5)
                self.assertEqual(process.returncode, 0, errors.decode())
                self.assertEqual(events.read_text().splitlines(), ["1", "0", "1", "0", "release"])
            finally:
                if process.poll() is None:
                    process.kill()
                    process.communicate()


if __name__ == "__main__":
    unittest.main()
