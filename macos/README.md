# Crumble for macOS

Native SwiftUI macOS client for a Crumble server. Supports bot chats, group chats, coding jobs, live bot desktops with take-control, memories, skills, scheduled tasks, MCP integrations, and provider account sign-in.

## Requirements

- macOS 26+ and Xcode 26+ (Swift 6.2).
- A running Crumble server from the sibling `bot` repository.

## Run

```bash
swift run Crumble
```

Defaults to `http://127.0.0.1:7337`. Configure the server URL and bearer token in **Settings** (`⌘,`), where credentials are stored in the Keychain (`ng.crumbli.mac` for release bundles, `ng.crumbli.mac.dev` for `swift run` and dev bundles), or override via environment variables:

```bash
CRUMBLE_URL="http://127.0.0.1:7338" CRUMBLE_TOKEN="REPLACE_WITH_TOKEN" swift run Crumble
```

Preview and snapshot bot avatars with the playground:

```bash
swift run AvatarPlayground
swift run AvatarPlayground --finishes finishes.png
swift run AvatarPlayground --snapshot avatars.png 0.3
```

## Build and verify

```bash
swift test
swiftlint lint
./scripts/check-app-bundle.sh
./scripts/build-app.sh                     # Builds build/Crumble.app
CRUMBLE_VARIANT=dev ./scripts/build-app.sh # Builds build/Crumble Dev.app
```

- Shared API client and models live in [`../apfelkern`](../apfelkern/README.md).
- Local notification behavior requires the `.app` bundle from `./scripts/build-app.sh`; see [Notifications on macOS](docs/notifications.md).
