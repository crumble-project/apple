#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
exec xcodebuild -quiet -project Crumble.xcodeproj -scheme Crumble \
  -destination 'generic/platform=iOS Simulator' ARCHS=arm64 \
  -derivedDataPath build -clonedSourcePackagesDirPath .packages \
  build-for-testing CODE_SIGNING_ALLOWED=NO
