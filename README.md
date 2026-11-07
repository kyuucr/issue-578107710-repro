# Reproducing an Android Wi-Fi standard-detection bug: BSS Membership Selector in Supported Rates

Automated reproduction of an AOSP bug: `ScanResult.getWifiStandard()` returns
`WIFI_STANDARD_UNKNOWN` (0) when an AP puts a BSS Membership Selector, such as
SAE-H2E `0xFB`, inside the **Supported Rates** element (IE 1).

## The bug

In `packages/modules/Wifi`, `InformationElementUtil.SupportedRates.from()` passes
every byte of IE 1 through `getRateFromByte()`. A byte that isn't a legacy rate,
such as a membership selector (value 120 to 127 with bit 7 set), marks the
whole element invalid. `NetworkDetail` then sets the Wi-Fi mode to
`MODE_UNDEFINED` unless `supportedRates.isValid()`, so the HE, VHT and HT
Operation elements are ignored, and the API reports UNKNOWN.

IEEE 802.11 allows selectors in IE 1. hostapd puts them there whenever an AP
advertises fewer than 8 rates. If IE 1 is full, the selector goes into
Extended Supported Rates (IE 50) instead, and then Android parses the AP
correctly.

## What the script does

`run_repro.sh` brings up two APs one after the other on the host's Wi-Fi card
with `hostapd`. Both are on 5 GHz channel 36, 802.11ax, WPA3-SAE with
`sae_pwe=1` (H2E only). The only difference between them is where the `0xFB`
selector ends up:

| AP | Config | IE 1 | IE 50 | Expected | Android 16/17 result |
|---|---|---|---|---|---|
| control | `hostapd_control.conf` | `8C 12 98 24 B0 48 60 6C` | `FB` | 11ax | 11ax |
| trigger | `hostapd_trigger.conf` | `98 24 B0 48 60 6C FB` | (none) | 11ax | **unknown** |

For each AP, the script:

1. starts `hostapd`, waits for `AP-ENABLED`, and triggers a scan on the phone;
2. launches **WifiStdProbe** (`probe/`), a small helper app. It logs each
   matching `ScanResult` as JSON to logcat (`WifiStdProbe: RESULT {...}`) and
   on screen, showing `getWifiStandard()` next to the raw IE 1 and IE 50 bytes
   and which Operation elements are present;
3. works out the expected standard from the Operation elements, as AOSP's
   `determineMode()` does, and compares it with the API value.

While the trigger AP is still on air, the script saves a screenshot and runs
`adb bugreport`. At the end it prints `REPRODUCED` or `NOT REPRODUCED`.

Phone and host settings are put back on exit, including on Ctrl-C:

- `hostapd` is stopped;
- NetworkManager manages the interface again;
- Wi-Fi verbose logging returns to its previous state;
- "stay awake" is turned off.

## Requirements

**Host (Linux)**
- A Wi-Fi card that supports AP mode (`iw list` → "Supported interface modes: AP")
- `hostapd` (tested with v2.11), `iw`, `nmcli` (NetworkManager), `python3`, `sudo`
- `adb`
- Android SDK build tools to build the probe: `build-tools/36.0.0` and
  `platforms/android-36` under `$ANDROID_HOME` (default `~/Android/Sdk`), a
  JDK with `javac` 17 or newer, and `~/.android/debug.keystore` (created by
  Android Studio, or with
  `keytool -genkeypair -keystore ~/.android/debug.keystore -storepass android -alias androiddebugkey -keypass android -keyalg RSA -dname "CN=Android Debug,O=Android,C=US" -validity 10000`)

**Phone**
- USB debugging enabled and the host authorised
- Location turned on (needed for scan results)
- Screen unlocked for the whole run

## Usage

Run it as your normal user, not with `sudo`. The script asks for your sudo
password once, for `nmcli` and `hostapd`.

```bash
./run_repro.sh                    # default Wi-Fi interface wlp1s0
./run_repro.sh -i wlan0           # another interface
./run_repro.sh -s <adb-serial>    # pick a phone when several are attached
./run_repro.sh --no-bugreport     # skip the bug report (about 3 minutes faster)
./run_repro.sh --uninstall-probe  # remove the helper app afterwards
```

The Wi-Fi interface leaves NetworkManager while the test runs, so any Wi-Fi
connection the host has on it drops. Use Ethernet or another interface for
connectivity.

To rebuild the probe app by hand, run `./build_probe.sh`. It builds without
Gradle, using aapt2, javac, d8, zipalign and apksigner.

## Output

Each run writes to `out/<YYYYmmdd-HHMMSS>/` (ignored by git):

| File | Contents |
|---|---|
| `summary.txt` | One verdict line per AP: IEs, expected standard, API value, OK/MISMATCH |
| `device_info.txt` | Build fingerprint, SDK level, security patch, Wi-Fi module version, host driver, hostapd version |
| `probe_<ap>.jsonl` | Raw probe output (one JSON object per scan result) |
| `control_probe.png`, `trigger_probe.png` | Probe screen for each AP |
| `bugreport_trigger.zip` | `adb bugreport` taken while the trigger AP was on air. Search for `WifiStdProbe: RESULT` |
| `hostapd_<ap>.conf`, `hostapd_<ap>.log` | Rendered config and hostapd log |
| `run.log` | Full console log |

Bug reports contain personal data from the phone (accounts, nearby networks,
location history, app list), so only share them privately.

## Notes and limitations

- **5 GHz, not 6 GHz.** The field data that exposed the bug came from 6 GHz
  APs. Most host cards can't transmit on 6 GHz (no-IR), and this setup doesn't
  override regulatory rules. The parsing code doesn't depend on band, so
  5 GHz shows the same failure.
- If the driver refuses 802.11ax in AP mode, set `ieee80211ax=0` in both
  configs. The expected standard then becomes 11ac, and the trigger AP still
  reports unknown.
- Both APs use the same BSSID (same radio), one after the other. The phone may
  keep the older scan entry for a short while. The probe filters by SSID, so
  this doesn't affect the result.

## Results so far

| Date | Device | Build | Result |
|---|---|---|---|
| 2026-11-07 | Pixel 10 Pro (`blazer`), Android 17 / API 37 | `CP3A.261005.005`, Wi-Fi module 372042280, patch 2026-10-05 | Reproduced (3 of 3 runs) |
