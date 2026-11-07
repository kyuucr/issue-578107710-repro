#!/usr/bin/env bash
# Reproduce AOSP bug: ScanResult.getWifiStandard() == UNKNOWN when a BSS Membership
# Selector (SAE-H2E 0xFB) is inside the Supported Rates element (IE 1).
#
# Runs two APs one after the other on this host and scans them from an adb-connected phone:
#   control: 0xFB in IE 50 -> expected 11ax
#   trigger: 0xFB in IE 1  -> bug gives unknown (should be 11ax)
# While the trigger AP is still up it captures a screenshot and an Android bug report.
#
# Run as your normal user (NOT with sudo): adb must use your authorised keys.
# You will be asked for your sudo password once (NetworkManager + hostapd).
#
# Usage: ./run_repro.sh [-i IFACE] [-s ADB_SERIAL] [--no-bugreport] [--uninstall-probe]
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
IFACE="wlp1s0"
SERIAL=""
DO_BUGREPORT=1
UNINSTALL_PROBE=0
while [ $# -gt 0 ]; do
    case "$1" in
        -i) IFACE="$2"; shift 2 ;;
        -s) SERIAL="$2"; shift 2 ;;
        --no-bugreport) DO_BUGREPORT=0; shift ;;
        --uninstall-probe) UNINSTALL_PROBE=1; shift ;;
        *) echo "unknown option: $1"; exit 2 ;;
    esac
done

PKG="edu.repro.wifistdprobe"
CTRL="/run/hostapd-repro"
OUT="$HERE/out/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
exec > >(tee -a "$OUT/run.log") 2>&1

ADB=(adb)
[ -n "$SERIAL" ] && ADB=(adb -s "$SERIAL")

