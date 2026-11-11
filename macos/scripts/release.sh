#!/bin/sh
# Builds Crumble.app signed with Developer ID, notarizes and staples it, and zips it for download.
#
# Needs CRUMBLE_VERSION and CRUMBLE_BUILD_NUMBER, a "Developer ID Application" identity in the
# keychain, and an App Store Connect API key: APP_STORE_CONNECT_KEY_PATH, APP_STORE_CONNECT_KEY_ID,
# and APP_STORE_CONNECT_ISSUER_ID. Prints the zip's path.
set -eu
cd "$(dirname "$0")/.."
: "${CRUMBLE_VERSION:?Set CRUMBLE_VERSION, such as 0.1.0.}"
: "${CRUMBLE_BUILD_NUMBER:?Set CRUMBLE_BUILD_NUMBER.}"
: "${APP_STORE_CONNECT_KEY_PATH:?Set APP_STORE_CONNECT_KEY_PATH to the .p8 key file.}"
: "${APP_STORE_CONNECT_KEY_ID:?Set APP_STORE_CONNECT_KEY_ID.}"
: "${APP_STORE_CONNECT_ISSUER_ID:?Set APP_STORE_CONNECT_ISSUER_ID.}"
export CRUMBLE_VERSION CRUMBLE_BUILD_NUMBER
export CRUMBLE_SIGNING_IDENTITY="${CRUMBLE_SIGNING_IDENTITY:-Developer ID Application}"
export CRUMBLE_VARIANT=production CRUMBLE_APP_OUTPUT=build

./scripts/build-app.sh release >&2
app="build/Crumble.app"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT HUP INT TERM

ditto -c -k --keepParent "$app" "$work/upload.zip"
xcrun notarytool submit "$work/upload.zip" --wait --output-format json \
	--key "$APP_STORE_CONNECT_KEY_PATH" --key-id "$APP_STORE_CONNECT_KEY_ID" \
	--issuer "$APP_STORE_CONNECT_ISSUER_ID" >"$work/result.json"
status=$(plutil -extract status raw "$work/result.json")
if [ "$status" != "Accepted" ]; then
	echo "Notarization ended as $status." >&2
	xcrun notarytool log "$(plutil -extract id raw "$work/result.json")" \
		--key "$APP_STORE_CONNECT_KEY_PATH" --key-id "$APP_STORE_CONNECT_KEY_ID" \
		--issuer "$APP_STORE_CONNECT_ISSUER_ID" >&2 || true
	exit 1
fi
xcrun stapler staple "$app" >&2
spctl --assess --type execute --verbose "$app" >&2

download="build/Crumble-$CRUMBLE_VERSION-macOS.zip"
rm -f "$download"
ditto -c -k --keepParent "$app" "$download"
echo "$download"
