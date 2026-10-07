#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
helper="$root/tools/x1407qa-wait-fastrpc-stable"
cycle_helper="$root/tools/x1407qa-cycle-remoteproc-once"
audiopd_unit="$root/systemd/adsprpcd_audiopd.service"
cdsp_dropin="$root/systemd/cdsprpcd.service.d/10-x1407qa-stability.conf"
cdsp_prepare_unit="$root/systemd/x1407qa-cdsp-prepare.service"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

[[ -x $helper ]] || fail "FastRPC stability helper is missing or not executable"
[[ -x $cycle_helper ]] || fail "CDSP one-shot remoteproc cycle helper is missing or not executable"
[[ -f $audiopd_unit ]] || fail "corrected audiopd unit is missing"
[[ -f $cdsp_dropin ]] || fail "cdsprpcd stability drop-in is missing"
[[ -f $cdsp_prepare_unit ]] || fail "CDSP preparation unit is missing"

touch "$tmp/fastrpc-cdsp"
printf '15.00 100.00\n' > "$tmp/uptime"

cat > "$tmp/udevadm" <<'EOF'
#!/usr/bin/env bash
printf 'USEC_INITIALIZED=10000000\n'
EOF
cat > "$tmp/sleep" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$X1407QA_SLEEP_LOG"
EOF
chmod +x "$tmp/udevadm" "$tmp/sleep"

X1407QA_UPTIME_FILE="$tmp/uptime" \
X1407QA_UDEVADM="$tmp/udevadm" \
X1407QA_SLEEP="$tmp/sleep" \
X1407QA_SLEEP_LOG="$tmp/sleeps" \
    "$helper" "$tmp/fastrpc-cdsp" 10

[[ $(<"$tmp/sleeps") == 5.000000 ]] ||
    fail "helper did not wait only for the remaining stability interval"

printf '25.00 100.00\n' > "$tmp/uptime"
: > "$tmp/sleeps"
X1407QA_UPTIME_FILE="$tmp/uptime" \
X1407QA_UDEVADM="$tmp/udevadm" \
X1407QA_SLEEP="$tmp/sleep" \
X1407QA_SLEEP_LOG="$tmp/sleeps" \
    "$helper" "$tmp/fastrpc-cdsp" 10
[[ ! -s $tmp/sleeps ]] || fail "helper slept after the device was already stable"

mkdir -p "$tmp/sys/class/remoteproc/remoteproc7" "$tmp/run"
printf 'cdsp\n' > "$tmp/sys/class/remoteproc/remoteproc7/name"
printf 'running\n' > "$tmp/sys/class/remoteproc/remoteproc7/state"
touch "$tmp/cycle-device"
cat > "$tmp/remote-state-control" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state_file=$1
action=$2
printf '%s\n' "$action" >> "$X1407QA_CONTROL_LOG"
case $action in
    stop)
        printf 'offline\n' > "$state_file"
        rm -f "$X1407QA_CYCLE_DEVICE"
        ;;
    start)
        [[ ${X1407QA_FAIL_START:-0} != 1 ]] || exit 1
        printf 'running\n' > "$state_file"
        touch "$X1407QA_CYCLE_DEVICE"
        ;;
    *) exit 2 ;;
esac
EOF
chmod +x "$tmp/remote-state-control"

for invocation in 1 2; do
    X1407QA_REMOTEPROC_ROOT="$tmp/sys/class/remoteproc" \
    X1407QA_RUN_DIR="$tmp/run" \
    X1407QA_REMOTE_STATE_CONTROL="$tmp/remote-state-control" \
    X1407QA_CONTROL_LOG="$tmp/control-log" \
    X1407QA_CYCLE_DEVICE="$tmp/cycle-device" \
        "$cycle_helper" cdsp "$tmp/cycle-device"
done

[[ $(cat "$tmp/control-log") == $'stop\nstart' ]] ||
    fail "remoteproc helper did not perform exactly one clean stop/start cycle"
[[ $(<"$tmp/sys/class/remoteproc/remoteproc7/state") == running ]] ||
    fail "remoteproc helper did not leave CDSP running"
[[ -e $tmp/cycle-device ]] || fail "remoteproc helper returned before FastRPC reappeared"

# A failed first attempt must still consume the per-boot cycle allowance. This
# prevents systemd retries from repeatedly resetting the same remote processor.
rm -rf "$tmp/run" "$tmp/control-log" "$tmp/cycle-device"
mkdir -p "$tmp/run"
printf 'running\n' > "$tmp/sys/class/remoteproc/remoteproc7/state"
export X1407QA_FAIL_START=1
if X1407QA_REMOTEPROC_ROOT="$tmp/sys/class/remoteproc" \
    X1407QA_RUN_DIR="$tmp/run" \
    X1407QA_REMOTE_STATE_CONTROL="$tmp/remote-state-control" \
    X1407QA_CONTROL_LOG="$tmp/control-log" \
    X1407QA_CYCLE_DEVICE="$tmp/cycle-device" \
        "$cycle_helper" cdsp "$tmp/cycle-device"; then
    fail "remoteproc helper unexpectedly succeeded when start failed"
