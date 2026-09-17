#!/usr/bin/env python3
"""DIN MIDI bench test for the console board (#1007).

Runs the acceptance test the bench handoff describes
(docs/research/2026-09-05-din-midi-bench.md): three exact 16-byte sequences in
each physical direction, 48/48 bytes per direction, zero UART framing, parity or
overrun errors, with the UART's internal loopback off.

    appliance MIDI OUT  ->  a MIDI interface's IN   (the path U1 drives)
    a MIDI interface's OUT  ->  appliance MIDI IN   (the path U2/H11L1 drives)

Run it ON THE APPLIANCE. The tested image has no `termios`, `ctypes` or
`pyserial`, so the UART is configured through raw `termios2` ioctls -- 31250 baud
is not a POSIX rate, and `stty` cannot set it. Those ioctl numbers are
ABI-specific; the script refuses to run anywhere but 64-bit ARM Linux.

    ./midi_din_test.py --preflight     # look at state, touch nothing
    ./midi_din_test.py --loopback      # prove this script's own UART path
    ./midi_din_test.py                 # the acceptance test, both directions
    ./midi_din_test.py --self-test     # logic only, runs on any machine

The UART settings are saved and restored around every run, and the pedal link's
own UART is refused by name: it carries the console board's traffic.
"""

from __future__ import annotations

import argparse
import fcntl
import os
import platform
import select
import struct
import subprocess
import sys
import time

# ---- the sequence under test ------------------------------------------------
# Note on, note off, three CC 22 values, one clock byte. The clock byte is why
# amidi is given -c: without it, ALSA drops F8 and the capture is 15 bytes.
NOTES = (60, 61, 62)


def sequence(note):
    return bytes((0x90, note, 0x40, 0x80, note, 0x00,
                  0xB0, 0x16, 0x00, 0xB0, 0x16, 0x40, 0xB0, 0x16, 0x7F, 0xF8))


TRIAL_LEN = 16
TOTAL = TRIAL_LEN * len(NOTES)

# ---- Linux arm64 ABI --------------------------------------------------------
TCGETS2, TCSETS2 = 0x802C542A, 0x402C542B
TIOCMBIS, TIOCMBIC, TIOCGICOUNT = 0x5416, 0x5417, 0x545D
TIOCM_LOOP = 0x8000
# struct termios2 { tcflag_t c_iflag, c_oflag, c_cflag, c_lflag; cc_t c_line;
#                   cc_t c_cc[19]; speed_t c_ispeed, c_ospeed; }  -- 44 bytes
TERMIOS2 = "4IB19B2I"
BOTHER, CBAUD = 0o010000, 0o010017
CS8, CLOCAL, CREAD = 0o000060, 0o004000, 0o000200
CSIZE, PARENB, CSTOPB, CRTSCTS = 0o000060, 0o000400, 0o000100, 0o020000000000
# struct serial_icounter_struct: cts dsr rng dcd rx tx frame overrun parity brk
# buf_overrun + 9 reserved
ICOUNTER = "20i"
COUNTER_NAMES = ("cts", "dsr", "rng", "dcd", "rx", "tx",
                 "frame", "overrun", "parity", "brk", "buf_overrun")
ERROR_COUNTERS = ("frame", "overrun", "parity", "brk", "buf_overrun")

BAUD = 31250
PEDAL_LINK = "/dev/ttyAMA3"      # the console board's own UART -- never this one


