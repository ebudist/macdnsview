#!/bin/bash
# Universal release build: ad-hoc signed MacDNSView.app and macdnsview CLI, zipped into dist/
set -euo pipefail
cd "$(dirname "$0")/.."

version=$(sed -n 's/^public let version = "\(.*\)"$/\1/p' Sources/MacDNSViewCore/Version.swift)
[ -n "$version" ] || { echo "no version in Version.swift" >&2; exit 1; }

swift build -c release --arch arm64 --arch x86_64
bin=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)

rm -rf dist
app=dist/MacDNSView.app
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/MacDNSViewApp" "$app/Contents/MacOS/MacDNSView"
cp "$bin/macdnsview" dist/macdnsview

iconset=$(mktemp -d)/AppIcon.iconset
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
    sips -z $size $size assets/AppIcon.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) assets/AppIcon.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"

cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>MacDNSView</string>
    <key>CFBundleIdentifier</key><string>io.github.ebudist.macdnsview</string>
    <key>CFBundleName</key><string>MacDNSView</string>
    <key>CFBundleDisplayName</key><string>MacDNSView</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$version</string>
    <key>CFBundleVersion</key><string>$version</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
EOF

codesign --force --sign - "$app"
codesign --force --sign - dist/macdnsview

ditto -c -k --norsrc --noextattr --keepParent "$app" "dist/MacDNSView-$version.zip"
ditto -c -k --norsrc --noextattr dist/macdnsview "dist/macdnsview-cli-$version.zip"
echo "dist/MacDNSView-$version.zip"
echo "dist/macdnsview-cli-$version.zip"
