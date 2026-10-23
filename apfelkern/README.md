# apfelkern

Shared Swift package for the Crumble macOS and iOS apps. Requires Swift 6.2+ and macOS 26 / iOS 26.

## Libraries

- **`apfelkern`:** Generated OpenAPI and SSE client (`Sources/apfelkern/Generated`), custom `URLSession` transport with per-operation timeouts (`ContractTransport.swift`), domain models, drafts, and optimistic chat delivery (`BotChatDelivery`). Contains no SwiftUI, AppKit, or UIKit code.
- **`BotAvatar`:** SwiftUI and Core Animation bot avatars with seeded motion and body finishes (`dither`, `glossy`, `matte`, `halftone`, `grain`, `outline`). Adapted from MIT-licensed work ([THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)); keep changes aligned with Android's `BotAvatar.kt`.

## Update the API contract

`Contract/pin.json` pins the verified `bot` contract release (`contract-vX.Y.Z`) and SHA-256 checksums. Ordinary builds use committed output in `Sources/apfelkern/Generated` without running the generator.

```sh
python3 scripts/contract.py                          # Regenerate from current pin
python3 scripts/contract.py --check                  # Verify checksums and byte-for-byte output
python3 scripts/contract.py --update contract-vX.Y.Z # Update to a published release (or local bundle path)
```

## Verify changes

```sh
python3 scripts/contract.py --check
swift build
swift test
swiftlint lint
xcodebuild -scheme BotAvatar -destination 'generic/platform=iOS Simulator' build
```

Because `../macos` and `../ios` reference `../apfelkern` by path, run the [macOS](../macos/README.md) and [iOS](../ios/README.md#build-and-test) checks when changing shared code.