class Uart(object):
    """The MIDI UART, configured for 31250 8N1 raw and restored on exit."""

    def __init__(self, path):
        if os.path.realpath(path) == os.path.realpath(PEDAL_LINK):
            raise SystemExit("refusing %s: that is the pedal link to the console "
                             "board, not the DIN MIDI UART" % path)
        self.path = path
        self.fd = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
        self.saved = self._get()

    # -- termios2
    def _get(self):
        buf = fcntl.ioctl(self.fd, TCGETS2, b"\x00" * struct.calcsize(TERMIOS2))
        return list(struct.unpack(TERMIOS2, buf))

    def _set(self, t):
        fcntl.ioctl(self.fd, TCSETS2, struct.pack(TERMIOS2, *t))

    def configure(self):
        t = self._get()
        t[0] = 0                                    # c_iflag: no translation
        t[1] = 0                                    # c_oflag: raw
        t[3] = 0                                    # c_lflag: non-canonical
        cflag = t[2] & ~(CBAUD | CSIZE | PARENB | CSTOPB | CRTSCTS)
        t[2] = cflag | BOTHER | CS8 | CLOCAL | CREAD
        t[24], t[25] = BAUD, BAUD                   # c_ispeed, c_ospeed
        t[5 + 6], t[5 + 5] = 0, 0                   # VMIN = 0, VTIME = 0
        self._set(t)
        got = self._get()
        if got[24] != BAUD or got[25] != BAUD:
            raise SystemExit("%s: asked for %d baud, the driver reports %d/%d"
                             % (self.path, BAUD, got[24], got[25]))

    def loopback(self, on):
        fcntl.ioctl(self.fd, TIOCMBIS if on else TIOCMBIC,
                    struct.pack("i", TIOCM_LOOP))

    # -- traffic
    def counters(self):
        try:
            raw = fcntl.ioctl(self.fd, TIOCGICOUNT,
                              b"\x00" * struct.calcsize(ICOUNTER))
        except OSError:
            return {}
        vals = struct.unpack(ICOUNTER, raw)
        return dict(zip(COUNTER_NAMES, vals))

    def flush_rx(self):
        while True:
            r, _w, _x = select.select([self.fd], [], [], 0)
            if not r or not os.read(self.fd, 4096):
                return

    def write(self, data):
        """Write it all, waiting when the tty buffer is full.

        The fd is non-blocking, and 31250 baud drains only ~3.1 kB/s: a long
        --stream run fills the kernel buffer and os.write then raises EAGAIN.
        Waiting for writability is the whole fix.
        """
        sent = 0
        while sent < len(data):
            try:
                sent += os.write(self.fd, data[sent:])
            except BlockingIOError:
                select.select([], [self.fd], [], 1.0)

    def read_exact(self, n, timeout):
        out, deadline = b"", time.monotonic() + timeout
        while len(out) < n and time.monotonic() < deadline:
            r, _w, _x = select.select([self.fd], [], [],
                                      max(0.0, deadline - time.monotonic()))
            if r:
                out += os.read(self.fd, n - len(out))
        return out

    def close(self):
        # Restoring the saved settings is the promise this class makes, so it
        # does not ride on the modem-control ioctl succeeding: a driver that
        # rejects TIOCMBIC would otherwise leave the port at 31250 baud raw.
        try:
            try:
                self.loopback(False)
            except OSError:
                pass
            self._set(self.saved)
        finally:
            os.close(self.fd)


def counter_delta(before, after):
    return dict((k, after.get(k, 0) - before.get(k, 0)) for k in after)


# ---- the MIDI interface on the other end ------------------------------------
def amidi_ports(text):
    """-> [(port, name)] from `amidi -l` output."""
    ports = []
    for line in text.splitlines():
        parts = line.split()
        if len(parts) >= 3 and parts[1].startswith(("hw:", "virtual")):
            ports.append((parts[1], " ".join(parts[2:])))
    return ports


def pick_port(ports, want):
    if want:
        for port, name in ports:
            if want in (port, name) or want.lower() in name.lower():
                return port, name
        raise SystemExit("no MIDI port matches %r; `amidi -l` shows: %s"
                         % (want, ", ".join("%s (%s)" % p for p in ports)))
    named = [p for p in ports if "through" not in p[1].lower()]
    if len(named) != 1:
        raise SystemExit("name the interface with --port: "
                         + (", ".join("%s (%s)" % p for p in ports)
                            or "`amidi -l` is empty"))
    return named[0]


