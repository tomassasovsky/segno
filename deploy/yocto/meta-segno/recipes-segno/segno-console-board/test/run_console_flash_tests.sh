#!/usr/bin/env bash
# Tests for `segno-console-flash` (#989).
#
# Reprogramming the board needs hardware; DECIDING whether to reprogram it does
# not, and the decision is the part with teeth:
#
#   * flashing a board that already matches wastes a reset on every boot, and
#     resets the panel in front of a performer.
#   * NOT flashing a board that disagrees is the failure this exists to end —
#     the app reports "incompatible" and, before this, the only cure was a
#     laptop and a ribbon.
#   * a console with no board attached must still boot the app. Every path that
#     cannot flash has to exit 0.
#
# So openocd is stubbed into a transcript and the transcript asserted, with the
# board's HELLO faked as bytes on a file standing in for the device node.
set -uo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SCRIPT="$here/../files/segno-console-flash"

pass=0
fail=0

setup() {
    work=$(mktemp -d "${TMPDIR:-/tmp}/console-flash-test.XXXXXX")
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
echo "pinctrl $*" >> "$CALLS"
STUB
    chmod +x "$work/bin/pinctrl"

    printf 'ELF' > "$work/fw/console_board.elf"
    printf 'config' > "$work/fw/pi5-swd.cfg"
    printf 'protocol=3 firmware=1.0\n' > "$work/fw/version"
}

teardown() { rm -rf "$work"; }

# Writes a HELLO frame — A5 03 03 <protocol> <major> <minor> <xor> — into the
# file the script reads as its device node.
say_hello() {
    local proto=$1 major=$2 minor=$3
    local xor=$(( 0x03 ^ 0x03 ^ proto ^ major ^ minor ))
    printf "$(printf '\\x%02x\\x03\\x03\\x%02x\\x%02x\\x%02x\\x%02x' 165 "$proto" "$major" "$minor" "$xor")" \
        > "$work/link"
}

run() {
    CALLS="$work/calls" \
    SEGNO_LINK_DEV="${1:-$work/link}" \
    SEGNO_CONSOLE_FW_DIR="$work/fw" \
    SEGNO_OPENOCD="$work/bin/openocd" \
    SEGNO_PINCTRL="$work/bin/pinctrl" \
    SEGNO_CONSOLE_LISTEN_SECONDS=1 \
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
        echo "  calls:"; sed 's/^/    /' "$work/calls"
        echo "  log:"; sed 's/^/    /' "$work/log"
    fi
}

# A board already running what shipped is left alone.
setup
say_hello 3 1 0
run >/dev/null; status=$?
check "matching board is not flashed" '[ ! -s "$work/calls" ]'
check "matching board exits 0" '[ "$status" = 0 ]'
teardown

# A board on an older protocol is exactly the case the version byte exists for.
setup
say_hello 2 1 0
run >/dev/null; status=$?
check "older protocol is flashed" 'grep -q "openocd .*program .*console_board.elf verify reset exit" "$work/calls"'
check "flash pulls SWDIO up first" '[ "$(head -1 "$work/calls" | cut -d" " -f1)" = pinctrl ]'
check "older protocol exits 0" '[ "$status" = 0 ]'
teardown

# Same protocol, older firmware: still a mismatch with what the image ships.
setup
say_hello 3 0 9
run >/dev/null; status=$?
check "older firmware is flashed" 'grep -q "program" "$work/calls"'
teardown

# A silent board may be unflashed rather than absent, and flashing is safe.
setup
: > "$work/link"
run >/dev/null; status=$?
check "silent board is flashed" 'grep -q "program" "$work/calls"'
check "silent board exits 0" '[ "$status" = 0 ]'
teardown

# No device node at all: nothing to ask, but a blank board still deserves one.
setup
run "$work/absent" >/dev/null; status=$?
check "absent link still attempts a flash" 'grep -q "program" "$work/calls"'
check "absent link exits 0" '[ "$status" = 0 ]'
teardown

# A failed flash must never keep the app from booting.
setup
say_hello 2 1 0
OPENOCD_EXIT=1 run >/dev/null; status=$?
check "failed flash exits 0" '[ "$status" = 0 ]'
check "failed flash is logged" 'grep -q "flashing failed" "$work/log"'
teardown

# Nothing to enforce is not an error either.
setup
rm "$work/fw/version"
run >/dev/null; status=$?
check "missing marker exits 0" '[ "$status" = 0 ]'
check "missing marker flashes nothing" '[ ! -s "$work/calls" ]'
teardown

setup
rm "$work/fw/console_board.elf"
run >/dev/null; status=$?
check "missing firmware exits 0" '[ "$status" = 0 ]'
check "missing firmware flashes nothing" '[ ! -s "$work/calls" ]'
teardown

echo "console-flash: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