log() { printf '\n[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { log "ERROR: $*"; exit 1; }

if [ "$(id -u)" -eq 0 ]; then
    die "run as your normal user, not root (adb authorisation lives in your user's ~/.android)"
fi

# ---------- preflight ----------
log "Preflight"
for t in adb hostapd nmcli iw python3; do command -v "$t" >/dev/null || die "missing tool: $t"; done
iw dev "$IFACE" info >/dev/null 2>&1 || die "interface $IFACE not found"
[ "$("${ADB[@]}" get-state 2>/dev/null)" = "device" ] || die "no adb device (use -s SERIAL if several are attached)"
[ "$("${ADB[@]}" shell cmd location is-location-enabled | tr -d '\r')" = "true" ] || die "turn on Location on the phone"
"${ADB[@]}" shell input keyevent KEYCODE_WAKEUP
if "${ADB[@]}" shell dumpsys window | grep -q "isKeyguardShowing=true"; then
    die "unlock the phone and keep the screen on, then re-run"
fi
"${ADB[@]}" shell svc power stayon usb >/dev/null 2>&1 || true

DEFROUTE_DEV="$(ip route show default | awk 'NR==1{print $5}')"
if [ "$DEFROUTE_DEV" = "$IFACE" ]; then
    log "WARNING: $IFACE carries this host's primary default route; you will lose that connection during the test."
fi

log "Device info"
{
    echo "fingerprint:      $("${ADB[@]}" shell getprop ro.build.fingerprint | tr -d '\r')"
    echo "sdk:              $("${ADB[@]}" shell getprop ro.build.version.sdk | tr -d '\r')"
    echo "security_patch:   $("${ADB[@]}" shell getprop ro.build.version.security_patch | tr -d '\r')"
    echo "wifi_module:      $("${ADB[@]}" shell pm list packages --apex-only --show-versioncode | grep -i wifi | tr -d '\r' | tr '\n' ' ')"
    echo "host_driver:      $(basename "$(readlink -f /sys/class/net/$IFACE/device/driver)")"
    echo "hostapd:          $(hostapd -v 2>&1 | head -1)"
} | tee "$OUT/device_info.txt"

# ---------- probe app ----------
if [ ! -f "$HERE/WifiStdProbe.apk" ]; then
    log "Building probe APK"
    "$HERE/build_probe.sh" || die "probe build failed"
fi
log "Installing probe app"
"${ADB[@]}" install -r "$HERE/WifiStdProbe.apk" >/dev/null || die "install failed"
"${ADB[@]}" shell pm grant "$PKG" android.permission.ACCESS_FINE_LOCATION
"${ADB[@]}" shell pm grant "$PKG" android.permission.ACCESS_COARSE_LOCATION

# ---------- root setup + cleanup ----------
log "Requesting sudo (NetworkManager + hostapd)"
sudo -v || die "sudo failed"
( while true; do sudo -n true; sleep 50; kill -0 "$$" 2>/dev/null || exit; done ) 2>/dev/null &
SUDO_KEEPALIVE=$!

VERBOSE_BEFORE="$("${ADB[@]}" shell cmd wifi is-verbose-logging | tr -d '\r')"
NM_MANAGED_BEFORE="$(nmcli -g GENERAL.STATE device show "$IFACE" 2>/dev/null | grep -qi unmanaged && echo no || echo yes)"
HOSTAPD_PID=""

stop_ap() {
    if [ -n "$HOSTAPD_PID" ]; then
        sudo kill "$HOSTAPD_PID" 2>/dev/null
        for _ in $(seq 20); do sudo kill -0 "$HOSTAPD_PID" 2>/dev/null || break; sleep 0.5; done
        HOSTAPD_PID=""
    fi
}

cleanup() {
    log "Cleanup"
    stop_ap
    if [ "$NM_MANAGED_BEFORE" = "yes" ]; then
        sudo nmcli device set "$IFACE" managed yes && echo "NetworkManager manages $IFACE again"
    fi
    if [ "$VERBOSE_BEFORE" = "disabled" ]; then
        "${ADB[@]}" shell cmd wifi set-verbose-logging disabled >/dev/null 2>&1 && echo "phone Wi-Fi verbose logging restored to disabled"
    fi
    "${ADB[@]}" shell svc power stayon false >/dev/null 2>&1 || true
    if [ "$UNINSTALL_PROBE" -eq 1 ]; then
        "${ADB[@]}" uninstall "$PKG" >/dev/null 2>&1 && echo "probe app uninstalled"
    fi
    kill "$SUDO_KEEPALIVE" 2>/dev/null
    echo "Output: $OUT"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

log "Enabling Wi-Fi verbose logging on the phone"
"${ADB[@]}" shell cmd wifi set-verbose-logging enabled

log "Releasing $IFACE from NetworkManager"
sudo nmcli device set "$IFACE" managed no || die "could not unmanage $IFACE"
sleep 3

# ---------- helpers ----------
start_ap() {  # $1 name, $2 template
    local name="$1" conf="$OUT/hostapd_$1.conf" hlog="$OUT/hostapd_$1.log"
    sed -e "s|@IFACE@|$IFACE|g" -e "s|@CTRL@|$CTRL|g" "$2" > "$conf"
    log "Starting AP '$name' ($(grep '^ssid=' "$conf" | cut -d= -f2))"
    sudo hostapd -B -P "$OUT/hostapd_$name.pid" -f "$hlog" "$conf" \
        || { sudo cat "$hlog" 2>/dev/null | tail -20; die "hostapd failed to start ($name)"; }
    HOSTAPD_PID="$(sudo cat "$OUT/hostapd_$name.pid")"
    for _ in $(seq 30); do
        sudo grep -q "AP-ENABLED" "$hlog" 2>/dev/null && { echo "AP-ENABLED"; return 0; }
        sudo grep -q -E "AP-DISABLED|Could not|Failed" "$hlog" 2>/dev/null && break
        sleep 1
    done
    sudo tail -20 "$hlog"
    die "AP '$name' did not come up"
}

probe() {  # $1 name, $2 ssid -> writes $OUT/probe_$1.jsonl
    local name="$1" ssid="$2" out="$OUT/probe_$1.jsonl"
    : > "$out"
    for attempt in $(seq 8); do
        "${ADB[@]}" shell cmd wifi start-scan
        sleep 7
        "${ADB[@]}" logcat -c
        "${ADB[@]}" shell am start -S -W -n "$PKG/.ProbeActivity" \
            --es ssid_prefix "$ssid" --es run_id "$name" >/dev/null
        sleep 2
        "${ADB[@]}" logcat -d -s WifiStdProbe:I | sed -n 's/.*RESULT //p' > "$out"
        if [ -s "$out" ]; then
            echo "found '$ssid' on attempt $attempt"
            return 0
        fi
        echo "attempt $attempt: '$ssid' not in scan results yet"
    done
    return 1
}

screenshot() {  # $1 output png; retries if the capture comes back blank/black
    for _ in 1 2 3 4 5; do
        "${ADB[@]}" shell input keyevent KEYCODE_WAKEUP
        sleep 1.5
        "${ADB[@]}" exec-out screencap -p > "$1"
        [ "$(stat -c %s "$1")" -gt 30000 ] && return 0
        echo "screenshot looked blank, retrying"
    done
    log "WARNING: screenshot $1 may be blank"
}

verdict() {  # $1 name
    python3 - "$OUT/probe_$1.jsonl" "$1" <<'EOF' | tee -a "$OUT/summary.txt"
import json, sys
path, name = sys.argv[1], sys.argv[2]
rows = [json.loads(l) for l in open(path) if l.strip()]
for r in rows:
    f = r["freq"]
    if r["eht_op"]: exp = "11be"
    elif r["he_op"]: exp = "11ax"
    elif r["vht_op"] and not (2400 <= f < 2500): exp = "11ac"
    elif r["ht_op"]: exp = "11n"
    else: exp = "legacy"
    ie1 = r["ie1"] or ""
    sel_ie1 = any((int(ie1[i:i+2], 16) & 0x80) and (int(ie1[i:i+2], 16) & 0x7F) >= 120
                  for i in range(0, len(ie1), 2))
    ok = r["wifi_standard"] == exp
    print(f"[{name}] {r['ssid']} {r['bssid']} {f} MHz  IE1={ie1} IE50={r['ie50']}  "
          f"selector_in_IE1={sel_ie1}  expected={exp}  getWifiStandard()={r['wifi_standard']} "
          f"({r['wifi_standard_int']})  -> {'OK' if ok else 'MISMATCH'}")
EOF
}

# ---------- control ----------
start_ap control "$HERE/hostapd_control.conf"
probe control repro-h2e-ie50 || log "WARNING: control AP not seen by the phone"
[ -s "$OUT/probe_control.jsonl" ] && verdict control
screenshot "$OUT/control_probe.png"
stop_ap
sleep 3

# ---------- trigger ----------
start_ap trigger "$HERE/hostapd_trigger.conf"
probe trigger repro-h2e-ie1 || die "trigger AP not seen by the phone"
verdict trigger
screenshot "$OUT/trigger_probe.png"
log "Screenshot saved: $OUT/trigger_probe.png"

if [ "$DO_BUGREPORT" -eq 1 ]; then
    log "Capturing Android bug report with the trigger AP still on air (takes a few minutes)"
    "${ADB[@]}" bugreport "$OUT/bugreport_trigger.zip" || log "WARNING: bugreport failed"
fi

log "Summary"
cat "$OUT/device_info.txt" "$OUT/summary.txt"
if grep -q "\[trigger\].*selector_in_IE1=True.*getWifiStandard()=unknown" "$OUT/summary.txt"; then
    log "REPRODUCED: selector in IE 1 -> getWifiStandard() = unknown"
else
    log "NOT REPRODUCED (see summary above)"
fi
