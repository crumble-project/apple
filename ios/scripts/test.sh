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
exec xcodebuild -project Crumble.xcodeproj -scheme Crumble \
  -destination "platform=iOS Simulator,id=$simulator_id" \
  -derivedDataPath build "${only[@]}" -parallel-testing-enabled NO test CODE_SIGNING_ALLOWED=NO
