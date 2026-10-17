#!/usr/bin/env bash
# Tests for segno-ring-flash's own decisions (#1342): the marker it trusts, the
# image it sends, the UART it opens, and the attempt count that stops an image
# the ring keeps rejecting from slowing every boot. The update protocol itself
# runs against the actual ring sketch in firmware/test/test_ring_update.cpp;
# here a small stand-in for the console and ring answers on a pseudo-terminal.
#
# Every path must exit 0: the app starts whatever the ring does.
set -uo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../../../../../.." && pwd)
files="$here/../files"

pass=0
fail=0
build=$(mktemp -d "${TMPDIR:-/tmp}/ring-flash-build.XXXXXX")
trap 'rm -rf "$build"' EXIT
"${CC:-cc}" -std=gnu11 -Wall -Wextra -Werror -O1 \
    -I "$root/firmware/console_board" -I "$root/firmware/libraries/SegnoRing/src" \
    -o "$build/segno-ring-flash" \
    "$files/segno-ring-flash.c" "$files/ring_flash.c" "$root/firmware/console_board/pedal_link.c" || exit 1

# The stand-in: waits for RING_BRIDGE, then answers QUERY with HELLO <hello>,
# and BEGIN with ACK <begin status>, until BRIDGE_END or a quiet second. It
# writes the message types it received to <seen>.
cat > "$build/ring.py" <<'PY'
import os, pty, select, sys, time
hello, begin_status, seen_path, link_path = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
master, slave = pty.openpty()
os.symlink(os.ttyname(slave), link_path)
print("ready", flush=True)

def crc16(data):
    crc = 0xFFFF
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021 if crc & 0x8000 else crc << 1) & 0xFFFF
    return crc

def frame(body):
    body = body + bytes([crc16(body) & 0xFF, crc16(body) >> 8])
    out = bytearray([0xC0])
    for b in body:
        out += {0xC0: b"\xdb\xdc", 0xDB: b"\xdb\xdd"}.get(b, bytes([b]))
    return bytes(out) + b"\xc0"

seen, buf, bridged, body, esc = [], bytearray(), False, bytearray(), False
deadline = time.time() + 4
while time.time() < deadline:
    r, _, _ = select.select([master], [], [], 0.05)
    if not r:
        continue
    data = os.read(master, 4096)
    deadline = time.time() + 1
    buf += data
    if not bridged:
        i = buf.find(bytes([0xA5, 0x12, 0x02, 0x52, 0x42, 0x12 ^ 0x02 ^ 0x52 ^ 0x42]))
        if i < 0:
            continue
        bridged, data = True, bytes(buf[i + 6:])
    if hello == "silent":
        continue
    for b in data:
        if b == 0xC0:
            if len(body) >= 4 and body[0] == 0xB5 and crc16(bytes(body[:-2])) == (body[-2] | body[-1] << 8):
                kind = body[1]
                seen.append(kind)
                if kind == 0x01:
                    major, minor, flags = (int(x) for x in hello.split("."))
                    os.write(master, frame(bytes([0xB5, 0x81, major, minor, 1, flags, 0])))
                elif kind == 0x02:
                    os.write(master, frame(bytes([0xB5, 0x82, 0x02, begin_status, 0, 0, 0, 0])))
                elif kind == 0x06:
                    deadline = 0
            body, esc = bytearray(), False
        elif esc:
            body.append({0xDC: 0xC0, 0xDD: 0xDB}.get(b, b)); esc = False
        elif b == 0xDB:
            esc = True
        else:
            body.append(b)
with open(seen_path, "w") as f:
    f.write(" ".join("%02x" % k for k in seen))
PY

setup() {
    work=$(mktemp -d "${TMPDIR:-/tmp}/ring-flash-test.XXXXXX")
    mkdir -p "$work/fw"
    head -c 5000 /dev/urandom > "$work/fw/ring_board.bin"
    printf 'firmware=1.2 size=5000 sha256=%064d\n' 0 > "$work/fw/version"
    state="$work/data/segno/ring-board"
}
teardown() { rm -rf "$work"; }

# run <hello major.minor.flags | silent> <BEGIN status>
run() {
    rm -f "$work/link" "$work/seen"
    python3 -I "$build/ring.py" "$1" "${2:-0}" "$work/seen" "$work/link" > "$work/ring.out" &
    local ring=$!
    for _ in $(seq 50); do grep -q ready "$work/ring.out" 2>/dev/null && break; sleep 0.1; done
    SEGNO_LINK_DEV="$work/link" SEGNO_RING_FW_DIR="$work/fw" SEGNO_RING_STATE_DIR="$state" \
        "$build/segno-ring-flash" 2>"$work/log"
    status=$?
    # A tool that never bridged leaves the stand-in waiting: do not wait long.
    ( sleep 2; kill "$ring" 2>/dev/null ) &
    wait "$ring" 2>/dev/null
}

