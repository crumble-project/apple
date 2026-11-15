#!/bin/zsh
# Archives Crumble for iOS and uploads it to App Store Connect, where it becomes a TestFlight build.
#
# Needs CRUMBLE_VERSION and CRUMBLE_BUILD_NUMBER, and an App Store Connect API key with the Admin
# role: APP_STORE_CONNECT_KEY_PATH, APP_STORE_CONNECT_KEY_ID, and APP_STORE_CONNECT_ISSUER_ID. Xcode
# signs with a cloud-managed distribution certificate, so none has to be installed.
set -euo pipefail
cd "${0:A:h}/.."
: "${CRUMBLE_VERSION:?Set CRUMBLE_VERSION, such as 0.1.0.}"
: "${CRUMBLE_BUILD_NUMBER:?Set CRUMBLE_BUILD_NUMBER.}"
: "${APP_STORE_CONNECT_KEY_PATH:?Set APP_STORE_CONNECT_KEY_PATH to the .p8 key file.}"
: "${APP_STORE_CONNECT_KEY_ID:?Set APP_STORE_CONNECT_KEY_ID.}"
: "${APP_STORE_CONNECT_ISSUER_ID:?Set APP_STORE_CONNECT_ISSUER_ID.}"
auth=(
  -allowProvisioningUpdates
  -authenticationKeyPath "$APP_STORE_CONNECT_KEY_PATH"
  -authenticationKeyID "$APP_STORE_CONNECT_KEY_ID"
  -authenticationKeyIssuerID "$APP_STORE_CONNECT_ISSUER_ID"
)
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT HUP INT TERM

xcodebuild -quiet -project Crumble.xcodeproj -scheme Crumble -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$work/Crumble.xcarchive" \
  -clonedSourcePackagesDirPath .packages "${auth[@]}" archive \
  MARKETING_VERSION="$CRUMBLE_VERSION" CURRENT_PROJECT_VERSION="$CRUMBLE_BUILD_NUMBER"
xcodebuild -quiet -exportArchive -archivePath "$work/Crumble.xcarchive" \
  -exportOptionsPlist scripts/ExportOptions.plist -exportPath "$work/export" "${auth[@]}"
echo "Uploaded Crumble $CRUMBLE_VERSION ($CRUMBLE_BUILD_NUMBER) to App Store Connect."
