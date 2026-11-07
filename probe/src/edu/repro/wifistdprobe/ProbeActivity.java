package edu.repro.wifistdprobe;

import android.app.Activity;
import android.graphics.Typeface;
import android.net.wifi.ScanResult;
import android.net.wifi.WifiManager;
import android.os.Bundle;
import android.util.Log;
import android.widget.ScrollView;
import android.widget.TextView;

import org.json.JSONException;
import org.json.JSONObject;

import java.nio.ByteBuffer;
import java.util.List;

/**
 * Dumps ScanResult.getWifiStandard() next to the raw Supported Rates (IE 1) and
 * Extended Supported Rates (IE 50) bytes and the Operation elements that AOSP's
 * WifiMode.determineMode() uses. Output goes to logcat (tag WifiStdProbe, one
 * "RESULT {json}" line per scan result) and to the screen for a screenshot.
 *
 * Launch: am start -S -W -n edu.repro.wifistdprobe/.ProbeActivity --es ssid_prefix <prefix> --es run_id <id>
 */
public class ProbeActivity extends Activity {
    private static final String TAG = "WifiStdProbe";

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        String prefix = getIntent().getStringExtra("ssid_prefix");
        String runId = getIntent().getStringExtra("run_id");

        StringBuilder screen = new StringBuilder();
        screen.append(android.os.Build.FINGERPRINT).append("\n");
        screen.append("WifiStdProbe  run=").append(runId)
                .append("  filter=").append(prefix == null ? "<all>" : prefix).append("\n\n");

        List<ScanResult> results;
        try {
            results = getSystemService(WifiManager.class).getScanResults();
        } catch (SecurityException e) {
            Log.e(TAG, "ERROR " + e);
            screen.append("ERROR: ").append(e);
            show(screen.toString());
            return;
        }

        int shown = 0;
        for (ScanResult r : results) {
            String ssid = r.SSID == null ? "" : r.SSID;
            if (prefix != null && !ssid.startsWith(prefix)) {
                continue;
            }
            String ie1 = null, ie50 = null;
            boolean htOp = false, vhtOp = false, heCap = false, heOp = false, ehtOp = false;
            for (ScanResult.InformationElement ie : r.getInformationElements()) {
                ByteBuffer bb = ie.getBytes().duplicate();
                byte[] b = new byte[bb.remaining()];
                bb.get(b);
                int id = ie.getId();
                int ext = ie.getIdExt();
                if (id == 1) ie1 = hex(b);
                else if (id == 50) ie50 = hex(b);
                else if (id == 61) htOp = true;
                else if (id == 192) vhtOp = true;
                else if (id == 255 && ext == 35) heCap = true;
                else if (id == 255 && ext == 36) heOp = true;
                else if (id == 255 && ext == 106) ehtOp = true;
            }
            int std = r.getWifiStandard();
            long ageMs = android.os.SystemClock.elapsedRealtime() - r.timestamp / 1000;
            try {
                JSONObject o = new JSONObject()
                        .put("run_id", runId)
                        .put("ssid", ssid)
                        .put("bssid", r.BSSID)
                        .put("freq", r.frequency)
                        .put("rssi", r.level)
                        .put("age_ms", ageMs)
                        .put("wifi_standard_int", std)
                        .put("wifi_standard", stdName(std))
                        .put("ie1", ie1 == null ? JSONObject.NULL : ie1)
                        .put("ie50", ie50 == null ? JSONObject.NULL : ie50)
                        .put("ht_op", htOp)
                        .put("vht_op", vhtOp)
                        .put("he_cap", heCap)
                        .put("he_op", heOp)
                        .put("eht_op", ehtOp)
                        .put("capabilities", r.capabilities);
                Log.i(TAG, "RESULT " + o);
            } catch (JSONException e) {
                Log.e(TAG, "ERROR " + e);
            }
            screen.append(ssid).append("  ").append(r.BSSID).append("  ").append(r.frequency).append(" MHz\n")
                    .append("  getWifiStandard() = ").append(std).append(" (").append(stdName(std)).append(")\n")
                    .append("  IE 1  = ").append(ie1).append("\n")
                    .append("  IE 50 = ").append(ie50).append("\n")
                    .append("  HT op=").append(htOp).append(" VHT op=").append(vhtOp)
                    .append(" HE op=").append(heOp).append(" EHT op=").append(ehtOp).append("\n\n");
            shown++;
        }
        Log.i(TAG, "DONE run_id=" + runId + " total=" + results.size() + " matched=" + shown);
        screen.append("matched ").append(shown).append(" of ").append(results.size()).append(" scan results");
        show(screen.toString());
    }

    private void show(String text) {
        TextView tv = new TextView(this);
        tv.setTypeface(Typeface.MONOSPACE);
        tv.setTextSize(13);
        tv.setText(text);
        ScrollView sv = new ScrollView(this);
        // targetSdk 35+ is edge-to-edge: pad by the system bar insets so nothing hides under them
        sv.setOnApplyWindowInsetsListener((v, insets) -> {
            android.graphics.Insets bars = insets.getInsets(
                    android.view.WindowInsets.Type.systemBars() | android.view.WindowInsets.Type.displayCutout());
            tv.setPadding(32 + bars.left, 32 + bars.top, 32 + bars.right, 32 + bars.bottom);
            return insets;
        });
        sv.addView(tv);
        setContentView(sv);
    }

    private static String hex(byte[] b) {
        StringBuilder sb = new StringBuilder();
        for (byte x : b) sb.append(String.format("%02X", x & 0xFF));
        return sb.toString();
    }

    private static String stdName(int s) {
        switch (s) {
            case ScanResult.WIFI_STANDARD_LEGACY: return "legacy";
            case ScanResult.WIFI_STANDARD_11N: return "11n";
            case ScanResult.WIFI_STANDARD_11AC: return "11ac";
            case ScanResult.WIFI_STANDARD_11AX: return "11ax";
            case ScanResult.WIFI_STANDARD_11AD: return "11ad";
            case ScanResult.WIFI_STANDARD_11BE: return "11be";
            case ScanResult.WIFI_STANDARD_UNKNOWN: return "unknown";
            default: return "other(" + s + ")";
        }
    }
}
