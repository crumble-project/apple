#!/bin/sh
# Builds Crumble.app from the Swift package.
#
# The default is an ad hoc local build. Set CRUMBLE_SIGNING_IDENTITY alone to
# sign with the hardened runtime and a timestamp, as notarization requires. Add
# CRUMBLE_PROVISIONING_PROFILE and CRUMBLE_PUSH_ENVIRONMENT to make a
# provisioned APNs build. Set CRUMBLE_VARIANT=dev to build Crumble Dev.app,
# which has its own bundle ID and so its own Keychain items and settings.
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
provisioning_profile="${CRUMBLE_PROVISIONING_PROFILE:-}"
push_environment="${CRUMBLE_PUSH_ENVIRONMENT:-}"
version="${CRUMBLE_VERSION:-0.1.0}"
build_number="${CRUMBLE_BUILD_NUMBER:-1}"

if [ -n "$signing_identity" ] && ! security find-identity -v -p codesigning | grep -F "$signing_identity" >/dev/null; then
	echo "Signing identity is not available in the keychain: $signing_identity" >&2
	exit 2
fi

if [ -n "$provisioning_profile" ] || [ -n "$push_environment" ]; then
	if [ -z "$signing_identity" ] || [ -z "$provisioning_profile" ] || [ -z "$push_environment" ]; then
		echo "Push signing requires CRUMBLE_SIGNING_IDENTITY, CRUMBLE_PROVISIONING_PROFILE, and CRUMBLE_PUSH_ENVIRONMENT." >&2
		exit 2
	fi
	case "$push_environment" in
		development|production) ;;
		*) echo "CRUMBLE_PUSH_ENVIRONMENT must be development or production." >&2; exit 2 ;;
	esac
	if [ ! -f "$provisioning_profile" ]; then
		echo "Provisioning profile not found: $provisioning_profile" >&2
		exit 2
	fi
	if ! security cms -D -i "$provisioning_profile" -o /dev/null 2>/dev/null; then
		echo "The provisioning profile is not a readable Apple profile: $provisioning_profile" >&2
		exit 2
	fi
	profile_plist="$(mktemp)"
	trap 'rm -f "$profile_plist"' EXIT HUP INT TERM
	security cms -D -i "$provisioning_profile" -o "$profile_plist"
	profile_application_id="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$profile_plist" 2>/dev/null || true)"
	if [ -z "$profile_application_id" ]; then
		profile_application_id="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$profile_plist" 2>/dev/null || true)"
	fi
	profile_team_identifier="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.team-identifier' "$profile_plist" 2>/dev/null || true)"
	profile_aps_environment="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.aps-environment' "$profile_plist" 2>/dev/null || true)"
	case "$profile_application_id" in
		*."$bundle_id") ;;
		*) echo "Provisioning profile application ID must end in .$bundle_id (found: ${profile_application_id:-missing})." >&2; exit 2 ;;
	esac
	if [ "$profile_aps_environment" != "$push_environment" ]; then
		echo "Provisioning profile APNs environment must be $push_environment (found: ${profile_aps_environment:-missing})." >&2
		exit 2
	fi
	if [ -z "$profile_team_identifier" ]; then
		echo "Provisioning profile is missing com.apple.developer.team-identifier." >&2
		exit 2
	fi
	case "$signing_identity" in
		*"($profile_team_identifier)") ;;
		*) echo "Signing identity team does not match provisioning profile team $profile_team_identifier." >&2; exit 2 ;;
	esac
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
	<key>CrumblePushEnvironment</key><string>${push_environment:-disabled}</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSAppTransportSecurity</key>
	<dict><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict>
</plist>
PLIST
if [ -n "$provisioning_profile" ]; then
	cp "$provisioning_profile" "$app/Contents/embedded.provisionprofile"
	entitlements="$(mktemp)"
	trap 'rm -f "$entitlements" "$profile_plist"' EXIT HUP INT TERM
	sed -e "s/__APPLICATION_IDENTIFIER__/$profile_application_id/g" \
		-e "s/__TEAM_IDENTIFIER__/$profile_team_identifier/g" \
		-e "s/__APNS_ENVIRONMENT__/$push_environment/g" \
		resources/CrumblePush.entitlements > "$entitlements"
	if [ "$push_environment" = "production" ]; then
		codesign --force --sign "$signing_identity" --timestamp --options runtime --entitlements "$entitlements" "$app"
	else
		codesign --force --sign "$signing_identity" --entitlements "$entitlements" "$app"
	fi
elif [ -n "$signing_identity" ]; then
	codesign --force --sign "$signing_identity" --timestamp --options runtime "$app"
else
	codesign --force --sign - "$app"
fi
echo "Built $app"
