#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
suite="${1:-all}"
case "$suite" in
  unit) only=(-only-testing:CrumbleTests) ;;
  ui) only=(-only-testing:CrumbleUITests) ;;
  all) only=() ;;
  *) print -u2 'Usage: scripts/test.sh [unit|ui|all]'; exit 2 ;;
esac
simulator_id="${CRUMBLE_SIMULATOR_ID:-}"
if [[ -z "$simulator_id" ]]; then
  simulator_id="$(xcrun simctl list devices available -j | python3 -c 'import json,sys; d=json.load(sys.stdin); print(next((x["udid"] for devices in d["devices"].values() for x in devices if x["name"].startswith("iPhone")), ""))')"
fi
if [[ -z "$simulator_id" ]]; then
  print -u2 'Install an iOS simulator runtime in Xcode Settings > Components, then retry.'
  exit 1
fi
# Booting takes minutes on a fresh CI runner, so it runs while the app builds.
xcrun simctl boot "$simulator_id" 2>/dev/null &
boot=$!
common=(-project Crumble.xcodeproj -scheme Crumble
  -destination "platform=iOS Simulator,id=$simulator_id"
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO)
if [[ -n "${CRUMBLE_PACKAGES_DIR:-}" ]]; then
  common+=(-clonedSourcePackagesDirPath "$CRUMBLE_PACKAGES_DIR")
fi
xcodebuild "${common[@]}" "${only[@]}" build-for-testing
wait "$boot" || true
xcrun simctl bootstatus "$simulator_id" -b
exec xcodebuild "${common[@]}" "${only[@]}" -parallel-testing-enabled NO test-without-building
