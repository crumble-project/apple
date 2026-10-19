# apfelkern

Shared Swift code for the Crumble iOS and macOS clients. Requires Swift 6.2 or later and iOS 26 or macOS 26.

## Package contents

- API request encoding, response decoding, bearer authentication, and server-sent event parsing.
- Common server models, JSON values, and message delivery state.
- Agent, memory, task, and integration drafts.
- Transcript merging, mention completion, message previews, OAuth callbacks, task validation, and date formatting.
- Attachment metadata, encoding, and limits, plus avatar seed selection.

The `apfelkern` library uses Foundation. It has no third-party dependencies and contains no SwiftUI, UIKit, or AppKit code.

The separate `BotAvatar` library draws the bot avatars with SwiftUI. Live avatars run their motion as looping Core Animation keyframes, hosted in an AppKit or UIKit view, so they cost the app almost no CPU while they animate. Import it with `import BotAvatar`. Choose a body finish with `.environment(\.botFinish, .dither)`: `glossy` (the default), `matte`, `dither`, `halftone`, `grain`, or `outline`. The avatar drawing is adapted from MIT-licensed work; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Use the package

Both clients fetch `git@github.com:crumble-project/apfelkern.git`, tracking `main`. Configure SSH access to GitHub before resolving packages.
A sibling checkout is not required. Import the public API with `import apfelkern`.

Commit and push package changes before updating either client's resolved revision. Uncommitted local changes are not included in remote dependencies.

The apps retain UI, observable application state, optimistic operation orchestration, notifications, Keychain storage, and image conversion.
Activity payload models remain app-specific because their `details` representations differ. Skill drafts also retain their platform-specific fields.
The transport preserves each platform's existing handling of invalid UTF-8.

## Verify changes

Run package checks:

```sh
swift build
swift test
swiftlint lint
```

Build `BotAvatar` for iOS as well, because its live view has separate AppKit and UIKit code:

```sh
xcodebuild -scheme BotAvatar -destination 'generic/platform=iOS Simulator' build
```

The `apfelkernTests` target currently contains only the scaffold test; `BotAvatarTests` covers avatar motion. Existing client suites exercise the extracted APIs and logic.
Run `swift test` in `../desktop` and the unit tests in the `../ios` Xcode project after changing shared behavior.
The iOS test script also runs UI tests; see the [iOS build and test instructions](../ios/README.md#build-and-test).
