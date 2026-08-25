#!/usr/bin/env bash
# Tests for the persistent journal + coredump storage (#438).
#
# Whether the journal really survives a reboot needs a device, and it has been
# shown on one (`journalctl -b -1` returned 6521 lines of the previous boot).
# What CANNOT be shown on a device once and then trusted is the wiring, because
# every way of breaking it is silent:
#
#   - rename a .mount file and it no longer matches its escaped Where=. systemd
#     never starts it, journald writes to the tmpfs underneath, `journalctl`
#     looks perfectly healthy, and `journalctl -b -1` is empty after the next
#     reboot.
#   - drop a unit from SYSTEMD_SERVICE and it ships disabled: same symptom.
#   - install a file under /etc without naming it in FILES:${PN} and the
#     recipe's own inventory of what it owns goes stale.
#
# So this asserts the wiring statically, and asserts that segno-log-check —
# which exists precisely because the RAM fallback is invisible — actually calls
# the fallback a failure. Every path it reads is injected; no device involved.
set -uo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SCRIPT="$here/../files/segno-log-check"
BB="$here/../segno-bundle.bb"
FILES_DIR="$here/../files"

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

# --- segno-log-check: is the RAM fallback loud? ------------------------------

setup() {
    work=$(mktemp -d "${TMPDIR:-/tmp}/log-persist-test.XXXXXX")
    mkdir -p "$work/journal/3f9a2c" "$work/coredump"
    : > "$work/journal/3f9a2c/system.journal"
    : > "$work/mountinfo"
}

teardown() { rm -rf "$work"; }

# One /proc/self/mountinfo line: id, device (major:minor), mount point. The
# device is the field that matters — a bind mount reports the device of the
# filesystem its source came from, which is how "bound to /data" is told apart
# from "still the tmpfs underneath".
mnt() {
    printf '%s 25 %s / %s rw,relatime shared:1 - ext4 /dev/disk rw\n' \
        "$1" "$2" "$3" >> "$work/mountinfo"
}

# The state a working console is in: /data mounted, both bind mounts on it.
healthy_mounts() {
    mnt 30 179:2 /data
    mnt 31 179:2 "$work/journal"
    mnt 32 179:2 "$work/coredump"
}

run_check() {
    SEGNO_MOUNTINFO="$work/mountinfo" \
    SEGNO_DATA_DIR=/data \
    SEGNO_JOURNAL_DIR="$work/journal" \
    SEGNO_COREDUMP_DIR="$work/coredump" \
    SEGNO_LOG_MARKER="$work/marker" \
        sh "$SCRIPT" 2>"$work/stderr"
}

marker() { [ -f "$work/marker" ] && echo yes || echo no; }
said() { grep -qF -- "$1" "$work/stderr" && echo yes || echo no; }

echo "everything landed on /data"
setup
healthy_mounts
run_check; rc=$?
check "exits 0" 0 "$rc"
check "leaves no degraded marker" no "$(marker)"
check "says where the evidence lives" yes "$(said "journal and coredumps are on /data")"
teardown

echo "a previous boot was degraded and this one is not"
setup
healthy_mounts
printf 'stale\n' > "$work/marker"
run_check
check "clears the stale marker" no "$(marker)"
teardown

echo "the journal bind mount never landed"
setup
mnt 30 179:2 /data
mnt 32 179:2 "$work/coredump"
run_check; rc=$?
# This is the whole reason the script exists: journald reports success while
# writing into RAM, so nothing else in the system will ever say this.
check "fails" 1 "$rc"
check "drops the marker the app can read" yes "$(marker)"
check "names the journal" yes "$(said "the journal is not mounted")"
check "says the boot's evidence dies with it" yes "$(said "dies with the boot")"
teardown

echo "the journal is mounted, but on the tmpfs"
setup
mnt 30 179:2 /data
mnt 31 0:22 "$work/journal"
mnt 32 179:2 "$work/coredump"
run_check; rc=$?
check "fails" 1 "$rc"
check "names the wrong device" yes "$(said "is on device 0:22, not on /data")"
teardown

echo "coredump storage never landed"
setup
mnt 30 179:2 /data
mnt 31 179:2 "$work/journal"
run_check; rc=$?
check "fails" 1 "$rc"
check "names coredump storage" yes "$(said "coredump storage is not mounted")"
teardown

echo "/data itself is not mounted"
setup
run_check; rc=$?
check "fails" 1 "$rc"
check "says so first" yes "$(said "/data is not mounted")"
teardown

echo "mounts are right but journald never wrote there"
setup
healthy_mounts
rm -f "$work/journal/3f9a2c/system.journal"
run_check; rc=$?
# A journald.conf.d drop-in that failed to land looks exactly like a mount that
# failed to land, and neither says anything on its own.
check "fails" 1 "$rc"
check "names journald rather than the mount" yes "$(said "journald is not writing there")"
teardown

echo "mountinfo cannot be read"
setup
healthy_mounts
chmod 000 "$work/mountinfo"
run_check; rc=$?
check "refuses to report health it could not check" 1 "$rc"
teardown

# --- the wiring: shipped, enabled, packaged, correctly named -----------------

# The block of a line-continued bitbake assignment, from the line that opens it
# through the first line that does not end in a backslash.
bb_block() {
    awk -v start="$1" '
        index($0, start) == 1 { inblock = 1 }
        inblock { print; if ($0 !~ /\\$/) exit }
    ' "$BB"
}

