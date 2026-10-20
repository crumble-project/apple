#!/bin/sh
# Builds Crumble.app from the Swift package.
#
# The default is an ad hoc local build. Set CRUMBLE_SIGNING_IDENTITY alone to
# sign with the hardened runtime and a timestamp, as notarization requires.
# Set CRUMBLE_VARIANT=dev to build Crumble Dev.app, which has its own bundle ID
# and so its own Keychain items and settings.
# CRUMBLE_VERSION and CRUMBLE_BUILD_NUMBER set the app's version.
set -eu
cd "$(dirname "$0")/.."
configuration="${1:-release}"
output_root="${CRUMBLE_APP_OUTPUT:-build}"
case "${CRUMBLE_VARIANT:-production}" in
	production) bundle_id="ng.crumbli.mac"; app_name="Crumble" ;;
	dev) bundle_id="ng.crumbli.mac.dev"; app_name="Crumble Dev" ;;
	*) echo "CRUMBLE_VARIANT must be production or dev." >&2; exit 2 ;;
esac
app="$output_root/$app_name.app"
signing_identity="${CRUMBLE_SIGNING_IDENTITY:-}"
version="${CRUMBLE_VERSION:-0.1.0}"
build_number="${CRUMBLE_BUILD_NUMBER:-1}"

if [ -n "$signing_identity" ] && ! security find-identity -v -p codesigning | grep -F "$signing_identity" >/dev/null; then
	echo "Signing identity is not available in the keychain: $signing_identity" >&2
	exit 2
fi

swift build -c "$configuration" --product Crumble
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp ".build/$configuration/Crumble" "$app/Contents/MacOS/Crumble"
# The icon set macOS expects, scaled from the 1024-pixel source.
iconset="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
	sips -z "$size" "$size" resources/icon.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
	sips -z "$((size * 2))" "$((size * 2))" resources/icon.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>Crumble</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundleIdentifier</key><string>$bundle_id</string>
	<key>CFBundleName</key><string>$app_name</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$version</string>
	<key>CFBundleVersion</key><string>$build_number</string>
	<key>LSMinimumSystemVersion</key><string>26.0</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSAppTransportSecurity</key>
	<dict><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict>
</plist>
PLIST
if [ -n "$signing_identity" ]; then
	codesign --force --sign "$signing_identity" --timestamp --options runtime "$app"
else
	codesign --force --sign - "$app"
fi
echo "Built $app"
