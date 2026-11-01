#!/bin/zsh
set -eu
cd "${0:A:h}"
source_hash=$(python3 - <<'HASH'
import hashlib,pathlib
r=pathlib.Path('.');h=hashlib.sha256()
for p in sorted(list((r/'src').rglob('*.java'))+[r/'AndroidManifest.xml',r/'build.sh']):h.update(p.read_bytes())
print(h.hexdigest())
HASH
)
if [[ -f helper.apk && -f .source-sha256 && "$(cat .source-sha256)" == "$source_hash" ]]; then exit 0; fi
sdk="$HOME/Library/Android/sdk"
jdk='/Applications/Android Studio.app/Contents/jbr/Contents/Home'
export JAVA_HOME="$jdk"
mkdir -p classes dex
"$jdk/bin/javac" -Xlint:-options --release 8 -classpath "$sdk/platforms/android-37.0/android.jar" -d classes src/local/drivee/qahelper/FlowInstrumentation.java
"$sdk/build-tools/36.0.0/d8" --lib "$sdk/platforms/android-37.0/android.jar" --min-api 26 --output dex classes/local/drivee/qahelper/*.class
"$sdk/build-tools/36.0.0/aapt2" link -I "$sdk/platforms/android-37.0/android.jar" --manifest AndroidManifest.xml -o unsigned.apk
/usr/bin/python3 - <<'PY'
import zipfile
with zipfile.ZipFile('unsigned.apk','a') as z:z.write('dex/classes.dex','classes.dex')
PY
if [[ ! -f debug.keystore ]]; then
"$jdk/bin/keytool" -genkeypair -keystore debug.keystore -storepass android -keypass android -alias androiddebugkey -dname 'CN=Drivee QA Local Debug' -keyalg RSA -validity 10000 >/dev/null 2>&1
fi
JAVA_HOME="$jdk" "$sdk/build-tools/36.0.0/apksigner" sign --ks debug.keystore --ks-pass pass:android --key-pass pass:android --out helper.apk unsigned.apk

print -r -- "$source_hash" > .source-sha256