check() {
    local name=$1 cond=$2
    if eval "$cond"; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        echo "FAIL: $name"
        echo "  condition: $cond"
        echo "  seen: $(cat "$work/seen" 2>/dev/null)"
        echo "  log:"; sed 's/^/    /' "$work/log"
    fi
}

# A ring on the image's firmware: one QUERY, then the bridge ends.
setup
run 1.2.0
check "current ring exits 0" '[ "$status" = 0 ]'
check "current ring says so" 'grep -q "nothing to do" "$work/log"'
check "current ring: QUERY, BRIDGE_END" '[ "$(cat "$work/seen")" = "01 06" ]'
check "current ring records no attempt" '[ ! -e "$state/attempts" ]'
teardown

# A ring that refuses: each boot counts one attempt, and after three the next
# boot only reports.
setup
for n in 1 2 3; do
    run 1.1.0 2
    check "refused update $n exits 0" '[ "$status" = 0 ]'
    check "refused update $n sends BEGIN" 'grep -q "02" "$work/seen"'
    check "refused update $n is counted" 'grep -qx "firmware=1.2 count=$n" "$state/attempts"'
done
run 1.1.0 2
check "fourth boot does not send" '! grep -q "02" "$work/seen"'
check "fourth boot says why" 'grep -q "not retrying" "$work/log"'
# Once the ring runs the image's firmware, the count is cleared.
run 1.2.0
check "a current ring clears the count" '[ ! -e "$state/attempts" ]'
# A new image version starts its own count.
printf 'firmware=1.3 size=5000 sha256=%064d\n' 0 > "$work/fw/version"
printf 'firmware=1.2 count=3\n' > "$state/attempts"
run 1.1.0 2
check "a new version is tried" 'grep -qx "firmware=1.3 count=1" "$state/attempts"'
teardown

# A ring without the partition table needs its USB install.
setup
run 1.0.2
check "no table says so" 'grep -q "install it once over USB" "$work/log"'
check "no table records no attempt" '[ ! -e "$state/attempts" ]'
teardown

# Silence: an old console or ring firmware. The boot waits about 1.5 s, no
# more, and the next boot of the same image does not wait at all.
setup
start=$(date +%s)
run silent
check "silence exits 0" '[ "$status" = 0 ]'
check "silence says so" 'grep -q "no answer" "$work/log"'
check "silence is short" '[ $(( $(date +%s) - start )) -le 8 ]'
check "silence is recorded" 'grep -qx "firmware=1.2" "$state/silent"'
run 1.2.0
check "a recorded silence skips the ring" '[ ! -s "$work/seen" ] && grep -q "not asking" "$work/log"'
check "the skip says how to ask again" 'grep -q "remove $state/silent" "$work/log"'
# A new image asks again, and an answer clears the record.
printf 'firmware=1.3 size=5000 sha256=%064d\n' 0 > "$work/fw/version"
run 1.3.0
check "a new image asks again" '[ "$(cat "$work/seen")" = "01 06" ]'
check "an answer clears the record" '[ ! -e "$state/silent" ]'
teardown

# Nothing to trust: the ring is left alone.
setup
printf 'firmware=1.2\n' > "$work/fw/version"
run 1.1.0
check "a bad marker exits 0" '[ "$status" = 0 ]'
check "a bad marker refuses" 'grep -q "refusing to guess" "$work/log"'
printf 'firmware=1.2 size=4999 sha256=%064d\n' 0 > "$work/fw/version"
run 1.1.0
check "a wrong size refuses" 'grep -q "does not match its marker" "$work/log"'
rm -f "$work/fw/version"
run 1.1.0
check "no marker is not an error" 'grep -q "nothing to enforce" "$work/log" && [ "$status" = 0 ]'
teardown

setup
SEGNO_LINK_DEV="$work/missing" SEGNO_RING_FW_DIR="$work/fw" SEGNO_RING_STATE_DIR="$state" \
    "$build/segno-ring-flash" 2>"$work/log"
status=$?
check "no UART exits 0" '[ "$status" = 0 ]'
check "no UART says so" 'grep -q "cannot open" "$work/log"'
teardown

echo "segno-ring-flash: $pass passed, $fail failed"
[ "$fail" = 0 ]
