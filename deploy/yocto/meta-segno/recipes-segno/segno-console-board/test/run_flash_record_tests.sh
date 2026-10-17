#!/usr/bin/env bash
# Tests for the record `segno-console-flash` leaves after a verified program
# (#1270 Part 12).
#
# The app's About page reads the board's firmware from its HELLO while the
# link is up, and from this record when it is not: a silent board is exactly
# the one whose version someone needs to read. So the record must say what was
# flashed, only when the flash verified, and writing it must never cost the
# console its boot.
set -uo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SCRIPT="$here/../files/segno-console-flash"

pass=0
fail=0

setup() {
    work=$(mktemp -d "${TMPDIR:-/tmp}/flash-record-test.XXXXXX")
    mkdir -p "$work/bin" "$work/fw"
    : > "$work/calls"

    cat > "$work/bin/openocd" <<'STUB'
#!/usr/bin/env bash
echo "openocd $*" >> "$CALLS"
exit "${OPENOCD_EXIT:-0}"
STUB
    chmod +x "$work/bin/openocd"

    cat > "$work/bin/pinctrl" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "$work/bin/pinctrl"

    printf 'ELF' > "$work/fw/console_board.elf"
    printf 'config' > "$work/fw/pi5-swd.cfg"
    printf 'protocol=3 firmware=1.4\n' > "$work/fw/version"
    record="$work/data/segno/console-board/last-flashed"
}

teardown() { rm -rf "$work"; }

# HELLO: A5 03 03 <protocol> <major> <minor> <xor>.
say_hello() {
    local proto=$1 major=$2 minor=$3
    local xor=$(( 0x03 ^ 0x03 ^ proto ^ major ^ minor ))
    printf "$(printf '\\x%02x\\x03\\x03\\x%02x\\x%02x\\x%02x\\x%02x' 165 "$proto" "$major" "$minor" "$xor")" \
        > "$work/link"
}

run() {
    CALLS="$work/calls" \
    SEGNO_LINK_DEV="$work/link" \
    SEGNO_CONSOLE_FW_DIR="$work/fw" \
    SEGNO_OPENOCD="$work/bin/openocd" \
    SEGNO_PINCTRL="$work/bin/pinctrl" \
    SEGNO_CONSOLE_LISTEN_SECONDS=1 \
    SEGNO_CONSOLE_RECORD="$record" \
    OPENOCD_EXIT="${OPENOCD_EXIT:-0}" \
    bash "$SCRIPT" 2>"$work/log"
}

check() {
    local name=$1 cond=$2
    if eval "$cond"; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        echo "FAIL: $name"
        echo "  condition: $cond"
        echo "  record:"; [ -e "$record" ] && sed 's/^/    /' "$record"
        echo "  log:"; sed 's/^/    /' "$work/log"
    fi
}

# A verified program records what it put on the board.
setup
say_hello 2 1 0
run >/dev/null; status=$?
check "successful program writes the record" '[ "$(cat "$record")" = "firmware=1.4 protocol=3" ]'
check "successful program exits 0" '[ "$status" = 0 ]'
check "no temp file is left behind" '[ ! -e "$record.tmp" ]'
teardown

# A failed program records nothing: the board is not running what shipped.
setup
say_hello 2 1 0
OPENOCD_EXIT=1 run >/dev/null; status=$?
check "failed program writes nothing" '[ ! -e "$record" ]'
check "failed program exits 0" '[ "$status" = 0 ]'
teardown

# A failed program leaves an earlier record alone: it still names the last
# firmware this console verified onto the board.
setup
say_hello 2 1 0
mkdir -p "$(dirname "$record")"
printf 'firmware=1.3 protocol=3\n' > "$record"
OPENOCD_EXIT=1 run >/dev/null; status=$?
check "failed program keeps the earlier record" '[ "$(cat "$record")" = "firmware=1.3 protocol=3" ]'
teardown

# A board already running what shipped is not flashed, so nothing is recorded.
setup
say_hello 3 1 4
run >/dev/null; status=$?
check "matching board writes no record" '[ ! -e "$record" ]'
check "matching board exits 0" '[ "$status" = 0 ]'
teardown

# A data volume that refuses the write costs the record, never the boot.
setup
say_hello 2 1 0
mkdir -p "$work/data"
: > "$work/data/segno"   # a file where the directory should be
run >/dev/null; status=$?
check "unwritable record still exits 0" '[ "$status" = 0 ]'
check "unwritable record is logged" 'grep -q "could not record" "$work/log"'
check "unwritable record still reports the flash" 'grep -q "flashed firmware 1.4" "$work/log"'
teardown

echo "flash-record: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
