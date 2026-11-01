#!/bin/zsh
set -eu
cd "${0:A:h}"
app_dir="$PWD/Жмякее.app"
if [[ ! -d "$app_dir" ]]; then
    for previous_name in "Дрыц-тыц Помогатор.app" "Drivee QA Desk.app"; do
        if [[ -d "$PWD/$previous_name" ]]; then
            mv "$PWD/$previous_name" "$app_dir"
            break
        fi
    done
fi
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
zsh "$PWD/Assets/build-icon.sh"
cp "$PWD/Assets/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"
cp "$PWD/Assets/BrandLogo.png" "$app_dir/Contents/Resources/BrandLogo.png"
cp "$PWD/BuildInspector.py" "$app_dir/Contents/Resources/BuildInspector.py"
cp "$PWD/Assets/BrandMark.png" "$app_dir/Contents/Resources/BrandMark.png"
cp "$PWD/tools/scrcpy/scrcpy-server" "$app_dir/Contents/Resources/scrcpy-server"
zsh "$PWD/AndroidAutomation/build.sh"
cp "$PWD/AndroidAutomation/helper.apk" "$app_dir/Contents/Resources/qa-helper.apk"
cp "$PWD/tools/scrcpy/LICENSE" "$app_dir/Contents/Resources/LICENSE"
swiftc -swift-version 5 -parse-as-library -O -target arm64-apple-macosx14.0 Controller.swift Environments.swift AccountCatalog.swift CourierDeepLink.swift DeepLinkControls.swift BuildModels.swift BuildLibrary.swift BuildsView.swift AndroidWire.swift EmbeddedAndroid.swift AccountAutomation.swift IOSAccountAction.swift MediaCapture.swift ScreenshotEditor.swift -o "$app_dir/Contents/MacOS/DriveeQADesk"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.drivee.qadesk</string>
<key>CFBundleName</key><string>Жмякее</string>
<key>CFBundleDisplayName</key><string>Жмякее</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
<key>CFBundleExecutable</key><string>DriveeQADesk</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.9.0</string>
<key>CFBundleVersion</key><string>11</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
python3 "$PWD/sign-local.py" "$app_dir"
echo "Собрано: $app_dir"
