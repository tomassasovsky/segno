#!/usr/bin/env bash
# Wiring tests for the weston drop-in (#947, #825).
#
# Whether compositor lines actually appear in /run/user/1000/weston.log needs
# a device. What CANNOT be shown on a device once and then trusted is the
# wiring, because every way of breaking it is silent:
#
#   - drop the file from SRC_URI / do_install / FILES and the image ships
#     the stock ExecStart, so weston.log is never written and #825 is
#     debugged blind again.
#   - append a second ExecStart= without the clearing ExecStart= and systemd
#     runs both, or ignores the override.
#   - put ExecStart= under [Unit] (or PartOf= under [Service]) and systemd
#     ignores the key.
#   - lose systemd-notify.so and Type=notify hangs until timeout — a dark
#     screen, not a missing log.
#   - pass --log=/dev/stderr and weston exits 1 (User=weston cannot write it).
#   - leave --logger-scopes=drm-backend on and /run fills with per-frame dumps.
#   - drop StartLimitIntervalSec=0 and a segno Restart=always crash-loop can
#     start-limit weston into a dark screen.
#
# So this asserts the drop-in and the recipe inventory statically.
set -uo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BB="$here/../weston-init.bbappend"
DROPIN="$here/../files/20-segno-weston.conf"
DROPIN_NAME=$(basename "$DROPIN")
TMPFILES="$here/../../../recipes-segno/segno-bundle/files/segno-runtime.conf"

pass=0
fail=0

check() {
    local label=$1 expected=$2 actual=$3
    if [ "$expected" = "$actual" ]; then
        echo "  ok   $label"
        pass=$((pass + 1))
    else
        echo "  FAIL $label (expected '$expected', got '$actual')"
        fail=$((fail + 1))
    fi
}

# Lines of a systemd drop-in section, excluding the header.
section() {
    awk -v sec="[$1]" '
        $0 == sec { insec = 1; next }
        insec && /^\[/ { exit }
        insec { print }
    ' "$2"
}

# The block of a line-continued bitbake assignment, from the line that opens it
# through the first line that does not end in a backslash.
bb_block() {
    awk -v start="$1" '
        index($0, start) == 1 { inblock = 1 }
        inblock { print; if ($0 !~ /\\$/) exit }
    ' "$BB"
}

# Drop whole-line and trailing comments so `file://foo  # file://bar` does
# not count as shipping bar.
strip_comments() { sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d'; }

in_src_uri() {
    bb_block 'SRC_URI' | strip_comments |
        grep -qE "(^|[[:space:]\"])file://$1(\"|[[:space:]]|$)" &&
        echo yes || echo no
}

# Entries are separated by spaces, line continuations and the closing quote —
# flatten those to spaces so the last entry in the block matches like any other.
in_files() {
    bb_block 'FILES:${PN}' | strip_comments | tr '\\"' '  ' |
        grep -qF -- " $1 " && echo yes || echo no
}

installed() {
    # Join bitbake continuations, then require a non-comment `install` that
    # names both the UNPACKDIR source and the weston.service.d dest. A
    # whole-file grep still matches a commented-out stanza.
    sed -e :a -e '/\\$/N; s/\\\n//; ta' "$BB" |
        grep -vE '^[[:space:]]*#' |
        grep -E '^[[:space:]]*install ' |
        grep -F -- "\${UNPACKDIR}/$1" |
        grep -qF -- "\${D}\${systemd_system_unitdir}/weston.service.d/$1" &&
        echo yes || echo no
}

join_continuations() { sed -e :a -e '/\\$/N; s/\\\n//; ta'; }

unit=$(section Unit "$DROPIN" | join_continuations)
service=$(section Service "$DROPIN" | join_continuations)
exec_start=$(printf '%s\n' "$service" | grep -E '^ExecStart=/usr/bin/weston' || true)
exec_start_count=$(printf '%s\n' "$exec_start" | grep -c . || true)
log_count=$(printf '%s' "$exec_start" | grep -oE -- '--log=[^[:space:]]+' | grep -c . || true)

echo "the drop-in bounces weston with segno and does not start-limit"
check "PartOf=segno.service is a [Unit] line" yes \
    "$(printf '%s\n' "$unit" | grep -qx 'PartOf=segno.service' && echo yes || echo no)"
check "StartLimitIntervalSec=0 is a [Unit] line" yes \
    "$(printf '%s\n' "$unit" | grep -qx 'StartLimitIntervalSec=0' && echo yes || echo no)"

echo "the drop-in replaces ExecStart under [Service] and keeps notify"
check "clears stock ExecStart first" yes \
    "$(printf '%s\n' "$service" | awk '
        $0 == "ExecStart=" { empty = 1; next }
        empty && $0 ~ /^ExecStart=/ { print "yes"; exit }
        END { if (!empty) print "no" }
    ')"
check "exactly one weston ExecStart" 1 "$exec_start_count"
check "keeps systemd-notify.so (Type=notify)" yes \
    "$(printf '%s' "$exec_start" | grep -qF -- '--modules=systemd-notify.so' && echo yes || echo no)"
check "exactly one --log=" 1 "$log_count"
check "that --log= is the weston-writable path" yes \
    "$(printf '%s' "$exec_start" | grep -qE -- '--log=/run/user/1000/weston.log( |$)' && echo yes || echo no)"
check "does not log to /dev/stderr or /dev/fd/2" yes \
    "$(printf '%s' "$exec_start" | grep -qE -- '/dev/(stderr|fd/2)' && echo no || echo yes)"
check "does not enable drm-backend scope by default (per-frame flood)" yes \
    "$(printf '%s' "$exec_start" | grep -qF -- '--logger-scopes=' && echo no || echo yes)"

echo "the recipe ships the drop-in"
check "drop-in file is *.conf (systemd only loads those)" yes \
    "$(printf '%s' "$DROPIN_NAME" | grep -qE '\.conf$' && echo yes || echo no)"
check "SRC_URI names the drop-in" yes "$(in_src_uri "$DROPIN_NAME")"
check "do_install writes it under weston.service.d" yes "$(installed "$DROPIN_NAME")"
check "FILES names the drop-in (else it is installed-but-not-shipped)" yes \
    "$(in_files '${systemd_system_unitdir}/weston.service.d/'"$DROPIN_NAME")"
check "SRC_URI still names weston.ini" yes "$(in_src_uri weston.ini)"
check "do_install still writes weston.ini" yes \
    "$(sed -e :a -e '/\\$/N; s/\\\n//; ta' "$BB" |
        grep -vE '^[[:space:]]*#' |
        grep -E '^[[:space:]]*install ' |
        grep -qF -- '${D}${sysconfdir}/xdg/weston/weston.ini' && echo yes || echo no)"

echo "tmpfiles still creates the log directory for User=weston"
check "segno-runtime.conf creates /run/user/1000" yes \
    "$(grep -qx 'd /run/user/1000 0700 weston weston -' "$TMPFILES" && echo yes || echo no)"

echo
echo "weston-log: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
echo "ALL PASSED"
