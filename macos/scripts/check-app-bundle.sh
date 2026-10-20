#!/bin/sh
# Builds Crumble Dev.app into a temporary folder and checks what local
# notifications need from the bundle: its bundle ID and a valid signature,
# without APNs entitlements or push metadata. It does not launch the app.
set -eu
cd "$(dirname "$0")/.."
output="$(mktemp -d)"
trap 'rm -rf "$output"' EXIT HUP INT TERM
CRUMBLE_VARIANT=dev CRUMBLE_APP_OUTPUT="$output" CRUMBLE_SIGNING_IDENTITY='' ./scripts/build-app.sh debug >/dev/null
app="$output/Crumble Dev.app"
plist="$app/Contents/Info.plist"

fail() {
	echo "check-app-bundle: $1" >&2
	exit 1
}

[ -x "$app/Contents/MacOS/Crumble" ] || fail "missing executable"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")" = "ng.crumbli.mac.dev" ] ||
	fail "notifications need the ng.crumbli.mac.dev bundle ID"
codesign --verify --strict "$app" || fail "invalid signature"
if codesign --display --entitlements :- "$app" 2>/dev/null | grep -q "aps-environment"; then
	fail "unexpected APNs entitlement"
fi
if /usr/libexec/PlistBuddy -c 'Print :CrumblePushEnvironment' "$plist" >/dev/null 2>&1; then
	fail "unexpected CrumblePushEnvironment key"
fi
echo "App bundle OK"
