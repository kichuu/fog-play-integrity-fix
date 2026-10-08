#!/usr/bin/env bash
# Build the PPU Hook Xposed module APK -> hook/out/ppuhook.apk
#
# Needs: JDK, Android SDK build-tools (d8, aapt2, zipalign, apksigner) and a platform android.jar.
# Signs with hook/key.jks (gitignored). Keep that key: Android only accepts an update
# signed with the same key as the installed copy. If it's lost, uninstall local.ppuhook first.
set -euo pipefail
cd "$(dirname "$0")"

SDK="${ANDROID_HOME:-}"
[ -d "$SDK/build-tools" ] || SDK="$HOME/Android/Sdk"
BT="${BUILD_TOOLS:-$(ls -d "$SDK"/build-tools/* | sort -V | tail -1)}"
AJ="${ANDROID_JAR:-$(ls -d "$SDK"/platforms/android-*/android.jar | sort -V | tail -1)}"

rm -rf out && mkdir -p out/stubs out/cls out/dex
javac -nowarn --release 11 -cp "$AJ" -d out/stubs $(find stubs -name '*.java')
javac --release 11 -cp "$AJ:out/stubs" -d out/cls src/local/ppuhook/Hook.java
# stubs are compile-only: Vector provides the real Xposed API at runtime
"$BT/d8" --release --min-api 26 --lib "$AJ" --classpath out/stubs --output out/dex $(find out/cls -name '*.class')
"$BT/aapt2" link -I "$AJ" --manifest AndroidManifest.xml -A assets -o out/unsigned.apk
(cd out/dex && zip -q ../unsigned.apk classes.dex)
"$BT/zipalign" -f -p 4 out/unsigned.apk out/aligned.apk

if [ ! -f key.jks ]; then
  echo "No hook/key.jks - generating a new signing key"
  keytool -genkeypair -keystore key.jks -storepass ppuhook -keypass ppuhook -alias ppu \
    -keyalg RSA -keysize 2048 -validity 10000 -dname CN=ppuhook >/dev/null 2>&1
fi
"$BT/apksigner" sign --ks key.jks --ks-pass pass:ppuhook --out out/ppuhook.apk out/aligned.apk
"$BT/apksigner" verify out/ppuhook.apk
echo "Built $(pwd)/out/ppuhook.apk"