def run(cmd, timeout=10.0):
    """subprocess.run, but a missing binary is a result rather than a traceback:
    amidi is not on every image, and --preflight exists to say so plainly."""
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return subprocess.CompletedProcess(cmd, 127, "", "%s not found" % cmd[0])


def hexs(data):
    return " ".join("%02X" % b for b in data)


# ---- the two directions -----------------------------------------------------
def test_out(uart, port, note, capture):
    """Appliance OUT -> the interface's IN. amidi captures; the UART sends."""
    want = sequence(note)
    before = uart.counters()
    if os.path.exists(capture):
        os.unlink(capture)
    try:
        proc = subprocess.Popen(["amidi", "-p", port, "-r", capture, "-t", "1",
                                 "-a", "-c"],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                text=True)
    except FileNotFoundError:
        raise SystemExit("amidi is not installed -- run --preflight to see what "
                         "this image has")
    time.sleep(0.4)                      # let the capture open before sending
    if proc.poll() is not None:
        err = (proc.stderr.read() or "").strip()
        raise SystemExit("amidi capture exited early: %s" % err)
    uart.write(want)
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
    got = b""
    if os.path.exists(capture):
        with open(capture, "rb") as fh:
            got = fh.read()
    return {"want": want, "got": got,
            "counters": counter_delta(before, uart.counters())}


def test_in(uart, port, note):
    """The interface's OUT -> appliance IN. amidi sends; the UART receives."""
    want = sequence(note)
    uart.flush_rx()
    before = uart.counters()
    sent = run(["amidi", "-p", port, "-S", hexs(want)])
    if sent.returncode != 0:
        raise SystemExit("amidi send failed: %s" % sent.stderr.strip())
    got = uart.read_exact(len(want), timeout=2.0)
    return {"want": want, "got": got,
            "counters": counter_delta(before, uart.counters())}


def test_external_loop(uart, note):
    """A cable from the board's own MIDI OUT to its own MIDI IN.

    The two directions share one UART, so this is the one test that needs no
    second device -- and with IN already proven, bytes arriving here mean the
    OUT path works and the fault is at the other end of the bench.
    """
    want = sequence(note)
    uart.flush_rx()
    before = uart.counters()
    uart.write(want)
    got = uart.read_exact(len(want), timeout=2.0)
    return {"want": want, "got": got,
            "counters": counter_delta(before, uart.counters())}


def test_loopback(uart, note):
    want = sequence(note)
    uart.loopback(True)
    try:
        uart.flush_rx()
        before = uart.counters()
        uart.write(want)
        got = uart.read_exact(len(want), timeout=2.0)
    finally:
        uart.loopback(False)
    return {"want": want, "got": got,
            "counters": counter_delta(before, uart.counters())}


def stream(uart, seconds):
    """Hold the line busy so a multimeter can see it move.

    0x00 bytes are deliberate: a start bit plus eight zero bits is nine bit
    times of current ON out of every ten, so the average at the buffer's output
    (and at DIN pin 5) falls from about 5 V to under 1 V while this runs. A
    meter on a UART's idle line tells you nothing; this gives it something to
    average.
    """
    print("streaming 0x00 for %d s on %s -- measure now" % (seconds, uart.path))
    print("  idle, before this started: DIN OUT pin 5 to ground should read ~5 V")
    print("  while streaming:           it should fall to roughly 0.5-1.5 V")
    end = time.monotonic() + seconds
    sent = 0
    while time.monotonic() < end:
        # 240 bytes per 80 ms is 3.0 kB/s, just under the line's 3.125 kB/s, so
        # the kernel buffer drains rather than filling over a long run.
        uart.write(b"\x00" * 240)
        sent += 240
        time.sleep(0.08)
    print("sent %d bytes" % sent)


