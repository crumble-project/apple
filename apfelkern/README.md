# apfelkern

Shared Swift package for the Crumble macOS and iOS apps. Requires Swift 6.2+ and macOS 26 / iOS 26.

## Libraries

- **`apfelkern`:** Generated OpenAPI and SSE client (`Sources/apfelkern/Generated`), custom `URLSession` transport with per-operation timeouts (`ContractTransport.swift`), domain models, drafts, and optimistic chat delivery (`BotChatDelivery`). Contains no SwiftUI, AppKit, or UIKit code.
- **`BotAvatar`:** The shared SwiftUI views: bot avatars, `BotAvatarEditor`, `FilterPills`, `ReasoningControl`, the chat's `MarkdownText`, `DisplayView`, `ChartView`, and cards, and `BrandLogoView`, whose data `python3 scripts/generate-brand-logos.py` regenerates from the web's icon packages. Avatars build on [Open Bot Avatar for Swift](https://github.com/cheetahbyte/open-bot-avatar-swift), pinned by revision ([THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)).

## Update the API contract

`Contract/` holds a copy of the `bot` contract files from `bot/openapi/`. Ordinary builds use committed output in `Sources/apfelkern/Generated` without running the generator. A running server also serves its document at `GET /openapi.json`.

```sh
python3 scripts/contract.py                           # Regenerate from Contract/
python3 scripts/contract.py --check                   # Verify the generated output byte-for-byte
python3 scripts/contract.py --update ../../bot/openapi # Copy the contract files, regenerate, and run swift test
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