# Entries are separated by spaces, line continuations and the closing quote —
# flatten those to spaces so the last entry in the block matches like any other.
in_files() {
    bb_block 'FILES:${PN}' | tr '\\"' '  ' | grep -qF -- " $1 " && echo yes || echo no
}

systemd_service_line() { grep -F 'SYSTEMD_SERVICE:${PN}' "$BB"; }

enabled() {
    systemd_service_line | grep -qE "[\" ]$(printf '%s' "$1" | sed 's/\./\\./g')[\" ]" &&
        echo yes || echo no
}

echo "the units this feature ships are enabled and packaged"
for unit in segno-log-dirs.service segno-log-check.service \
    var-volatile-log-journal.mount var-lib-systemd-coredump.mount; do
    check "$unit is in SRC_URI" yes \
        "$(grep -qF "file://$unit" "$BB" && echo yes || echo no)"
    check "$unit is installed" yes \
        "$(grep -qF "\${UNPACKDIR}/$unit " "$BB" && echo yes || echo no)"
    check "$unit is in SYSTEMD_SERVICE (else it ships disabled)" yes "$(enabled "$unit")"
    check "$unit is in FILES" yes "$(in_files "\${systemd_system_unitdir}/$unit")"
done

echo "the drop-ins land in the right conf.d"
check "journald drop-in installed under journald.conf.d" yes \
    "$(grep -qF '${sysconfdir}/systemd/journald.conf.d/10-segno.conf' "$BB" && echo yes || echo no)"
check "coredump drop-in installed under coredump.conf.d" yes \
    "$(grep -qF '${sysconfdir}/systemd/coredump.conf.d/10-segno.conf' "$BB" && echo yes || echo no)"

echo "the policy that keeps the RAM fallback visible and boot un-held"
# Storage=persistent would make journald build a healthy-looking journal on
# the tmpfs whenever the bind mount fails; auto ties "persistent" to the mount
# having landed. And both bind mounts sit Before= early-boot units, so without
# a job timeout a missing /data holds boot for DefaultTimeoutStartSec (~90 s).
check "journald drop-in says Storage=auto" yes \
    "$(grep -qx 'Storage=auto' "$FILES_DIR/journald-segno.conf" && echo yes || echo no)"
for unit_path in "$FILES_DIR"/var-*.mount; do
    unit=$(basename "$unit_path")
    check "$unit bounds its boot-path job (JobTimeoutSec=)" yes \
        "$(grep -q '^JobTimeoutSec=' "$unit_path" && echo yes || echo no)"
    check "$unit does not hard-Require the log-dirs oneshot" yes \
        "$(grep -E '^Requires=' "$unit_path" | grep -q 'segno-log-dirs' && echo no || echo yes)"
done

echo "every file do_install writes is named in FILES"
# The regression in the recipe's own inventory that #810 review caught: two
# /etc paths were installed and never added to FILES:${PN}. The default
# ${sysconfdir} glob still packaged them, so nothing broke — the recipe just
# stopped describing what it owns.
#
# The recipe writes most destinations on the continuation line of a two-line
# install, so the sed joins continuations first: reading the file line by line
# saw 35 of the 46 destinations and skipped every two-line one — which is
# precisely the style a new /etc drop-in would be added in, so the guard would
# have reported green for the very finding it was written to catch.
while read -r dest; do
    [ -n "$dest" ] || continue
    check "FILES names $dest" yes "$(in_files "$dest")"
done <<EOF
$(sed -e :a -e '/\\$/N; s/\\\n//; ta' "$BB" |
    grep -E '^[[:space:]]*install -m [0-7]+ ' |
    grep -oE '\$\{D\}\$\{(sysconfdir|systemd_system_unitdir|bindir)\}[^ ]*' |
    sed 's|\${D}||' | sort -u)
EOF

echo "every enabled unit exists, and every .mount is enabled"
for unit in $(systemd_service_line | sed 's/.*= *"//; s/"$//'); do
    check "$unit exists in files/" yes \
        "$([ -f "$FILES_DIR/$unit" ] && echo yes || echo no)"
done
for unit_path in "$FILES_DIR"/*.mount; do
    unit=$(basename "$unit_path")
    check "$unit is enabled (a shipped-but-disabled mount is invisible)" yes \
        "$(enabled "$unit")"
done

echo "each .mount unit is named for its own Where="
# systemd resolves a mount unit by the escaped form of its mount point and
# nothing else, so a rename of either side produces a unit it will never start
# — and the symptom is the silent RAM fallback the rest of this file is about.
escaped_name() {
    local path=$1
    if command -v systemd-escape > /dev/null 2>&1; then
        systemd-escape --path --suffix=mount -- "$path"
        return
    fi
    # Fallback for hosts without systemd (macOS): only correct while every
    # component is alphanumeric. Anything else has to be escaped \xNN, so say
    # so loudly rather than compare a wrong answer.
    case $path in
        *[!A-Za-z0-9/]*) echo "needs-systemd-escape($path)"; return ;;
    esac
    printf '%s.mount\n' "$(printf '%s' "$path" | sed 's|^/*||; s|/*$||; s|/|-|g')"
}

for unit_path in "$FILES_DIR"/*.mount; do
    unit=$(basename "$unit_path")
    where=$(grep -E '^Where=' "$unit_path" | head -n1 | cut -d= -f2-)
    check "$unit is the escaped form of Where=$where" "$unit" "$(escaped_name "$where")"
done

echo
echo "log-persist: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
echo "ALL PASSED"