# ---- reporting --------------------------------------------------------------
def report(title, trials):
    ok = True
    print("\n%s" % title)
    for note, res in trials:
        want, got = res["want"], res["got"]
        errs = dict((k, v) for k, v in res["counters"].items()
                    if k in ERROR_COUNTERS and v)
        good = got == want and not errs
        ok = ok and good
        print("  note %d: %d/%d bytes  %s%s"
              % (note, len(got), len(want),
                 "exact" if got == want else "MISMATCH",
                 ("  errors %s" % errs) if errs else ""))
        if got != want:
            print("    sent     %s" % hexs(want))
            print("    received %s" % (hexs(got) or "(nothing)"))
        counters = res["counters"]
        if "rx" in counters or "tx" in counters:
            print("    counters rx +%d tx +%d"
                  % (counters.get("rx", 0), counters.get("tx", 0)))
    total = sum(len(r["got"]) for _n, r in trials)
    want_total = sum(len(r["want"]) for _n, r in trials)
    print("  total %d/%d bytes -> %s"
          % (total, want_total, "PASS" if ok else "FAIL"))
    return ok


FAIL_HELP = """
If OUT still fails with the AHCT part fitted, measure before blaming it again
(docs/research/2026-09-05-din-midi-bench.md has the full map):
  * U1 pin 14 to pin 7: 5 V. Pin 10 (enable) must sit at 0 V.
  * With TX idle, U1 pin 9 is about 3.3 V and pin 8 about 5 V.
  * J4 pin 1 -> DIN OUT pin 5 through 220 ohms; J4 pin 2 -> DIN pin 4 through
    220 ohms; J4 pin 3 -> DIN pin 2. Check continuity with the power off.
  * A DIN socket's front and rear views are mirrored -- read the pin numbers,
    do not infer them.
"""


def preflight(args):
    print("machine        %s %s" % (platform.machine(), platform.system()))
    print("uart           %s %s" % (args.uart,
                                    "present" if os.path.exists(args.uart)
                                    else "MISSING"))
    if not os.path.exists(args.uart):
        print("               UART0 is not enabled. The bench session applied "
              "the image's own uart0-pi5\n               overlay at runtime "
              "(it does not survive a reboot).")
    found = run(["sh", "-c", "command -v amidi"]).stdout.strip()
    print("amidi          %s" % (found or "MISSING"))
    ports = amidi_ports(run(["amidi", "-l"]).stdout)
    for port, pname in ports:
        print("midi port      %s  %s" % (port, pname))
    if not ports:
        print("midi port      none -- is the interface plugged in and powered?")
    if os.path.exists(args.uart):
        uart = Uart(args.uart)
        try:
            counters = uart.counters()
            print("counters       %s"
                  % (", ".join("%s %d" % (k, counters[k])
                               for k in ("rx", "tx") if k in counters)
                     or "unavailable"))
        finally:
            uart.close()
    print("\nNothing was changed.")
    return 0


