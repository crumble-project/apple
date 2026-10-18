#!/bin/sh
# Builds Crumble.app into build/ from the Swift package, signed ad hoc for local use.
set -eu
cd "$(dirname "$0")/.."
configuration="${1:-release}"
swift build -c "$configuration"
app="build/Crumble.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp ".build/$configuration/Crumble" "$app/Contents/MacOS/Crumble"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>Crumble</string>
	<key>CFBundleIdentifier</key><string>dev.crumble.desktop</string>
	<key>CFBundleName</key><string>Crumble</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>0.1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>LSMinimumSystemVersion</key><string>26.0</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSAppTransportSecurity</key>
	<dict><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict>
</plist>
PLIST
codesign --force --sign - "$app"
echo "Built $app"
