#!/usr/bin/env bash
# Build the WifiStdProbe helper APK without Gradle (aapt2 + javac + d8 + apksigner).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SDK="${ANDROID_HOME:-$HOME/Android/Sdk}"
BT="$SDK/build-tools/36.0.0"
JAR="$SDK/platforms/android-36/android.jar"
KS="$HOME/.android/debug.keystore"
OUT="$HERE/probe/build"

rm -rf "$OUT" && mkdir -p "$OUT/classes" "$OUT/dex"

"$BT/aapt2" link -o "$OUT/unaligned.apk" -I "$JAR" --manifest "$HERE/probe/AndroidManifest.xml"
javac --release 17 -nowarn -cp "$JAR" -d "$OUT/classes" \
    $(find "$HERE/probe/src" -name '*.java')
"$BT/d8" --min-api 30 --lib "$JAR" --output "$OUT/dex" $(find "$OUT/classes" -name '*.class')
(cd "$OUT/dex" && zip -q -j "$OUT/unaligned.apk" classes.dex)
"$BT/zipalign" -f 4 "$OUT/unaligned.apk" "$OUT/aligned.apk"
"$BT/apksigner" sign --ks "$KS" --ks-pass pass:android --ks-key-alias androiddebugkey \
    --out "$HERE/WifiStdProbe.apk" "$OUT/aligned.apk"
echo "Built $HERE/WifiStdProbe.apk"