def self_test():
    """The parts that need no hardware, so the script can be checked anywhere."""
    seq = sequence(60)
    assert len(seq) == TRIAL_LEN and seq[:3] == b"\x90\x3c\x40", hexs(seq)
    assert seq[-1] == 0xF8 and sequence(62)[1] == 62
    assert hexs(b"\x90\x3c") == "90 3C"
    listing = ("Dir Device    Name\n"
               "IO  hw:0,0,0  Scarlett 4i4 USB MIDI 1\n"
               "IO  hw:1,0,0  Midi Through Port-0\n")
    ports = amidi_ports(listing)
    assert ports == [("hw:0,0,0", "Scarlett 4i4 USB MIDI 1"),
                     ("hw:1,0,0", "Midi Through Port-0")], ports
    assert pick_port(ports, None)[0] == "hw:0,0,0"          # Through is ignored
    assert pick_port(ports, "scarlett")[0] == "hw:0,0,0"
    assert pick_port(ports, "hw:1,0,0")[1] == "Midi Through Port-0"
    assert struct.calcsize(TERMIOS2) == 44, struct.calcsize(TERMIOS2)
    assert struct.calcsize(ICOUNTER) == 80
    assert counter_delta({"rx": 5, "tx": 1}, {"rx": 9, "tx": 1}) == {"rx": 4, "tx": 0}
    trials = [(60, {"want": seq, "got": seq, "counters": {"rx": 16, "tx": 0}})]
    assert report("self-test: an exact trial", trials)
    bad = [(60, {"want": seq, "got": b"", "counters": {"rx": 0, "tx": 16}})]
    assert not report("self-test: a failed trial", bad)
    framing = [(60, {"want": seq, "got": seq, "counters": {"rx": 16, "frame": 2}})]
    assert not report("self-test: exact bytes but framing errors", framing)
    print("\nself-test: PASS")
    return 0


def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--uart", default="/dev/ttyAMA0", help="the DIN MIDI UART")
    ap.add_argument("--port", help="the MIDI interface, from `amidi -l` "
                                   "(port or a bit of its name)")
    ap.add_argument("--capture", default="/tmp/midi_din_capture.bin")
    ap.add_argument("--preflight", action="store_true",
                    help="report state and change nothing")
    ap.add_argument("--loopback", action="store_true",
                    help="internal UART loopback only -- proves this script, "
                         "not the board")
    ap.add_argument("--external-loop", action="store_true",
                    help="a cable from the board's own MIDI OUT to its own "
                         "MIDI IN: splits the board from the gear at the other "
                         "end, and needs no second device")
    ap.add_argument("--self-test", action="store_true",
                    help="check the script's own logic; no hardware needed")
    ap.add_argument("--only", choices=("in", "out"), help="one direction only")
    ap.add_argument("--stream", type=int, metavar="SECONDS", nargs="?", const=20,
                    help="transmit continuously so the line can be metered")
    args = ap.parse_args()

    if args.self_test:
        return self_test()
    if platform.system() != "Linux" or platform.machine() not in ("aarch64", "arm64"):
        raise SystemExit("run this on the appliance: the ioctl numbers here are "
                         "64-bit ARM Linux ones")
    if args.preflight:
        return preflight(args)
    if not os.path.exists(args.uart):
        raise SystemExit("%s does not exist -- UART0 is not enabled. Apply the "
                         "image's uart0-pi5 overlay, then re-run." % args.uart)

    uart = Uart(args.uart)
    ok = True
    try:
        uart.configure()
        uart.loopback(False)
        if args.stream:
            stream(uart, args.stream)
            print("\nUART settings restored.")
            return 0
        if args.loopback:
            trials = [(n, test_loopback(uart, n)) for n in NOTES]
            ok = report("internal loopback (no board involved)", trials)
        elif args.external_loop:
            trials = [(n, test_external_loop(uart, n)) for n in NOTES]
            ok = report("this board's MIDI OUT -> its own MIDI IN  (one cable)",
                        trials)
        else:
            port, pname = pick_port(
                amidi_ports(run(["amidi", "-l"]).stdout), args.port)
            print("interface      %s  %s" % (port, pname))
            print("uart           %s at %d baud 8N1, loopback off"
                  % (args.uart, BAUD))
            if args.only != "in":
                trials = [(n, test_out(uart, port, n, args.capture)) for n in NOTES]
                ok = report("appliance MIDI OUT -> interface IN  (through U1)",
                            trials) and ok
            if args.only != "out":
                trials = [(n, test_in(uart, port, n)) for n in NOTES]
                ok = report("interface OUT -> appliance MIDI IN  (through U2)",
                            trials) and ok
    finally:
        uart.close()
    print("\nUART settings restored.")
    if not ok:
        print(FAIL_HELP)
    print("RESULT: %s" % ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