fi
unset X1407QA_FAIL_START
first_attempt_log=$(<"$tmp/control-log")
if X1407QA_REMOTEPROC_ROOT="$tmp/sys/class/remoteproc" \
    X1407QA_RUN_DIR="$tmp/run" \
    X1407QA_REMOTE_STATE_CONTROL="$tmp/remote-state-control" \
    X1407QA_CONTROL_LOG="$tmp/control-log" \
    X1407QA_CYCLE_DEVICE="$tmp/cycle-device" \
        "$cycle_helper" cdsp "$tmp/cycle-device"; then
    fail "remoteproc helper unexpectedly hid the failed first attempt"
fi
[[ $(<"$tmp/control-log") == "$first_attempt_log" ]] ||
    fail "remoteproc helper cycled CDSP again after a failed first attempt"
[[ -d $tmp/run/remoteproc-cycle-cdsp.attempted ]] ||
    fail "remoteproc helper did not atomically record the first attempt"
[[ ! -e $tmp/run/remoteproc-cycled-cdsp ]] ||
    fail "remoteproc helper recorded success after a failed cycle"

grep -qxF 'ExecStart=/usr/local/sbin/adsprpcd audiopd adsp' "$audiopd_unit" ||
    fail "audiopd unit does not pass the explicit ADSP domain"
grep -qxF 'Requires=x1407qa-cdsp-prepare.service' "$cdsp_dropin" ||
    fail "cdsprpcd drop-in does not require the separate preparation unit"
grep -qxF 'After=x1407qa-cdsp-prepare.service' "$cdsp_dropin" ||
    fail "cdsprpcd drop-in is not ordered after the preparation unit"
! grep -q '^ExecStartPre=' "$cdsp_dropin" ||
    fail "cdsprpcd drop-in still couples preparation to daemon restart policy"
grep -qxF 'Type=oneshot' "$cdsp_prepare_unit" ||
    fail "CDSP preparation unit is not oneshot"
grep -qxF 'RemainAfterExit=yes' "$cdsp_prepare_unit" ||
    fail "CDSP preparation state is not retained by systemd"
grep -qxF 'Before=cdsprpcd.service' "$cdsp_prepare_unit" ||
    fail "CDSP preparation unit is not ordered before cdsprpcd"
grep -qxF 'ExecStart=/usr/local/libexec/x1407qa-cycle-remoteproc-once cdsp /dev/fastrpc-cdsp' "$cdsp_prepare_unit" ||
    fail "CDSP preparation unit does not perform the one-shot cycle"
grep -qxF 'ExecStart=/usr/local/libexec/x1407qa-wait-fastrpc-stable /dev/fastrpc-cdsp 10' "$cdsp_prepare_unit" ||
    fail "CDSP preparation unit does not enforce the stability gate"
! grep -q '^Restart=' "$cdsp_prepare_unit" ||
    fail "CDSP preparation unit must not restart after failure"

mkdir -p "$tmp/root/etc/systemd/system/cdsprpcd.service.d" \
    "$tmp/root/usr/local/libexec" "$tmp/root/usr/local/sbin"
cp "$helper" "$tmp/root/usr/local/libexec/x1407qa-wait-fastrpc-stable"
cp "$cycle_helper" "$tmp/root/usr/local/libexec/x1407qa-cycle-remoteproc-once"
cp "$audiopd_unit" "$tmp/root/etc/systemd/system/adsprpcd_audiopd.service"
cp "$cdsp_dropin" "$tmp/root/etc/systemd/system/cdsprpcd.service.d/10-x1407qa-stability.conf"
cp "$cdsp_prepare_unit" "$tmp/root/etc/systemd/system/x1407qa-cdsp-prepare.service"
cp /bin/true "$tmp/root/usr/local/sbin/adsprpcd"
cp /bin/true "$tmp/root/usr/local/sbin/cdsprpcd"
for target in sysinit.target basic.target shutdown.target; do
    printf '[Unit]\nDescription=Test target\n' > "$tmp/root/etc/systemd/system/$target"
done
cat > "$tmp/root/etc/systemd/system/cdsprpcd.service" <<'EOF'
[Unit]
Description=FastRPC CDSP daemon
[Service]
Type=simple
ExecStart=/usr/local/sbin/cdsprpcd
EOF
systemd-analyze --root="$tmp/root" verify \
    adsprpcd_audiopd.service x1407qa-cdsp-prepare.service cdsprpcd.service

echo 'PASS: FastRPC boot services clean-cycle and stabilize CDSP, then select ADSP explicitly'
